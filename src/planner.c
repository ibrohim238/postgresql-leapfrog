/*-------------------------------------------------------------------------
 *
 * planner.c
 *	  Planner side of the Index Merge Intersect custom scan: the
 *	  set_rel_pathlist hook that finds sets of indexes to intersect and
 *	  offers their paths, and the conversion of the chosen path into a
 *	  CustomScan plan.
 *
 * IDENTIFICATION
 *	  src/planner.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/cmptype.h"
#include "access/nbtree.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_opfamily_d.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/prep.h"
#include "optimizer/restrictinfo.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

#include "leapfrog.h"

/*
 * Under leapfrog.force the paths keep their relative costs, scaled down so
 * far that no other path can be cheaper: add_path compares costs by ratio,
 * so the cheapest set of indexes still wins among the sets.
 */
#define INTERSECT_FORCE_SCALE 1e-12

/*
 * Argument of ec_member_is_column, the callback of
 * generate_implied_equalities_for_column.
 */
typedef struct ColumnMatchArg
{
	Index		rti;
	AttrNumber	attno;
} ColumnMatchArg;

/*
 * What the hook looks at for one relation: the sort column and the index
 * candidates, with the lookups shared by every set of streams.
 */
typedef struct IntersectSearch
{
	PlannerInfo *root;
	RelOptInfo *rel;
	Index		rti;
	RangeTblEntry *rte;
	AttrNumber	sort_attno;
	PathKey    *pathkey;
	IndexCandidate *candidates;
	int			ncandidates;
	double		ndistinct;		/* -1 until looked up */
} IntersectSearch;

/* Saved hook value */
static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook = NULL;

static void intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel,
									   Index rti, RangeTblEntry *rte);
static Plan *intersect_plan_path(PlannerInfo *root, RelOptInfo *rel,
								 CustomPath *best_path, List *tlist,
								 List *clauses, List *custom_plans);

static const CustomPathMethods intersect_path_methods = {
	.CustomName = INTERSECT_NAME,
	.PlanCustomPath = intersect_plan_path,
};

static Const *
make_oid_const(Oid value)
{
	return makeConst(OIDOID, -1, InvalidOid, sizeof(Oid),
					 ObjectIdGetDatum(value), false, true);
}

static Const *
make_int4_const(int32 value)
{
	return makeConst(INT4OID, -1, InvalidOid, sizeof(int32),
					 Int32GetDatum(value), false, true);
}

static Const *
make_float8_const(double value)
{
	return makeConst(FLOAT8OID, -1, InvalidOid, sizeof(float8),
					 Float8GetDatum(value), false, FLOAT8PASSBYVAL);
}

static bool
is_column_var(Node *node, Index rti, AttrNumber attno)
{
	return IsA(node, Var) && ((Var *) node)->varno == rti &&
		((Var *) node)->varattno == attno &&
		((Var *) node)->varlevelsup == 0;
}

/*
 * is_int8_equality
 *		Is the clause "x = y" with x the bigint column attno of relation rti
 *		and y a plain integer value?  Returns y in *other.
 */
static bool
is_int8_equality(RestrictInfo *rinfo, Index rti, AttrNumber attno,
				 Node **other)
{
	OpExpr	   *op;
	Node	   *left;
	Node	   *right;

	if (rinfo->pseudoconstant || !IsA(rinfo->clause, OpExpr))
		return false;

	op = (OpExpr *) rinfo->clause;
	if (list_length(op->args) != 2 || op->opresulttype != BOOLOID)
		return false;

	/* bigint = bigint, bigint = integer/smallint and the reverse */
	switch (get_opcode(op->opno))
	{
		case F_INT8EQ:
		case F_INT84EQ:
		case F_INT48EQ:
		case F_INT82EQ:
		case F_INT28EQ:
			break;
		default:
			return false;
	}

	left = linitial(op->args);
	right = lsecond(op->args);

	if (!is_column_var(left, rti, attno))
	{
		Node	   *tmp = left;

		left = right;
		right = tmp;
	}

	if (!is_column_var(left, rti, attno) || exprType(left) != INT8OID)
		return false;

	/* the value is passed to the btree as an int8 key */
	switch (exprType(right))
	{
		case INT2OID:
		case INT4OID:
		case INT8OID:
			break;
		default:
			return false;
	}

	*other = right;

	return true;
}

