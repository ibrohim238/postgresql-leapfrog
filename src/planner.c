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
#include "catalog/pg_type.h"
#include "common/int.h"
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
	Oid			opfamily;
} ColumnMatchArg;

/*
 * An equality the scan can enforce on one index column: the clause, the
 * value expression, its operator with the column on the left and the
 * collation it compares in, and the outer rels the value refers to.
 */
typedef struct IndexEquality
{
	RestrictInfo *clause;
	Node	   *expr;
	Oid			opno;
	Oid			collation;
	Relids		outer_relids;
} IndexEquality;

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
	SortColumn	sort;
	PathKey    *pathkey;
	IndexCandidate *candidates;
	int			ncandidates;
	double		ndistinct;		/* -1 until looked up */
} IntersectSearch;

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

/*
 * match_column_var
 *		The Var of column attno of relation rti the node stands for, or NULL.
 *		A binary-compatible relabeling is looked through, as
 *		match_index_to_operand accepts it: a varchar column compared with texteq
 *		appears as (col)::text, a domain column in an equivalence class is
 *		relabeled to its base type.
 */
static Var *
match_column_var(Node *node, Index rti, AttrNumber attno)
{
	Var		   *var;

	while (node && IsA(node, RelabelType))
		node = (Node *) ((RelabelType *) node)->arg;

	if (node == NULL || !IsA(node, Var))
		return NULL;

	var = (Var *) node;
	if (var->varno != rti || var->varattno != attno || var->varlevelsup != 0)
		return NULL;

	return var;
}

static bool
is_column_var(Node *node, Index rti, AttrNumber attno)
{
	return match_column_var(node, rti, attno) != NULL;
}

/*
 * match_index_equality
 *		Is the clause "x = y" with x key column col of the index, compared by
 *		an equality operator of the column's btree family, as for an Index
 *		Cond?  Fills *equality with y, the operator with x on the left (the
 *		commutator when x is on the right) and the clause's collation.  The
 *		index column must be sorted in that collation, unless it has none, and
 *		the clause must be safe to run before the row security quals: a scan
 *		key sees every entry of the index, also those of rows the quals hide.
 */
static bool
match_index_equality(RestrictInfo *rinfo, Index rti, IndexOptInfo *index,
					 int col, IndexEquality *equality)
{
	AttrNumber	attno = index->indexkeys[col];
	OpExpr	   *op;
	Node	   *left;
	Node	   *right;
	Oid			opno;

	if (rinfo->pseudoconstant || !IsA(rinfo->clause, OpExpr) ||
		!restriction_is_securely_promotable(rinfo, index->rel))
		return false;

	op = (OpExpr *) rinfo->clause;
	if (list_length(op->args) != 2 || op->opresulttype != BOOLOID)
		return false;

	left = linitial(op->args);
	right = lsecond(op->args);
	opno = op->opno;

	if (!is_column_var(left, rti, attno))
	{
		Node	   *tmp = left;

		left = right;
		right = tmp;
		opno = get_commutator(opno);
		if (!OidIsValid(opno))
			return false;
	}

	if (!is_column_var(left, rti, attno) ||
		get_op_opfamily_strategy(opno, index->opfamily[col]) !=
		BTEqualStrategyNumber)
		return false;

	if (OidIsValid(index->indexcollations[col]) &&
		index->indexcollations[col] != op->inputcollid)
		return false;

	equality->clause = rinfo;
	equality->expr = right;
	equality->opno = opno;
	equality->collation = op->inputcollid;
	equality->outer_relids = NULL;

	return true;
}

/*
 * ec_member_is_column
 *		ec_matches_callback_type: does the equivalence member stand for
 *		column attno of relation rti, in an equivalence class the column's
 *		btree family can enforce?
 */
static bool
ec_member_is_column(PlannerInfo *root, RelOptInfo *rel, EquivalenceClass *ec,
					EquivalenceMember *em, void *arg)
{
	ColumnMatchArg *column = (ColumnMatchArg *) arg;

	if (!list_member_oid(ec->ec_opfamilies, column->opfamily))
		return false;

	return is_column_var((Node *) em->em_expr, column->rti, column->attno);
}

/*
 * find_join_equality
 *		Pick "col = value" from a list of join clauses: the value is a
 *		non-volatile expression of other relations only, as
 *		match_clause_to_indexcol accepts for an Index Cond; its columns become
 *		nestloop parameters.  False when there is no such clause.
 */
