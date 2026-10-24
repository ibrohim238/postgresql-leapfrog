/*-------------------------------------------------------------------------
 *
 * planner.c
 *	  Planner side of the Index Merge Intersect custom scan: the
 *	  set_rel_pathlist hook that finds index pairs and offers their paths,
 *	  and the conversion of the chosen path into a CustomScan plan.
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
 * Argument of ec_member_is_column, the callback of
 * generate_implied_equalities_for_column.
 */
typedef struct ColumnMatchArg
{
	Index		rti;
	AttrNumber	attno;
} ColumnMatchArg;

/*
 * Under leapfrog.force the paths keep their relative costs, scaled down so
 * far that no other path can be cheaper: add_path compares costs by ratio,
 * so the cheapest index pair still wins among the pairs.
 */
#define INTERSECT_FORCE_SCALE 1e-12

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
 *		operator family of the query's sort key, so that both sides of the
 *		merge produce values in the order the query asks for.  NULLs
 *		ordering is not checked: the sort column is NOT NULL.  Whether the
 *		duplicates are ordered by TID is checked last, by is_heapkeyspace,
 *		for the pairs that pass everything else: it opens the index.
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
find_index_candidate(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 RangeTblEntry *rte, IndexOptInfo *index,
					 AttrNumber sort_attno, PathKey *pathkey,
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
		if (index->indexkeys[i] == sort_attno)
		{
			sortpos = i;
			break;
		}
	}
	candidate->sortpos = sortpos;

	if (sortpos < 0 || !is_usable_btree(index, sortpos, pathkey))
		return false;

	for (int i = 0; i < sortpos; i++)
	{
		AttrNumber	attno = index->indexkeys[i];
		RestrictInfo *clause;
		Node	   *expr;
		Relids		outer_relids;

		/* the scan keys use int8 operators of the integer family */
		if (!is_int8_column(rte, attno) ||
			index->opfamily[i] != INTEGER_BTREE_FAM_OID)
			return false;

		clause = find_equality_clause(root, rel, rti, attno, &expr,
									  &outer_relids);
		if (clause == NULL)
			return false;

		candidate->clauses = lappend(candidate->clauses, clause);
		candidate->exprs = lappend(candidate->exprs, expr);
		candidate->required_outer = bms_add_members(candidate->required_outer,
													outer_relids);
	}

	return true;
}

/*
 * is_outer_candidate
 *		Can the index be the outer side of the intersection: at least one
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
 * adds_restriction
 *		Does the inner index narrow the outer stream down?  A partial index
 *		does through its predicate; an ordinary one only through an equality
 *		column the outer index does not have.
 */
static bool
adds_restriction(IndexOptInfo *outer, IndexOptInfo *inner, int inner_sortpos)
{
	if (inner->indpred != NIL)
		return true;

	for (int i = 0; i < inner_sortpos; i++)
	{
		bool		in_outer = false;

		for (int j = 0; j < outer->nkeycolumns - 1; j++)
		{
			if (outer->indexkeys[j] == inner->indexkeys[i])
				in_outer = true;
		}
		if (!in_outer)
			return true;
	}

	return false;
}

/*
 * is_inner_candidate
 *		Can the index be the inner side of the intersection for the given
 *		outer index: (j1, ..., jM, sortcol, ...) with equalities on every jI,
 *		partial or adding an equality column of its own?
 */
static bool
is_inner_candidate(IndexCandidate *outer, IndexCandidate *inner)
{
	return inner->usable && inner != outer &&
		adds_restriction(outer->index, inner->index, inner->sortpos);
}

/*
 * add_intersect_path
 *		Build and cost the Index Merge Intersect path for one index pair and
 *		offer it to add_path.  ndistinct is lf_sortcol_ndistinct and
 *		correlation lf_outer_index_correlation of the outer index, both
 *		computed once by the caller.
 */