/*
 * ec_member_is_column
 *		ec_matches_callback_type: does the equivalence member stand for
 *		column attno of relation rti, in an equivalence class the integer
 *		btree family can enforce?
 */
static bool
ec_member_is_column(PlannerInfo *root, RelOptInfo *rel, EquivalenceClass *ec,
					EquivalenceMember *em, void *arg)
{
	ColumnMatchArg *column = (ColumnMatchArg *) arg;

	if (!list_member_oid(ec->ec_opfamilies, INTEGER_BTREE_FAM_OID))
		return false;

	return is_column_var((Node *) em->em_expr, column->rti, column->attno);
}

/*
 * find_join_equality
 *		Pick "attno = othercolumn" from a list of join clauses: the value is
 *		a column of a single other relation, which becomes a nestloop
 *		parameter.  Returns NULL when there is no such clause.
 */
static RestrictInfo *
find_join_equality(List *clauses, RelOptInfo *rel, Index rti,
				   AttrNumber attno, Node **expr, Relids *outer_relids)
{
	ListCell   *lc;

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		Node	   *other;

		if (!is_int8_equality(rinfo, rti, attno, &other))
			continue;

		if (IsA(other, Var) && ((Var *) other)->varlevelsup == 0 &&
			((Var *) other)->varno != rti &&
			join_clause_is_movable_to(rinfo, rel))
		{
			*expr = other;
			*outer_relids = bms_make_singleton(((Var *) other)->varno);
			return rinfo;
		}
	}

	return NULL;
}

/*
 * find_equality_clause
 *		Look for "attno = value" among the restrictions of rel, among its
 *		join clauses when the value is a column of another relation, or
 *		among the equalities implied by the equivalence classes the column
 *		belongs to (a mergejoinable join clause lives there, not in
 *		joininfo), the way match_eclass_clauses_to_index does.
 *
 * Returns the clause, the value expression in *expr and the relids the
 * expression refers to in *outer_relids; NULL when there is none.
 */
static RestrictInfo *
find_equality_clause(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 AttrNumber attno, Node **expr, Relids *outer_relids)
{
	ListCell   *lc;
	RestrictInfo *join_rinfo;
	ColumnMatchArg arg;

	foreach(lc, rel->baserestrictinfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		Node	   *other;

		if (!is_int8_equality(rinfo, rti, attno, &other))
			continue;

		/* constants and query parameters, both known at execution time */
		if (IsA(other, Const) && !((Const *) other)->constisnull)
		{
			*expr = other;
			*outer_relids = NULL;
			return rinfo;
		}

		if (IsA(other, Param))
		{
			*expr = other;
			*outer_relids = NULL;
			return rinfo;
		}
	}

	join_rinfo = find_join_equality(rel->joininfo, rel, rti, attno, expr,
									outer_relids);
	if (join_rinfo != NULL)
		return join_rinfo;

	if (!rel->has_eclass_joins)
		return NULL;

	arg.rti = rti;
	arg.attno = attno;

	return find_join_equality(generate_implied_equalities_for_column(root, rel,
																	 ec_member_is_column,
																	 &arg,
																	 rel->lateral_referencers),
							  rel, rti, attno, expr, outer_relids);
}

/*
 * pathkey_is_column
 *		Is the given pathkey a sort on column attno of relation rti?  A
 *		member nulled by an outer join is a different expression, as
 *		get_eclass_for_sort_expr treats it when building index pathkeys.
 */
static bool
pathkey_is_column(PathKey *pathkey, Index rti, AttrNumber attno)
{
	ListCell   *lc;

	foreach(lc, pathkey->pk_eclass->ec_members)
	{
		EquivalenceMember *em = (EquivalenceMember *) lfirst(lc);

		if (is_column_var((Node *) em->em_expr, rti, attno) &&
			((Var *) em->em_expr)->varnullingrels == NULL)
			return true;
	}

	return false;
}

static bool
is_int8_column(RangeTblEntry *rte, AttrNumber attno)
{
	return attno > 0 && get_atttype(rte->relid, attno) == INT8OID;
}

/*
 * is_notnull_column
 *		NULLs have no place in the merge: values are compared for equality
 *		and the sort column must be NOT NULL.  The planner's notnullattnums
 *		is the source of truth: a NOT NULL constraint added NOT VALID sets
 *		pg_attribute.attnotnull while NULLs may still be in the column, and
 *		get_relation_info leaves such columns out of the set.
 */