static bool
find_join_equality(PlannerInfo *root, List *clauses, RelOptInfo *rel,
				   Index rti, IndexOptInfo *index, int col,
				   IndexEquality *equality)
{
	ListCell   *lc;

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
		Relids		outer_relids;

		if (!match_index_equality(rinfo, rti, index, col, equality))
			continue;

		outer_relids = pull_varnos(root, equality->expr);
		if (!bms_is_empty(outer_relids) &&
			!bms_overlap(outer_relids, rel->relids) &&
			!contain_volatile_functions(equality->expr) &&
			join_clause_is_movable_to(rinfo, rel))
		{
			equality->outer_relids = outer_relids;
			return true;
		}
	}

	return false;
}

/*
 * find_equality_clause
 *		Look for "col = value" among the restrictions of rel, its join clauses,
 *		or the equalities implied by the column's equivalence classes (a
 *		mergejoinable join clause lives there, not in joininfo), as
 *		match_eclass_clauses_to_index does.  False when there is none.
 */
static bool
find_equality_clause(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 IndexOptInfo *index, int col, IndexEquality *equality)
{
	ListCell   *lc;
	ColumnMatchArg arg;

	foreach(lc, rel->baserestrictinfo)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);

		if (!match_index_equality(rinfo, rti, index, col, equality))
			continue;

		/*
		 * A value known at execution time: a constant, or an expression of
		 * constants and parameters without volatile functions, evaluated once
		 * per (re)scan.  A NULL constant matches no row.
		 */
		if (IsA(equality->expr, Const))
		{
			if (!((Const *) equality->expr)->constisnull)
				return true;
		}
		else if (!contain_var_clause(equality->expr) &&
				 !contain_volatile_functions(equality->expr))
			return true;
	}

	if (find_join_equality(root, rel->joininfo, rel, rti, index, col,
						   equality))
		return true;

	if (!rel->has_eclass_joins)
		return false;

	arg.rti = rti;
	arg.attno = index->indexkeys[col];
	arg.opfamily = index->opfamily[col];

	return find_join_equality(root,
							  generate_implied_equalities_for_column(root, rel,
																	 ec_member_is_column,
																	 &arg,
																	 rel->lateral_referencers),
							  rel, rti, index, col, equality);
}

/*
 * pathkey_is_column
 *		Is the given pathkey a sort on column attno of relation rti?  A
 *		member nulled by an outer join is a different expression, as
 *		get_eclass_for_sort_expr treats it when building index pathkeys.  The
 *		column of a partition is a child member of the class, which only the
 *		iterator shows, with the partition's own attribute number.
 */
static bool
pathkey_is_column(PathKey *pathkey, RelOptInfo *rel, Index rti,
				  AttrNumber attno)
{
	EquivalenceMemberIterator it;
	EquivalenceMember *em;

	setup_eclass_member_iterator(&it, pathkey->pk_eclass, rel->relids);
	while ((em = eclass_member_iterator_next(&it)) != NULL)
	{
		Var		   *var = match_column_var((Node *) em->em_expr, rti, attno);

		if (var != NULL && var->varnullingrels == NULL)
			return true;
	}

	return false;
}

/*
 * is_notnull_column
 *		Is the sort column free of NULLs in the live rows?  notnullattnums is
 *		the source of truth: a NOT NULL constraint added NOT VALID sets
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
 * is_backward_stream
 *		Does the index give the query's order when scanned backward?
 */
static bool
is_backward_stream(IndexOptInfo *index, int pos, SortColumn *sort)
{
	return index->reverse_sort[pos] != sort->descending;
}

/*
 * is_usable_btree
 *		A btree whose column at pos is sorted in the operator family, input
 *		type and collation of the query's sort key, so that its values compare
 *		alike with the other streams', and which reads the query's order in one
 *		scan direction, the NULLs of a nullable column included.
 *		is_heapkeyspace is checked last, for the sets that pass everything
 *		else: it opens the index.
 */
static bool
is_usable_btree(IndexOptInfo *index, int pos, SortColumn *sort)
{
	return index->relam == BTREE_AM_OID &&
		!index->hypothetical &&
		(index->indpred == NIL || index->predOK) &&
		index->sortopfamily != NULL &&
		index->sortopfamily[pos] == sort->opfamily &&
		index->opcintype[pos] == sort->type &&
		index->indexcollations[pos] == sort->collation &&
		(sort->notnull ||
		 (is_backward_stream(index, pos, sort) ? !index->nulls_first[pos] :
		  index->nulls_first[pos]) == sort->nulls_first);
}