static void
add_intersect_path(PlannerInfo *root, RelOptInfo *rel, Index rti,
				   RangeTblEntry *rte, AttrNumber sort_attno,
				   PathKey *pathkey, IndexCandidate *outer_candidate,
				   IndexCandidate *inner_candidate, double ndistinct,
				   double correlation)
{
	IndexOptInfo *outer = outer_candidate->index;
	IndexOptInfo *inner = inner_candidate->index;
	CustomPath *cpath;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer;
	double		outer_entries;
	double		inner_entries;
	double		outer_read;
	double		inner_read;
	double		group_size;

	outer_entries = lf_index_entries(root, rti, outer, outer_candidate);
	inner_entries = lf_index_entries(root, rti, inner, inner_candidate);

	/*
	 * The TID group of one value is expected to fit into work_mem.  This is
	 * an estimate over the average value; the executor enforces the limit
	 * itself, so under leapfrog.force the estimate is ignored.
	 */
	group_size = Max(1.0, inner_entries / ndistinct);
	if (!intersect_force &&
		group_size * sizeof(ItemPointerData) > work_mem * 1024.0)
		return;

	/* duplicates must be ordered by TID on both sides */
	if (!is_heapkeyspace(outer_candidate) || !is_heapkeyspace(inner_candidate))
		return;

	/* a LATERAL reference makes the path parameterized by those rels */
	required_outer = bms_union(outer_candidate->required_outer,
							   inner_candidate->required_outer);
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
	cpath->path.pathkeys = list_make1(pathkey);
	cpath->flags = 0;
	cpath->methods = &intersect_path_methods;

	lf_cost_intersect_path(cpath, root, rte, sort_attno, outer_candidate,
						   inner_candidate, outer_entries, inner_entries,
						   group_size, correlation, &outer_read, &inner_read);

	/*
	 * A CustomPath has no custom_exprs; the value expressions and the inner
	 * index predicate travel in custom_private and become the plan's
	 * custom_exprs in intersect_plan_path, where createplan.c turns
	 * outer-relation Vars into nestloop params and setrefs.c fixes up the
	 * rest.  The layout is the PRIVATE_* and EXPRS_* positions.
	 */
	cpath->custom_private =
		list_make4(make_oid_const(outer->indexoid),
				   make_oid_const(inner->indexoid),
				   makeBoolConst(pathkey->pk_cmptype == COMPARE_GT, false),
				   makeConst(INT4OID, -1, InvalidOid, sizeof(int32),
							 Int32GetDatum(inner_candidate->sortpos),
							 false, true));
	cpath->custom_private = lappend(cpath->custom_private,
									make_float8_const(outer_read));
	cpath->custom_private = lappend(cpath->custom_private,
									make_float8_const(inner_read));
	cpath->custom_private = lappend(cpath->custom_private,
									copyObject(outer_candidate->exprs));
	cpath->custom_private = lappend(cpath->custom_private,
									copyObject(inner->indpred));
	cpath->custom_private = lappend(cpath->custom_private,
									copyObject(inner_candidate->exprs));

	/*
	 * With leapfrog.force the competition with the other plans is skipped,
	 * like MySQL does for the INDEX_MERGE hint, but the pairs still compete
	 * among themselves.  The path can still be passed over for reasons other
	 * than cost, such as disabled_nodes or a parameterization the join order
	 * cannot provide.
	 */
	if (intersect_force)
	{
		cpath->path.startup_cost *= INTERSECT_FORCE_SCALE;
		cpath->path.total_cost *= INTERSECT_FORCE_SCALE;
	}

	add_path(rel, &cpath->path);
}

/*
 * intersect_set_rel_pathlist
 *		set_rel_pathlist_hook: offer Index Merge Intersect paths for every
 *		suitable pair of indexes of the relation.
 */
static void
intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti,
						   RangeTblEntry *rte)
{
	PathKey    *pathkey;
	AttrNumber	sort_attno = InvalidAttrNumber;
	IndexCandidate *candidates;
	int			ncandidates = 0;
	double		ndistinct = -1.0;
	ListCell   *lc;

	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	if (!intersect_enabled || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION ||
		rel->reloptkind != RELOPT_BASEREL || root->query_pathkeys == NIL ||
		IS_DUMMY_REL(rel) || rel->indexlist == NIL)
		return;

	/* the sort column: a bigint NOT NULL column of this relation */
	pathkey = linitial_node(PathKey, root->query_pathkeys);
	foreach(lc, pathkey->pk_eclass->ec_members)
	{
		EquivalenceMember *em = (EquivalenceMember *) lfirst(lc);
		AttrNumber	attno;

		if (!IsA(em->em_expr, Var))
			continue;
		attno = ((Var *) em->em_expr)->varattno;
		if (attno > 0 && pathkey_is_column(pathkey, rti, attno) &&
			is_int8_column(rte, attno) && is_notnull_column(rel, attno))
		{
			sort_attno = attno;
			break;
		}
	}

	if (sort_attno == InvalidAttrNumber)
		return;

	/*
	 * Each index is checked once; the pairs are then formed from the indexes
	 * that can produce sortcol in order, usually a few of the relation's.
	 */
	candidates = palloc(list_length(rel->indexlist) * sizeof(IndexCandidate));
	foreach(lc, rel->indexlist)
	{
		IndexCandidate *candidate = &candidates[ncandidates];

		candidate->usable = find_index_candidate(root, rel, rti, rte,
												 lfirst_node(IndexOptInfo, lc),
												 sort_attno, pathkey,
												 candidate);
		if (candidate->usable)
			ncandidates++;
	}

	for (int i = 0; i < ncandidates; i++)
	{
		IndexCandidate *outer = &candidates[i];
		double		correlation = 0.0;
		bool		has_correlation = false;

		if (!is_outer_candidate(outer))
			continue;

		for (int j = 0; j < ncandidates; j++)
		{
			IndexCandidate *inner = &candidates[j];

			if (!is_inner_candidate(outer, inner))
				continue;

			if (ndistinct < 0)
				ndistinct = lf_sortcol_ndistinct(root, rel, rti, sort_attno);
			if (!has_correlation)
			{
				correlation = lf_outer_index_correlation(root, rti,
														 outer->index);
				has_correlation = true;
			}
			add_intersect_path(root, rel, rti, rte, sort_attno, pathkey,
							   outer, inner,
							   ndistinct, correlation);
		}
	}

	pfree(candidates);
}