static bool
is_notnull_column(RelOptInfo *rel, AttrNumber attno)
{
	return bms_is_member(attno, rel->notnullattnums);
}

/*
 * is_heapkeyspace
 *		Does the btree order duplicate keys by heap TID?  True for indexes
 *		in the version 4 format; older pg_upgraded indexes need a REINDEX.
 */
static bool
is_heapkeyspace(IndexCandidate *candidate)
{
	if (candidate->heapkeyspace < 0)
	{
		Relation	index = index_open(candidate->index->indexoid,
									   AccessShareLock);
		bool		heapkeyspace;
		bool		allequalimage;

		_bt_metaversion(index, &heapkeyspace, &allequalimage);
		index_close(index, AccessShareLock);
		candidate->heapkeyspace = heapkeyspace ? 1 : 0;
	}

	return candidate->heapkeyspace == 1;
}

/*
 * is_usable_btree
 *		A btree whose column at position pos is sorted ascending in the
 *		operator family of the query's sort key, so that every stream of the
 *		merge produces values in the order the query asks for.  NULLs
 *		ordering is not checked: the sort column is NOT NULL.  Whether the
 *		duplicates are ordered by TID is checked last, by is_heapkeyspace,
 *		for the sets that pass everything else: it opens the index.
 */
static bool
is_usable_btree(IndexOptInfo *index, int pos, PathKey *pathkey)
{
	return index->relam == BTREE_AM_OID &&
		!index->hypothetical &&
		(index->indpred == NIL || index->predOK) &&
		index->opfamily[pos] == INTEGER_BTREE_FAM_OID &&
		index->sortopfamily != NULL &&
		index->sortopfamily[pos] == pathkey->pk_opfamily &&
		!index->reverse_sort[pos];
}

/*
 * find_index_candidate
 *		Check whether index can produce sort_attno in order once the key
 *		columns before it are fixed by equalities.
 *
 * Every key column before sort_attno must be compared for equality with a
 * value known at execution time.  Returns false when sort_attno is not a
 * key column or a column before it has no usable equality.
 */
static bool
find_index_candidate(IntersectSearch *search, IndexOptInfo *index,
					 IndexCandidate *candidate)
{
	int			sortpos = -1;

	candidate->index = index;
	candidate->clauses = NIL;
	candidate->exprs = NIL;
	candidate->required_outer = NULL;
	candidate->heapkeyspace = -1;
	candidate->range_known = -1;

	for (int i = 0; i < index->nkeycolumns; i++)
	{
		if (index->indexkeys[i] == search->sort_attno)
		{
			sortpos = i;
			break;
		}
	}
	candidate->sortpos = sortpos;

	if (sortpos < 0 || !is_usable_btree(index, sortpos, search->pathkey))
		return false;

	for (int i = 0; i < sortpos; i++)
	{
		AttrNumber	attno = index->indexkeys[i];
		RestrictInfo *clause;
		Node	   *expr;
		Relids		outer_relids;

		/* the scan keys use int8 operators of the integer family */
		if (!is_int8_column(search->rte, attno) ||
			index->opfamily[i] != INTEGER_BTREE_FAM_OID)
			return false;

		clause = find_equality_clause(search->root, search->rel, search->rti,
									  attno, &expr, &outer_relids);
		if (clause == NULL)
			return false;

		candidate->clauses = lappend(candidate->clauses, clause);
		candidate->exprs = lappend(candidate->exprs, expr);
		candidate->required_outer = bms_add_members(candidate->required_outer,
													outer_relids);
	}

	candidate->entries = lf_index_entries(search->root, search->rti, candidate);

	return true;
}

/*
 * is_outer_candidate
 *		Can the index be the outer stream of the intersection: at least one
 *		equality column, then sortcol as the last key column?
 */
static bool
is_outer_candidate(IndexCandidate *candidate)
{
	return candidate->usable &&
		candidate->index->nkeycolumns >= 2 &&
		candidate->sortpos == candidate->index->nkeycolumns - 1;
}

/*
 * equality_column_in_set
 *		Is attno an equality column of some stream of the set?
 */