/*
 * find_index_candidate
 *		Can the index produce sort_attno in order?  Every key column before it
 *		must be compared for equality with a value known at execution time.
 *		False when sort_attno is not a key column or an equality is missing.
 */
static bool
find_index_candidate(IntersectSearch *search, IndexOptInfo *index,
					 IndexCandidate *candidate)
{
	int			sortpos = -1;

	candidate->index = index;
	candidate->clauses = NIL;
	candidate->exprs = NIL;
	candidate->operators = NIL;
	candidate->collations = NIL;
	candidate->required_outer = NULL;
	candidate->heapkeyspace = -1;
	candidate->range_known = -1;
	candidate->correlation = -2.0;
	candidate->holds_nulls = -1;
	candidate->group_probes = NIL;

	for (int i = 0; i < index->nkeycolumns; i++)
	{
		if (index->indexkeys[i] == search->sort.attno)
		{
			sortpos = i;
			break;
		}
	}
	candidate->sortpos = sortpos;

	if (sortpos < 0 || !is_usable_btree(index, sortpos, &search->sort))
		return false;

	for (int i = 0; i < sortpos; i++)
	{
		IndexEquality equality;

		/* an expression column has no attno to compare with */
		if (index->indexkeys[i] == 0 ||
			!find_equality_clause(search->root, search->rel, search->rti,
								  index, i, &equality))
			return false;

		candidate->clauses = lappend(candidate->clauses, equality.clause);
		candidate->exprs = lappend(candidate->exprs, equality.expr);
		candidate->operators = lappend_oid(candidate->operators, equality.opno);
		candidate->collations = lappend_oid(candidate->collations,
											equality.collation);
		candidate->required_outer = bms_add_members(candidate->required_outer,
													equality.outer_relids);
	}

	candidate->backward = is_backward_stream(index, sortpos, &search->sort);
	candidate->entries = lf_index_entries(search->root, search->rti, candidate);

	return true;
}

/*
 * equality_column_in_set
 *		Is attno an equality column of some stream of the set other than
 *		skip?
 */
static bool
equality_column_in_set(IndexCandidate **streams, int nstreams,
					   IndexCandidate *skip, AttrNumber attno)
{
	for (int i = 0; i < nstreams; i++)
	{
		IndexOptInfo *index = streams[i]->index;

		if (streams[i] == skip)
			continue;
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
 *		Does the candidate narrow the rows of the set's other streams down:
 *		through an equality column no other stream has, or a predicate the
 *		other streams' equalities and predicates do not imply (predicate kind =
 *		2 is implied by an equality kind = 2 with a constant)?  A stream that
 *		adds nothing only makes the merge read more.  candidate may itself be
 *		one of streams: it is then compared with the others.
 */
static bool
adds_restriction(IndexCandidate **streams, int nstreams,
				 IndexCandidate *candidate)
{
	IndexOptInfo *index = candidate->index;

	for (int i = 0; i < candidate->sortpos; i++)
	{
		if (!equality_column_in_set(streams, nstreams, candidate,
									index->indexkeys[i]))
			return true;
	}

	if (index->indpred != NIL)
	{
		List	   *enforced = NIL;

		for (int i = 0; i < nstreams; i++)
		{
			if (streams[i] == candidate)
				continue;
			enforced = list_concat_copy(enforced, streams[i]->clauses);
			enforced = list_concat_copy(enforced, streams[i]->index->indpred);
		}
		if (!predicate_implied_by(index->indpred, enforced, false))
			return true;
	}

	return false;
}

/*
 * is_inner_candidate
 *		Can the index join the set as an inner stream: not in the set yet,
 *		adding a restriction of its own, and leaving every stream already in
 *		the set with one of its own?  A pair of (customer_id, id) and
 *		(customer_id, id) WHERE deleted_at IS NULL is not a set: the partial
 *		index alone enforces what the other does, and an Index Scan on it is
 *		the plan.
 */
static bool
is_inner_candidate(IndexCandidate **streams, int nstreams,
				   IndexCandidate *candidate)
{
	IndexCandidate *set[INTERSECT_MAX_STREAMS];

	if (!candidate->usable)
		return false;
	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i] == candidate)
			return false;
		set[i] = streams[i];
	}
	set[nstreams] = candidate;

	for (int i = 0; i <= nstreams; i++)
	{
		if (!adds_restriction(set, nstreams + 1, set[i]))
			return false;
	}

	return true;
}