/*
 * is_candidate_equality
 *		Is the clause one of the equalities the outer index enforces: column
 *		i of the index compared with the i-th value expression?
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

/*
 * path_private_oid
 *		An index OID stored in the path's custom_private.
 */
static Oid
path_private_oid(CustomPath *best_path, int pos)
{
	return DatumGetObjectId(list_nth_node(Const, best_path->custom_private,
										  pos)->constvalue);
}

/*
 * intersect_scan_qual
 *		The quals the node still has to evaluate, as create_indexscan_plan
 *		computes qpqual: the equalities on the columns of both indexes are
 *		enforced by the scan keys and rechecked under EvalPlanQual by
 *		intersect_recheck, so they are dropped.  Clauses implied by the inner
 *		index predicate are dropped as well, except for a target relation of
 *		UPDATE/DELETE/SELECT FOR UPDATE, where check_index_predicates keeps
 *		them in the plan for EvalPlanQual.
 *
 * Clauses implied by the predicate of a partial outer index are never
 * dropped: the node does not keep that predicate, so under EvalPlanQual
 * only this qual checks it on the new row version (leapfrog_outer_partial).
 */
static List *
intersect_scan_qual(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *clauses)
{
	List	   *outer_exprs = list_nth(best_path->custom_private,
									   PRIVATE_COUNT + EXPRS_OUTER_KEYS);
	List	   *indpred = list_nth(best_path->custom_private,
								   PRIVATE_COUNT + EXPRS_INNER_PRED);
	List	   *inner_exprs = list_nth(best_path->custom_private,
									   PRIVATE_COUNT + EXPRS_INNER_KEYS);
	IndexOptInfo *outer;
	IndexOptInfo *inner;
	bool		is_target_rel;
	List	   *qpqual = NIL;
	ListCell   *lc;

	outer = find_index_info(rel, path_private_oid(best_path,
												  PRIVATE_OUTER_INDEX));
	inner = find_index_info(rel, path_private_oid(best_path,
												  PRIVATE_INNER_INDEX));

	is_target_rel = (bms_is_member(rel->relid, root->all_result_relids) ||
					 get_plan_rowmark(root->rowMarks, rel->relid) != NULL);

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);

		if (rinfo->pseudoconstant)
			continue;
		if (is_candidate_equality(rinfo, rel->relid, outer, outer_exprs) ||
			is_candidate_equality(rinfo, rel->relid, inner, inner_exprs))
			continue;
		if (!is_target_rel && indpred != NIL &&
			!contain_mutable_functions((Node *) rinfo->clause) &&
			predicate_implied_by(list_make1(rinfo->clause), indpred, false))
			continue;
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

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = intersect_scan_qual(root, rel, best_path, clauses);
	cscan->scan.scanrelid = rel->relid;
	cscan->flags = best_path->flags;
	cscan->custom_private = list_truncate(list_copy(private), PRIVATE_COUNT);
	cscan->custom_exprs =
		list_make3(list_nth(private, PRIVATE_COUNT + EXPRS_OUTER_KEYS),
				   list_nth(private, PRIVATE_COUNT + EXPRS_INNER_PRED),
				   list_nth(private, PRIVATE_COUNT + EXPRS_INNER_KEYS));
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