static bool
equality_column_in_set(IndexCandidate **streams, int nstreams,
					   AttrNumber attno)
{
	for (int i = 0; i < nstreams; i++)
	{
		IndexOptInfo *index = streams[i]->index;

		for (int j = 0; j < streams[i]->sortpos; j++)
		{
			if (index->indexkeys[j] == attno)
				return true;
		}
	}

	return false;
}

/*
 * adds_restriction
 *		Does the index narrow the set's rows down?  A partial index does
 *		through its predicate, unless a stream of the set already enforces
 *		one that implies it; an ordinary one only through an equality column
 *		no stream of the set has.
 */
static bool
adds_restriction(IndexCandidate **streams, int nstreams,
				 IndexCandidate *candidate)
{
	IndexOptInfo *index = candidate->index;

	if (index->indpred != NIL)
	{
		bool		implied = false;

		for (int i = 1; i < nstreams && !implied; i++)
		{
			List	   *pred = streams[i]->index->indpred;

			if (pred != NIL && predicate_implied_by(index->indpred, pred, false))
				implied = true;
		}
		if (!implied)
			return true;
	}

	for (int i = 0; i < candidate->sortpos; i++)
	{
		if (!equality_column_in_set(streams, nstreams, index->indexkeys[i]))
			return true;
	}

	return false;
}

/*
 * is_inner_candidate
 *		Can the index join the set as an inner stream: (j1, ..., jM, sortcol,
 *		...) with equalities on every jI, not in the set yet, and adding a
 *		restriction of its own?
 */
static bool
is_inner_candidate(IndexCandidate **streams, int nstreams,
				   IndexCandidate *candidate)
{
	if (!candidate->usable)
		return false;
	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i] == candidate)
			return false;
	}

	return adds_restriction(streams, nstreams, candidate);
}

/*
 * build_intersect_path
 *		Build and cost the Index Merge Intersect path for one set of streams;
 *		NULL when the set cannot be used.  correlation is
 *		lf_outer_index_correlation of the outer index.
 */
static CustomPath *
build_intersect_path(IntersectSearch *search, IndexCandidate **streams,
					 int nstreams, double correlation)
{
	PlannerInfo *root = search->root;
	RelOptInfo *rel = search->rel;
	CustomPath *cpath;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer = NULL;
	double		group_bytes = 0;
	double		reads[INTERSECT_MAX_STREAMS];

	if (search->ndistinct < 0)
		search->ndistinct = lf_sortcol_ndistinct(root, rel, search->rti,
												 search->sort_attno);

	/*
	 * The TID groups of one value are expected to fit into work_mem together.
	 * This is an estimate over the average value; the executor enforces the
	 * limit itself, so under leapfrog.force the estimate is ignored.
	 */
	for (int i = 1; i < nstreams; i++)
		group_bytes += Max(1.0, streams[i]->entries / search->ndistinct) *
			sizeof(ItemPointerData);
	if (!intersect_force && group_bytes > work_mem * 1024.0)
		return NULL;

	/* duplicates must be ordered by TID in every stream */
	for (int i = 0; i < nstreams; i++)
	{
		if (!is_heapkeyspace(streams[i]))
			return NULL;
	}

	/* a LATERAL reference makes the path parameterized by those rels */
	for (int i = 0; i < nstreams; i++)
		required_outer = bms_add_members(required_outer,
										 streams[i]->required_outer);
	required_outer = bms_add_members(required_outer, rel->lateral_relids);
	if (!bms_is_empty(required_outer))
		param_info = get_baserel_parampathinfo(root, rel, required_outer);

	cpath = makeNode(CustomPath);

	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = rel;
	cpath->path.pathtarget = rel->reltarget;
	cpath->path.param_info = param_info;
	cpath->path.parallel_aware = false;
	cpath->path.parallel_safe = false;
	cpath->path.parallel_workers = 0;
	cpath->path.rows = param_info ? param_info->ppi_rows : rel->rows;
	cpath->path.pathkeys = list_make1(search->pathkey);
	cpath->flags = 0;
	cpath->methods = &intersect_path_methods;

	lf_cost_intersect_path(cpath, root, search->rte, search->sort_attno,
						   streams, nstreams, search->ndistinct, correlation,
						   reads);

	/*
	 * A CustomPath has no custom_exprs; the value expressions and the index
	 * predicates travel in custom_private and become the plan's custom_exprs
	 * in intersect_plan_path, where createplan.c turns outer-relation Vars
	 * into nestloop params and setrefs.c fixes up the rest.  The layout is
	 * the PRIVATE_* and STREAM_* positions.
	 */
	cpath->custom_private =
		list_make2(makeBoolConst(search->pathkey->pk_cmptype == COMPARE_GT,
								 false),
				   make_int4_const(nstreams));
	for (int i = 0; i < nstreams; i++)
	{
		cpath->custom_private = lappend(cpath->custom_private,
										make_oid_const(streams[i]->index->indexoid));
		cpath->custom_private = lappend(cpath->custom_private,
										make_int4_const(streams[i]->sortpos));
		cpath->custom_private = lappend(cpath->custom_private,
										make_float8_const(reads[i]));
	}
	for (int i = 0; i < nstreams; i++)
	{
		cpath->custom_private = lappend(cpath->custom_private,
										copyObject(streams[i]->exprs));
		cpath->custom_private = lappend(cpath->custom_private,
										i > 0 ? copyObject(streams[i]->index->indpred) : NIL);
	}

	return cpath;
}