/*
 * build_intersect_path
 *		Build and cost the Index Merge Intersect path for one set of streams;
 *		NULL when the set cannot be used.  correlation is
 *		lf_outer_index_correlation of the outer index.
 */
static CustomPath *
build_intersect_path(IntersectSearch *search, IndexCandidate **streams,
					 int nstreams, Cost *fetch_cost, double correlation)
{
	PlannerInfo *root = search->root;
	RelOptInfo *rel = search->rel;
	CustomPath *cpath;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer = NULL;
	double		group_bytes = 0;
	double		reads[INTERSECT_MAX_STREAMS];
	int			ranks[INTERSECT_MAX_STREAMS];

	if (search->ndistinct < 0)
		search->ndistinct = lf_sortcol_ndistinct(root, rel, search->rti,
												 search->sort.attno);

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

	lf_cost_intersect_path(cpath, root, search->rte, &search->sort,
						   streams, nstreams, search->ndistinct, correlation,
						   reads, ranks, fetch_cost);
	lf_trace.sets++;

	/*
	 * A CustomPath has no custom_exprs; the value expressions and the index
	 * predicates travel in custom_private and become the plan's custom_exprs
	 * in intersect_plan_path, where createplan.c turns outer-relation Vars
	 * into nestloop params and setrefs.c fixes up the rest.  The layout is
	 * the PRIVATE_* and STREAM_* positions.
	 */
	cpath->custom_private =
		list_make5(makeBoolConst(search->sort.descending, false),
				   make_int4_const(nstreams),
				   make_oid_const(search->sort.type),
				   make_oid_const(search->sort.opfamily),
				   make_oid_const(search->sort.collation));
	cpath->custom_private = lappend(cpath->custom_private,
									makeBoolConst(search->sort.nulls_first, false));
	cpath->custom_private = lappend(cpath->custom_private,
									makeBoolConst(search->sort.notnull, false));
	for (int i = 0; i < nstreams; i++)
	{
		cpath->custom_private = lappend(cpath->custom_private,
										make_oid_const(streams[i]->index->indexoid));
		cpath->custom_private = lappend(cpath->custom_private,
										make_int4_const(streams[i]->sortpos));
		cpath->custom_private = lappend(cpath->custom_private,
										make_float8_const(reads[i]));
		cpath->custom_private = lappend(cpath->custom_private,
										list_copy(streams[i]->operators));
		cpath->custom_private = lappend(cpath->custom_private,
										list_copy(streams[i]->collations));
		cpath->custom_private = lappend(cpath->custom_private,
										makeBoolConst(streams[i]->backward, false));
		cpath->custom_private = lappend(cpath->custom_private,
										make_int4_const(ranks[i]));
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
 *		scaled down: it skips the competition with other plans, but the sets
 *		still compete among themselves.  It can still be passed over for other
 *		reasons, such as disabled_nodes or a parameterization the join order
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
 * candidate_entries_cmp
 *		Fewest entries first; the OID makes it deterministic.
 */
static int
candidate_entries_cmp(const void *a, const void *b)
{
	const IndexCandidate *ca = (const IndexCandidate *) a;
	const IndexCandidate *cb = (const IndexCandidate *) b;

	if (ca->entries != cb->entries)
		return ca->entries < cb->entries ? -1 : 1;
	return pg_cmp_u32(ca->index->indexoid, cb->index->indexoid);
}

/*
 * build_set_path
 *		Build the path of a set of streams in merge order.  The outer stream is
 *		the densest without a predicate: the others are held in memory, value
 *		by value, so this keeps the groups small, and a predicate of the outer
 *		index would have to stay in the Filter.
 */
static CustomPath *
build_set_path(IntersectSearch *search, IndexCandidate **streams, int nstreams,
			   Cost *fetch_cost)
{
	IndexCandidate *ordered[INTERSECT_MAX_STREAMS];
	int			outer = 0;

	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i]->index->indpred == NIL)
			outer = i;
		ordered[i] = streams[i];
	}
	ordered[0] = streams[outer];
	ordered[outer] = streams[0];

	if (ordered[0]->correlation < -1.5)
		ordered[0]->correlation = lf_outer_index_correlation(search->root,
															 search->rti,
															 ordered[0]->index);

	return build_intersect_path(search, ordered, nstreams, fetch_cost,
								ordered[0]->correlation);
}