/*
 * add_intersect_path
 *		Offer a built path to add_path, under leapfrog.force with its costs
 *		scaled down: the competition with the other plans is skipped, like
 *		MySQL does for the INDEX_MERGE hint, but the sets still compete among
 *		themselves.  The path can still be passed over for reasons other than
 *		cost, such as disabled_nodes or a parameterization the join order
 *		cannot provide.
 */
static void
add_intersect_path(RelOptInfo *rel, CustomPath *cpath)
{
	if (intersect_force)
	{
		cpath->path.startup_cost *= INTERSECT_FORCE_SCALE;
		cpath->path.total_cost *= INTERSECT_FORCE_SCALE;
	}

	add_path(rel, &cpath->path);
}

/*
 * The cheapest pair found so far, the start of the greedy expansion.
 */
typedef struct BestPair
{
	CustomPath *path;
	IndexCandidate *outer;
	IndexCandidate *inner;
	double		correlation;
} BestPair;

/*
 * search_pairs_from_outer
 *		Offer every pair of one outer index with an inner candidate, as the
 *		planner compares them with the stock plans and with each other, and
 *		remember the cheapest pair of all in *best.  Pairs are not offered
 *		under leapfrog.min_indexes > 2.
 */
static void
search_pairs_from_outer(IntersectSearch *search, IndexCandidate *outer,
						BestPair *best)
{
	IndexCandidate *streams[2];
	double		correlation;

	correlation = lf_outer_index_correlation(search->root, search->rti,
											 outer->index);
	streams[0] = outer;

	for (int j = 0; j < search->ncandidates; j++)
	{
		IndexCandidate *inner = &search->candidates[j];
		CustomPath *cpath;

		if (!is_inner_candidate(streams, 1, inner))
			continue;
		streams[1] = inner;
		cpath = build_intersect_path(search, streams, 2, correlation);
		if (cpath == NULL)
			continue;
		if (best->path == NULL ||
			cpath->path.total_cost < best->path->path.total_cost)
		{
			best->path = cpath;
			best->outer = outer;
			best->inner = inner;
			best->correlation = correlation;
		}
		if (intersect_min_streams <= 2)
			add_intersect_path(search->rel, cpath);
	}
}

/*
 * expand_best_pair
 *		From the cheapest pair, add one stream at a time, the one that lowers
 *		the estimated cost the most, as long as one does and
 *		leapfrog.max_indexes allows.  A stream that costs more than it saves
 *		is left out and the planner stays with the smaller set.  Only the
 *		cheapest pair is expanded: a larger set built on a dearer pair reads
 *		the dearer pair's streams and more.  Sets smaller than
 *		leapfrog.min_indexes are built but not offered, and the set that
 *		reaches it is offered whatever its cost: that lets a test run a
 *		larger set against the stock plans.
 */
static void
expand_best_pair(IntersectSearch *search, BestPair *best)
{
	IndexCandidate *streams[INTERSECT_MAX_STREAMS];
	int			nstreams = 2;
	CustomPath *best_path = best->path;

	streams[0] = best->outer;
	streams[1] = best->inner;

	while (nstreams < intersect_max_streams)
	{
		CustomPath *next_best = NULL;
		IndexCandidate *next_stream = NULL;
		bool		required = nstreams + 1 <= intersect_min_streams;

		for (int j = 0; j < search->ncandidates; j++)
		{
			IndexCandidate *inner = &search->candidates[j];
			CustomPath *cpath;

			if (!is_inner_candidate(streams, nstreams, inner))
				continue;
			streams[nstreams] = inner;
			cpath = build_intersect_path(search, streams, nstreams + 1,
										 best->correlation);
			if (cpath == NULL)
				continue;
			if (next_best == NULL ||
				cpath->path.total_cost < next_best->path.total_cost)
			{
				next_best = cpath;
				next_stream = inner;
			}
		}

		if (next_best == NULL)
			break;
		if (!required &&
			next_best->path.total_cost >= best_path->path.total_cost)
			break;

		streams[nstreams++] = next_stream;
		best_path = next_best;
		if (nstreams >= intersect_min_streams)
			add_intersect_path(search->rel, next_best);
	}
}

/*
 * intersect_set_rel_pathlist
 *		set_rel_pathlist_hook: offer Index Merge Intersect paths for every
 *		suitable set of indexes of the relation.
 */
static void
intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
						   RangeTblEntry *rte)
{
	IntersectSearch search;
	BestPair	best;
	ListCell   *lc;

	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	if (!intersect_enabled || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION ||
		rel->reloptkind != RELOPT_BASEREL || root->query_pathkeys == NIL ||
		IS_DUMMY_REL(rel) || rel->indexlist == NIL)
		return;

	search.root = root;
	search.rel = rel;
	search.rti = rti;
	search.rte = rte;
	search.sort_attno = InvalidAttrNumber;
	search.ndistinct = -1.0;

	/* the sort column: a bigint NOT NULL column of this relation */
	search.pathkey = linitial_node(PathKey, root->query_pathkeys);
	foreach(lc, search.pathkey->pk_eclass->ec_members)
	{
		EquivalenceMember *em = (EquivalenceMember *) lfirst(lc);
		AttrNumber	attno;

		if (!IsA(em->em_expr, Var))
			continue;
		attno = ((Var *) em->em_expr)->varattno;
		if (attno > 0 && pathkey_is_column(search.pathkey, rti, attno) &&
			is_int8_column(rte, attno) && is_notnull_column(rel, attno))
		{
			search.sort_attno = attno;
			break;
		}
	}

	if (search.sort_attno == InvalidAttrNumber)
		return;

	/*
	 * Each index is checked once; the sets are then formed from the indexes
	 * that can produce sortcol in order, usually a few of the relation's.
	 */
	search.candidates = palloc(list_length(rel->indexlist) *
							   sizeof(IndexCandidate));
	search.ncandidates = 0;
	foreach(lc, rel->indexlist)
	{
		IndexCandidate *candidate = &search.candidates[search.ncandidates];

		candidate->usable = find_index_candidate(&search,
												 lfirst_node(IndexOptInfo, lc),
												 candidate);
		if (candidate->usable)
			search.ncandidates++;
	}

	best.path = NULL;
	for (int i = 0; i < search.ncandidates; i++)
	{
		if (is_outer_candidate(&search.candidates[i]))
			search_pairs_from_outer(&search, &search.candidates[i], &best);
	}
	if (best.path != NULL)
		expand_best_pair(&search, &best);

	pfree(search.candidates);
}

/*
 * is_candidate_equality
 *		Is the clause one of the equalities a stream enforces: column i of
 *		its index compared with the i-th value expression?
 */
static bool
is_candidate_equality(RestrictInfo *rinfo, Index rti, IndexOptInfo *index,
					  List *exprs)
{
	int			i = 0;
	ListCell   *lc;

	foreach(lc, exprs)
	{
		Node	   *other;

		if (is_int8_equality(rinfo, rti, index->indexkeys[i], &other) &&
			equal(other, lfirst(lc)))
			return true;
		i++;
	}

	return false;
}

/*
 * find_index_info
 *		The IndexOptInfo of the relation's index with the given OID.
 */
static IndexOptInfo *
find_index_info(RelOptInfo *rel, Oid indexoid)
{
	ListCell   *lc;

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, lc);

		if (index->indexoid == indexoid)
			return index;
	}

	elog(ERROR, "index %u is not an index of the relation", indexoid);
	return NULL;				/* keep compiler quiet */
}