/*
 * search_intersection
 *		One pass over the candidates: a stream joins the set when it adds a
 *		restriction, even if the set costs more with it.  The cheapest set seen
 *		is offered, along with the one quickest to its first row when that is
 *		another: a stream that lowers the total can make the query wait for one
 *		more first group, which a LIMIT pays for.  A set smaller than
 *		leapfrog.min_indexes is not offered, and the first to reach it is kept
 *		whatever its cost, so a test can run a larger set against the stock
 *		plans.  With plain_only the candidates that need a parameter stay out,
 *		so that the unparameterized set has its own chance.
 */
static void
search_intersection(IntersectSearch *search, bool plain_only)
{
	IndexCandidate *streams[INTERSECT_MAX_STREAMS];
	int			nstreams = 0;
	CustomPath *best = NULL;
	CustomPath *quickest = NULL;
	Cost		best_cost = 0;
	Cost		fetch_cost = 0;
	Cost		last_cost = 0;

	for (int j = 0; j < search->ncandidates &&
		 nstreams < intersect_max_streams; j++)
	{
		IndexCandidate *candidate = &search->candidates[j];
		CustomPath *cpath;

		if (plain_only && !bms_is_empty(candidate->required_outer))
			continue;
		if (nstreams == 0)
		{
			streams[nstreams++] = candidate;
			continue;
		}
		if (!is_inner_candidate(streams, nstreams, candidate))
			continue;

		/*
		 * A stream saves at most the rows fetched from the heap and adds at
		 * least its descent and a leaf page.  When the set cannot get below
		 * the cheapest one that way, skip the stream's costing and range
		 * probe.  There is no cheapest set before leapfrog.min_indexes is
		 * reached.  This leaves out what a narrower overlap of the ranges
		 * could save on the other streams, which only the probe would tell.
		 */
		if (best != NULL &&
			last_cost - fetch_cost + lf_stream_min_cost(candidate->index) >=
			best_cost)
		{
			lf_trace.pruned++;
			continue;
		}

		streams[nstreams] = candidate;
		cpath = build_set_path(search, streams, nstreams + 1, &fetch_cost);
		if (cpath == NULL)
			continue;
		nstreams++;
		last_cost = cpath->path.total_cost;

		if (nstreams >= intersect_min_streams &&
			(best == NULL || cpath->path.total_cost < best_cost))
		{
			best = cpath;
			best_cost = cpath->path.total_cost;
		}
		if (nstreams >= intersect_min_streams &&
			(quickest == NULL ||
			 cpath->path.startup_cost < quickest->path.startup_cost))
			quickest = cpath;
	}

	if (quickest != NULL && quickest != best)
		add_intersect_path(search->rel, quickest);
	if (best != NULL)
		add_intersect_path(search->rel, best);
}

/*
 * intersect_set_rel_pathlist
 *		set_rel_pathlist_hook: offer Index Merge Intersect paths for the
 *		relation.  A partition is a relation of its own here: its sorted path
 *		goes into the parent's MergeAppend or ordered Append, and a partition
 *		without one is sorted there.  The partitioned parent has no storage.
 */