static int
path_nstreams(CustomPath *best_path)
{
	return DatumGetInt32(list_nth_node(Const, best_path->custom_private,
									   PRIVATE_NSTREAMS)->constvalue);
}

static Oid
path_stream_oid(CustomPath *best_path, int stream)
{
	return DatumGetObjectId(list_nth_node(Const, best_path->custom_private,
										  PRIVATE_COUNT +
										  stream * STREAM_PRIVATE_COUNT +
										  STREAM_PRIVATE_INDEX)->constvalue);
}

static List *
path_stream_exprs(CustomPath *best_path, int stream, int which)
{
	int			nstreams = path_nstreams(best_path);

	return list_nth(best_path->custom_private,
					PRIVATE_COUNT + nstreams * STREAM_PRIVATE_COUNT +
					stream * STREAM_EXPRS_COUNT + which);
}

/*
 * intersect_scan_qual
 *		The quals the node still has to evaluate, as create_indexscan_plan
 *		computes qpqual: the equalities on the columns of every stream are
 *		enforced by the scan keys and rechecked under EvalPlanQual by
 *		intersect_recheck, so they are dropped.  Clauses implied by the
 *		predicate of an inner index are dropped as well, except for a target
 *		relation of UPDATE/DELETE/SELECT FOR UPDATE, where
 *		check_index_predicates keeps them in the plan for EvalPlanQual.
 *
 * Clauses implied by the predicate of a partial outer index are never
 * dropped: the node does not keep that predicate, so under EvalPlanQual
 * only this qual checks it on the new row version (leapfrog_outer_partial).
 */
static List *
intersect_scan_qual(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *clauses)
{
	int			nstreams = path_nstreams(best_path);
	IndexOptInfo *indexes[INTERSECT_MAX_STREAMS];
	bool		is_target_rel;
	List	   *qpqual = NIL;
	ListCell   *lc;

	for (int i = 0; i < nstreams; i++)
		indexes[i] = find_index_info(rel, path_stream_oid(best_path, i));

	is_target_rel = (bms_is_member(rel->relid, root->all_result_relids) ||
					 get_plan_rowmark(root->rowMarks, rel->relid) != NULL);

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		bool		enforced = false;

		if (rinfo->pseudoconstant)
			continue;
		for (int i = 0; i < nstreams && !enforced; i++)
		{
			List	   *indpred = i > 0 ? indexes[i]->indpred : NIL;

			if (is_candidate_equality(rinfo, rel->relid, indexes[i],
									  path_stream_exprs(best_path, i,
														STREAM_EXPRS_KEYS)))
				enforced = true;
			else if (!is_target_rel && indpred != NIL &&
					 !contain_mutable_functions((Node *) rinfo->clause) &&
					 predicate_implied_by(list_make1(rinfo->clause), indpred,
										  false))
				enforced = true;
		}
		if (!enforced)
			qpqual = lappend(qpqual, rinfo);
	}

	return extract_actual_clauses(qpqual, false);
}

/*
 * intersect_plan_path
 *		PlanCustomPath callback: turn the path into a CustomScan plan node.
 *
 * The index OIDs need no entry in the plan's relationOids: as for an
 * IndexScan, creating or dropping an index sends a relcache invalidation for
 * its table, which the plan already depends on.
 */
static Plan *
intersect_plan_path(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *tlist, List *clauses, List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);
	List	   *private = best_path->custom_private;
	int			nconsts = PRIVATE_COUNT +
		path_nstreams(best_path) * STREAM_PRIVATE_COUNT;

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = intersect_scan_qual(root, rel, best_path, clauses);
	cscan->scan.scanrelid = rel->relid;
	cscan->flags = best_path->flags;
	cscan->custom_private = list_truncate(list_copy(private), nconsts);
	cscan->custom_exprs = list_copy_tail(private, nconsts);
	cscan->custom_scan_tlist = NIL;
	cscan->methods = &lf_scan_methods;

	return &cscan->scan.plan;
}

/*
 * lf_planner_init
 *		Install the planner hook; called once from _PG_init.
 */
void
lf_planner_init(void)
{
	prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = intersect_set_rel_pathlist;
}