static void
intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
						   RangeTblEntry *rte)
{
	IntersectSearch search;
	EquivalenceMemberIterator it;
	EquivalenceMember *em;
	ListCell   *lc;

	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	/* a sampled relation is read through its Sample Scan only */
	if (!intersect_enabled || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION || rte->tablesample != NULL ||
		!IS_SIMPLE_REL(rel) || root->query_pathkeys == NIL ||
		IS_DUMMY_REL(rel) || rel->indexlist == NIL)
		return;

	search.root = root;
	search.rel = rel;
	search.rti = rti;
	search.rte = rte;
	search.sort.attno = InvalidAttrNumber;
	search.ndistinct = -1.0;

	/* the sort column: a column of this relation */
	search.pathkey = linitial_node(PathKey, root->query_pathkeys);
	setup_eclass_member_iterator(&it, search.pathkey->pk_eclass, rel->relids);
	while ((em = eclass_member_iterator_next(&it)) != NULL)
	{
		Node	   *expr = (Node *) em->em_expr;
		AttrNumber	attno;

		while (IsA(expr, RelabelType))
			expr = (Node *) ((RelabelType *) expr)->arg;
		if (!IsA(expr, Var))
			continue;
		attno = ((Var *) expr)->varattno;
		if (attno > 0 && pathkey_is_column(search.pathkey, rel, rti, attno))
		{
			search.sort.attno = attno;
			search.sort.type = em->em_datatype;
			search.sort.opfamily = search.pathkey->pk_opfamily;
			search.sort.collation = search.pathkey->pk_eclass->ec_collation;
			search.sort.descending = search.pathkey->pk_cmptype == COMPARE_GT;
			search.sort.nulls_first = search.pathkey->pk_nulls_first;
			search.sort.notnull = is_notnull_column(rel, attno);
			search.sort.null_frac = -1.0;
			search.sort.range_ssup_ready = false;
			search.sort.stats = NULL;
			break;
		}
	}

	if (search.sort.attno == InvalidAttrNumber)
		return;

	/*
	 * Each index is checked once; the sets are formed from those that can
	 * produce sortcol in order, usually a few of the relation's.
	 */
	search.candidates = palloc(list_length(rel->indexlist) *
							   sizeof(IndexCandidate));
	search.ncandidates = 0;
	memset(&lf_trace, 0, sizeof(lf_trace));
	foreach(lc, rel->indexlist)
	{
		IndexCandidate *candidate = &search.candidates[search.ncandidates];

		candidate->usable = find_index_candidate(&search,
												 lfirst_node(IndexOptInfo, lc),
												 candidate);
		if (candidate->usable)
			search.ncandidates++;
	}

	qsort(search.candidates, search.ncandidates, sizeof(IndexCandidate),
		  candidate_entries_cmp);

	search_intersection(&search, true);
	for (int i = 0; i < search.ncandidates; i++)
	{
		if (!bms_is_empty(search.candidates[i].required_outer))
		{
			search_intersection(&search, false);
			break;
		}
	}

	lf_trace.candidates = search.ncandidates;
	if (intersect_trace_planner)
		elog(NOTICE,
			 "leapfrog planner: %d candidates, %d sets, %d range scans, %d statistics reads, %d range fallbacks, %d correlations, %d pruned",
			 lf_trace.candidates, lf_trace.sets, lf_trace.range_scans,
			 lf_trace.stat_loads, lf_trace.range_fallbacks,
			 lf_trace.correlations, lf_trace.pruned);

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
		IndexEquality equality;

		if (match_index_equality(rinfo, rti, index, i, &equality) &&
			equal(equality.expr, lfirst(lc)))
			return true;
		i++;
	}

	return false;
}

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
 * lf_node_quals
 *		The clauses the node still evaluates on a fetched row, as
 *		create_indexscan_plan computes qpqual.  The equalities of every stream
 *		are enforced by the scan keys and rechecked by intersect_recheck, so
 *		they are dropped.  So are clauses implied by the predicate of an inner
 *		index, except for a target relation of UPDATE/DELETE/SELECT FOR UPDATE,
 *		where check_index_predicates keeps them for EvalPlanQual.  The cost
 *		model charges exactly these clauses.  indexes[0] is the outer index,
 *		exprs[i] the value expressions of stream i.
 *
 * Clauses implied by the predicate of a partial outer index are never
 * dropped: the node does not keep that predicate, so under EvalPlanQual
 * only this qual checks it on the new row version (leapfrog_outer_partial).
 */
List *
lf_node_quals(PlannerInfo *root, RelOptInfo *rel, IndexOptInfo **indexes,
			  List **exprs, int nstreams, List *clauses)
{
	bool		is_target_rel;
	List	   *qpqual = NIL;
	ListCell   *lc;

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

			if (is_candidate_equality(rinfo, rel->relid, indexes[i], exprs[i]))
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

	return qpqual;
}

static List *
intersect_scan_qual(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *clauses)
{
	int			nstreams = path_nstreams(best_path);
	IndexOptInfo *indexes[INTERSECT_MAX_STREAMS];
	List	   *exprs[INTERSECT_MAX_STREAMS];

	for (int i = 0; i < nstreams; i++)
	{
		indexes[i] = find_index_info(rel, path_stream_oid(best_path, i));
		exprs[i] = path_stream_exprs(best_path, i, STREAM_EXPRS_KEYS);
	}

	return extract_actual_clauses(lf_node_quals(root, rel, indexes, exprs,
												nstreams, clauses),
								  false);
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

void
lf_planner_init(void)
{
	prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = intersect_set_rel_pathlist;
}
