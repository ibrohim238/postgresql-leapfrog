/*-------------------------------------------------------------------------
 *
 * leapfrog.c
 *	  Index Merge Intersect custom scan: intersection of two btree indexes
 *	  by merging their sorted streams, modeled on MySQL's index merge
 *	  intersection (RowIDIntersectionIterator, ROR_intersect_plan).
 *
 * For every base relation of the query an index pair is chosen
 * automatically:
 *
 *	- the outer index (k1, ..., kN, sortcol): every kI is compared for
 *	  equality with a value known at execution time (a constant, a query
 *	  parameter or a column of an outer relation), and its last column is
 *	  the first sort key of the query;
 *	- the inner index is a partial index (sortcol, ...) WHERE predicate:
 *	  it starts with the same column and its predicate is implied by the
 *	  query's restrictions.
 *
 * The outer index ends with the column the inner index starts with; only
 * then do both produce sortcol values in the same order.
 *
 * Execution follows RowIDIntersectionIterator::DoRead: both indexes are
 * read sequentially in the same direction and the side that lags behind is
 * advanced until the values meet.  MySQL merges rowids; here the entries of
 * one value are matched by heap TID as well, so the merge stays correct when
 * sortcol is not unique or dead row versions are still in the index.  The
 * TIDs of one value are not in a usable order on both sides (a backward scan
 * returns posting-list TIDs ascending), so the inner entries of the value
 * are collected into a sorted group and the outer entries are looked up in
 * it.  The group lives in memory: the path is offered only when the
 * estimated number of inner entries per value fits into work_mem, and at
 * execution time a group that outgrows work_mem is abandoned for that value.
 * The outer entries of such a value are all fetched from the heap and
 * checked against the inner index predicate explicitly, before the node's
 * qual sees them, so the fallback does not depend on what the qual holds.
 * The heap is otherwise visited only for matches, walking HOT chains the
 * way index_getnext_slot does.
 *
 * Only the standard integer btree operator family is supported: the scan
 * keys are built with int8 operators, so both the equality columns and the
 * merge column must belong to it.
 *
 * Costing follows ROR_intersect_plan::add, with every component expressed
 * through the planner's own cost functions:
 *
 *	  run = index_read_cost(outer, rows matching the equalities)
 *		   + index_read_cost(inner, all entries of the partial index)
 *		   + cost of grouping the entries of one value
 *		   + cost of fetching the result rows from the heap
 *		   + cost of the node's qual and target list per result row
 *	  startup = descent into both btrees (CPU, as btcostestimate charges it)
 *			  + the share of run spent before the first match
 *	  total = startup + run
 *
 * Index pages are charged like genericcostestimate does (random_page_cost
 * per page, Mackert-Lohman for repeated scans inside a nestloop), the heap
 * pages like cost_index does: between the perfectly correlated and the
 * uncorrelated case by the squared correlation of the sort column, which is
 * the order the heap is visited in.  Tablespace page costs are honoured.
 *
 * Documented assumptions, not derived from statistics: the matches are
 * spread evenly along both indexes (so a LIMIT is served by a proportional
 * fraction of the total, as the planner assumes for every path), and the
 * TID group of one value has the average size.  Skewed data can make either
 * side much more expensive than predicted.
 *
 * leapfrog.force is the counterpart of MySQL's INDEX_MERGE hint
 * (ignore_cost in ROR_intersect_plan::add): the intersection is chosen
 * whenever a suitable index pair exists, regardless of cost.  It is a
 * diagnostic knob and can make a query far slower.
 *
 * Under EvalPlanQual the scan rechecks what it guaranteed by construction,
 * as an index scan rechecks indexqualorig: the equalities on the outer
 * index columns and the predicate of the inner index.
 *
 * Limitations: key columns must be bigint and the scan covers a single
 * relation only.
 *
 * The library installs set_rel_pathlist_hook from _PG_init, so it must be
 * loaded into the backend: shared_preload_libraries, session_preload_libraries
 * or LOAD.  CREATE EXTENSION registers SQL helpers only; PostgreSQL never
 * unloads a shared library, so the hook stays until the backend exits and
 * leapfrog.enabled = off is the way to switch it off.
 *
 * IDENTIFICATION
 *	  src/leapfrog.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>
#include <math.h>

#include "access/cmptype.h"
#include "access/genam.h"
#include "access/nbtree.h"
#include "access/relscan.h"
#include "access/stratnum.h"
#include "catalog/pg_am_d.h"
#include "catalog/pg_opfamily_d.h"
#include "catalog/pg_statistic.h"
#include "catalog/pg_type.h"
#include "commands/explain_format.h"
#include "executor/executor.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "nodes/extensible.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/prep.h"
#include "optimizer/restrictinfo.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"
#include "utils/spccache.h"

PG_MODULE_MAGIC_EXT(
					.name = "leapfrog",
					.version = LEAPFROG_VERSION
);

#define INTERSECT_NAME "Index Merge Intersect"

/* GUC variables */
static bool intersect_enabled = true;
static bool intersect_force = false;

/* Saved hook value */
static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook = NULL;

/* Set once the hook is installed */
static bool intersect_hook_installed = false;

/*
 * Execution state of an Index Merge Intersect scan.
 */
typedef struct IntersectScanState
{
	CustomScanState css;
	Relation	outer_index;	/* (k1, ..., kN, sortcol) */
	Relation	inner_index;	/* partial (sortcol, ...) */
	IndexScanDesc outer_scan;
	IndexScanDesc inner_scan;
	int			nequal;			/* number of equality columns of outer */
	ExprState  *equal_exprs[INDEX_MAX_KEYS];
	Oid			equal_types[INDEX_MAX_KEYS];
	int64		equal_values[INDEX_MAX_KEYS];
	AttrNumber	equal_attnos[INDEX_MAX_KEYS];	/* heap columns, for EPQ */
	bool		values_ready;	/* equal_values are evaluated */
	bool		values_null;	/* some equality value is NULL */
	ExprState  *inner_pred;		/* predicate of the inner partial index */
	bool		descending;
	bool		started;
	bool		done;
	bool		have_outer;		/* outer entry is not consumed yet */
	bool		have_inner;		/* inner entry is not consumed yet */
	bool		inner_eof;
	bool		fetching_match; /* heap fetch of a matched entry in progress */
	bool		match_by_pred;	/* the match comes from an overflowed group */
	int64		outer_value;
	int64		inner_value;
	ItemPointerData outer_tid;
	ItemPointerData inner_tid;
	/* inner TIDs of the value being matched, sorted */
	bool		in_group;
	bool		group_overflow; /* group exceeded work_mem: match by qual */
	int64		group_value;
	ItemPointerData *group_tids;
	int			group_count;
	int			group_capacity;
	int			group_limit;	/* entries that fit into work_mem */

	/* instrumentation, summed over all rescans */
	int64		outer_read;
	int64		inner_read;
	int64		matched;		/* TIDs found on both sides */
	int64		pred_checked;	/* overflow entries checked by predicate */
	int64		heap_fetches;
	int64		group_overflows;
	int			peak_capacity;	/* largest group array allocated */
} IntersectScanState;

/*
 * Outer index candidate: equality clauses of its leading columns, the
 * value expressions compared against, and the outer rels they refer to.
 */
typedef struct OuterCandidate
{
	List	   *clauses;
	List	   *exprs;
	Relids		required_outer;
} OuterCandidate;

/*
 * Argument of ec_member_is_column, the callback of
 * generate_implied_equalities_for_column.
 */
typedef struct ColumnMatchArg
{
	Index		rti;
	AttrNumber	attno;
} ColumnMatchArg;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(leapfrog_version);
PG_FUNCTION_INFO_V1(leapfrog_is_loaded);

static void intersect_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel,
									   Index rti, RangeTblEntry *rte);
static Plan *intersect_plan_path(PlannerInfo *root, RelOptInfo *rel,
								 CustomPath *best_path, List *tlist,
								 List *clauses, List *custom_plans);
static Node *intersect_create_scan_state(CustomScan *cscan);
static void intersect_begin(CustomScanState *node, EState *estate,
							int eflags);
static TupleTableSlot *intersect_exec(CustomScanState *node);
static void intersect_end(CustomScanState *node);
static void intersect_rescan(CustomScanState *node);
static void intersect_explain(CustomScanState *node, List *ancestors,
							  ExplainState *es);

static const CustomPathMethods intersect_path_methods = {
	.CustomName = INTERSECT_NAME,
	.PlanCustomPath = intersect_plan_path,
};

static const CustomScanMethods intersect_scan_methods = {
	.CustomName = INTERSECT_NAME,
	.CreateCustomScanState = intersect_create_scan_state,
};

static const CustomExecMethods intersect_exec_methods = {
	.CustomName = INTERSECT_NAME,
	.BeginCustomScan = intersect_begin,
	.ExecCustomScan = intersect_exec,
	.EndCustomScan = intersect_end,
	.ReScanCustomScan = intersect_rescan,
	.ExplainCustomScan = intersect_explain,
};

static Const *
make_oid_const(Oid value)
{
	return makeConst(OIDOID, -1, InvalidOid, sizeof(Oid),
					 ObjectIdGetDatum(value), false, true);
}

/*
 * datum_get_int64
 *		Return an int2/int4/int8 datum as int64.
 */
static int64
datum_get_int64(Datum value, Oid type)
{
	switch (type)
	{
		case INT2OID:
			return DatumGetInt16(value);
		case INT4OID:
			return DatumGetInt32(value);
		default:
			return DatumGetInt64(value);
	}
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
is_heapkeyspace(Oid indexoid)
{
	Relation	index = index_open(indexoid, AccessShareLock);
	bool		heapkeyspace;
	bool		allequalimage;

	_bt_metaversion(index, &heapkeyspace, &allequalimage);
	index_close(index, AccessShareLock);

	return heapkeyspace;
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
 * find_outer_candidate
 *		Check whether index can be the outer side of the intersection.
 *
 * Every key column but the last must be compared for equality with a value
 * known at execution time, and the last key column must be sort_attno.
 */
static bool
find_outer_candidate(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 RangeTblEntry *rte, IndexOptInfo *index,
					 AttrNumber sort_attno, PathKey *pathkey,
					 OuterCandidate *candidate)
{
	int			last = index->nkeycolumns - 1;

	candidate->clauses = NIL;
	candidate->exprs = NIL;
	candidate->required_outer = NULL;

	if (index->nkeycolumns < 2 || index->indexkeys[last] != sort_attno ||
		!is_usable_btree(index, last, pathkey))
		return false;

	for (int i = 0; i < last; i++)
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
 * is_inner_index
 *		Check whether index can be the inner side of the intersection.
 *
 * It must be a partial index starting with sort_attno whose predicate is
 * implied by the query's restrictions.
 */
static bool
is_inner_index(IndexOptInfo *index, AttrNumber sort_attno, PathKey *pathkey)
{
	return index->indpred != NIL && index->indexkeys[0] == sort_attno &&
		is_usable_btree(index, 0, pathkey);
}

/*
 * index_read_cost
 *		Cost of reading the given number of index entries sequentially,
 *		the counterpart of MySQL's index_read_cost.  Pages are charged the
 *		way genericcostestimate charges them: random_page_cost of the
 *		index's tablespace per page, and for a scan repeated loop_count
 *		times inside a nestloop the Mackert-Lohman estimate of the pages
 *		actually fetched, divided by the number of repetitions.
 */
static Cost
index_read_cost(PlannerInfo *root, IndexOptInfo *index, double entries,
				double loop_count)
{
	double		pages = 1.0;
	double		spc_random_page_cost;

	if (index->pages > 1 && index->tuples > 1)
		pages = ceil(entries * index->pages / index->tuples);

	get_tablespace_page_costs(index->reltablespace, &spc_random_page_cost,
							  NULL);

	if (loop_count > 1)
	{
		double		fetched;

		fetched = index_pages_fetched(pages * loop_count, index->pages,
									  (double) index->pages, root);
		pages = fetched / loop_count;
	}

	return pages * spc_random_page_cost + entries * cpu_index_tuple_cost;
}

/*
 * sort_column_correlation
 *		Correlation of the sort column with the heap order, from the same
 *		pg_statistic slot btcostestimate reads for the leading index column.
 *		Zero (no correlation) when there are no statistics.
 */
static double
sort_column_correlation(PlannerInfo *root, Index rti, AttrNumber sort_attno,
						IndexOptInfo *inner)
{
	Var		   *var = makeVar(rti, sort_attno, INT8OID, -1, InvalidOid, 0);
	VariableStatData vardata;
	AttStatsSlot sslot;
	Oid			sortop;
	double		correlation = 0.0;

	examine_variable(root, (Node *) var, 0, &vardata);
	if (!HeapTupleIsValid(vardata.statsTuple))
	{
		ReleaseVariableStats(vardata);
		return 0.0;
	}

	sortop = get_opfamily_member(inner->opfamily[0], inner->opcintype[0],
								 inner->opcintype[0], BTLessStrategyNumber);
	if (OidIsValid(sortop) &&
		get_attstatsslot(&sslot, vardata.statsTuple,
						 STATISTIC_KIND_CORRELATION, sortop,
						 ATTSTATSSLOT_NUMBERS))
	{
		Assert(sslot.nnumbers == 1);
		correlation = sslot.numbers[0];
		free_attstatsslot(&sslot);
	}

	ReleaseVariableStats(vardata);

	return correlation;
}

/*
 * heap_fetch_cost
 *		Cost of fetching the result rows from the heap, the counterpart of
 *		MySQL's get_sweep_read_cost, charged the way cost_index charges heap
 *		pages: the rows are visited in sort column order, so the number of
 *		pages lies between the perfectly correlated case (consecutive pages,
 *		read sequentially) and the uncorrelated case (Mackert-Lohman), and
 *		the squared correlation interpolates between them.
 */
static Cost
heap_fetch_cost(PlannerInfo *root, RelOptInfo *rel, double rows,
				double loop_count, double correlation, double pages_scanned)
{
	double		spc_random_page_cost;
	double		spc_seq_page_cost;
	double		pages_fetched;
	Cost		max_IO_cost;
	Cost		min_IO_cost;
	double		csquared;

	get_tablespace_page_costs(rel->reltablespace, &spc_random_page_cost,
							  &spc_seq_page_cost);

	/* uncorrelated: every row may be on a page of its own */
	pages_fetched = index_pages_fetched(rows * loop_count, rel->pages,
										pages_scanned, root);
	max_IO_cost = pages_fetched * spc_random_page_cost / loop_count;

	/*
	 * Correlated: the rows sit on consecutive pages, their share of the heap,
	 * as cost_index computes it from the index selectivity.
	 */
	pages_fetched = 1.0;
	if (rel->tuples > 0)
		pages_fetched = ceil(rows / rel->tuples * rel->pages);
	pages_fetched = Max(pages_fetched, 1.0);
	if (loop_count > 1)
	{
		pages_fetched = index_pages_fetched(pages_fetched * loop_count,
											rel->pages, pages_scanned, root);
		min_IO_cost = pages_fetched * spc_random_page_cost / loop_count;
	}
	else if (pages_fetched > 0)
		min_IO_cost = spc_random_page_cost +
			(pages_fetched - 1) * spc_seq_page_cost;
	else
		min_IO_cost = 0;

	csquared = correlation * correlation;

	return max_IO_cost + csquared * (min_IO_cost - max_IO_cost);
}

/*
 * group_cost
 *		Cost of sorting the inner entries of each value and looking the
 *		outer entries up in them: log2 of the group size per entry.
 */
static Cost
group_cost(double outer_entries, double inner_entries, double group_size)
{
	return (outer_entries + inner_entries) * cpu_operator_cost *
		log2(group_size + 1);
}

/*
 * loop_count_for
 *		How many times a path parameterized by outer_relids is expected to be
 *		rescanned inside a nestloop: the smallest row estimate among the
 *		outer rels, as indxpath.c's get_loop_count computes it (without the
 *		semijoin adjustment, which is private to that file).
 */
static double
loop_count_for(PlannerInfo *root, Relids outer_relids)
{
	double		result = 0.0;
	int			outer_relid = -1;

	if (outer_relids == NULL)
		return 1.0;

	while ((outer_relid = bms_next_member(outer_relids, outer_relid)) >= 0)
	{
		RelOptInfo *outer_rel;

		if (outer_relid >= root->simple_rel_array_size)
			continue;
		outer_rel = root->simple_rel_array[outer_relid];
		if (outer_rel == NULL || IS_DUMMY_REL(outer_rel))
			continue;

		if (result == 0.0 || result > outer_rel->rows)
			result = outer_rel->rows;
	}

	return (result > 0.0) ? result : 1.0;
}

/*
 * restriction_qual_cost
 *		Cost of the quals the scan evaluates, as costsize.c's
 *		get_restriction_qual_cost computes it: the rel's own restrictions
 *		plus the clauses pushed down into a parameterized path.
 */
static void
restriction_qual_cost(PlannerInfo *root, RelOptInfo *rel,
					  ParamPathInfo *param_info, QualCost *qpqual_cost)
{
	if (param_info == NULL)
	{
		*qpqual_cost = rel->baserestrictcost;
		return;
	}

	cost_qual_eval(qpqual_cost, param_info->ppi_clauses, root);
	qpqual_cost->startup += rel->baserestrictcost.startup;
	qpqual_cost->per_tuple += rel->baserestrictcost.per_tuple;
}

/*
 * descent_cost
 *		Cost of positioning a btree scan, as btcostestimate charges it.
 */
static Cost
descent_cost(IndexOptInfo *index)
{
	Cost		cost = 0;

	if (index->tuples > 1)
		cost += ceil(log(index->tuples) / log(2.0)) * cpu_operator_cost;
	cost += (index->tree_height + 1) * 50.0 * cpu_operator_cost;

	return cost;
}

/*
 * estimate_group_size
 *		Expected number of inner entries per sortcol value.
 */
static double
estimate_group_size(PlannerInfo *root, RelOptInfo *rel, Index rti,
					AttrNumber sort_attno, IndexOptInfo *inner)
{
	Var		   *var = makeVar(rti, sort_attno, INT8OID, -1, InvalidOid, 0);
	double		ndistinct;

	ndistinct = estimate_num_groups(root, list_make1(var), rel->tuples,
									NULL, NULL);

	return Max(1.0, inner->tuples / Max(ndistinct, 1.0));
}

/*
 * add_intersect_path
 *		Build and cost the Index Merge Intersect path for one index pair and
 *		offer it to add_path.
 */
static void
add_intersect_path(PlannerInfo *root, RelOptInfo *rel, Index rti,
				   AttrNumber sort_attno, PathKey *pathkey,
				   IndexOptInfo *outer, IndexOptInfo *inner,
				   OuterCandidate *candidate)
{
	CustomPath *cpath;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer;
	double		rows;
	double		loop_count;
	double		outer_entries;
	double		inner_entries;
	double		group_size;
	double		correlation;
	QualCost	qpqual_cost;
	Cost		run_cost;
	Cost		startup_cost;

	/*
	 * The TID group of one value is expected to fit into work_mem.  This is
	 * an estimate over the average value; the executor enforces the limit
	 * itself, so under leapfrog.force the estimate is ignored like the cost.
	 */
	group_size = estimate_group_size(root, rel, rti, sort_attno, inner);
	if (!intersect_force &&
		group_size * sizeof(ItemPointerData) > work_mem * 1024.0)
		return;

	/* duplicates must be ordered by TID on both sides */
	if (!is_heapkeyspace(outer->indexoid) || !is_heapkeyspace(inner->indexoid))
		return;

	/* a LATERAL reference makes the path parameterized by those rels */
	required_outer = bms_union(candidate->required_outer,
							   rel->lateral_relids);
	if (!bms_is_empty(required_outer))
		param_info = get_baserel_parampathinfo(root, rel, required_outer);

	rows = param_info ? param_info->ppi_rows : rel->rows;
	loop_count = loop_count_for(root, required_outer);
	outer_entries = clamp_row_est(rel->tuples *
								  clauselist_selectivity(root,
														 candidate->clauses,
														 rti, JOIN_INNER,
														 NULL));
	inner_entries = clamp_row_est(inner->tuples);
	correlation = sort_column_correlation(root, rti, sort_attno, inner);
	restriction_qual_cost(root, rel, param_info, &qpqual_cost);

	cpath = makeNode(CustomPath);

	cpath->path.pathtype = T_CustomScan;
	cpath->path.parent = rel;
	cpath->path.pathtarget = rel->reltarget;
	cpath->path.param_info = param_info;
	cpath->path.parallel_aware = false;
	cpath->path.parallel_safe = false;
	cpath->path.parallel_workers = 0;
	cpath->path.rows = rows;
	cpath->path.pathkeys = list_make1(pathkey);
	cpath->flags = 0;
	cpath->methods = &intersect_path_methods;

	/*
	 * A CustomPath has no custom_exprs; the value expressions and the inner
	 * index predicate travel in custom_private and become the plan's
	 * custom_exprs in intersect_plan_path, where createplan.c turns
	 * outer-relation Vars into nestloop params and setrefs.c fixes up the
	 * rest.
	 */
	cpath->custom_private =
		list_make5(make_oid_const(outer->indexoid),
				   make_oid_const(inner->indexoid),
				   makeBoolConst(pathkey->pk_cmptype == COMPARE_GT, false),
				   copyObject(candidate->exprs),
				   copyObject(inner->indpred));

	/*
	 * Reading both indexes, grouping the entries of each value, fetching the
	 * result rows and running the qual and the target list on them.  The heap
	 * is read in sort column order, so its correlation decides how scattered
	 * the fetches are.
	 */
	run_cost = index_read_cost(root, outer, outer_entries, loop_count) +
		index_read_cost(root, inner, inner_entries, loop_count) +
		group_cost(outer_entries, inner_entries, group_size) +
		heap_fetch_cost(root, rel, rows, loop_count, correlation,
						(double) outer->pages + inner->pages) +
		rows * (cpu_tuple_cost + qpqual_cost.per_tuple +
				rel->reltarget->cost.per_tuple);

	/* both streams advance through run/(rows+1) before the first match */
	startup_cost = descent_cost(outer) + descent_cost(inner) +
		qpqual_cost.startup + rel->reltarget->cost.startup +
		run_cost / (rows + 1);

	/*
	 * With leapfrog.force the cost check is skipped, like MySQL does for the
	 * INDEX_MERGE hint: a zero-cost path does not lose on cost.  It can still
	 * be passed over for reasons other than cost, such as disabled_nodes or a
	 * parameterization the join order cannot provide.
	 */
	if (intersect_force)
	{
		cpath->path.startup_cost = 0;
		cpath->path.total_cost = 0;
	}
	else
	{
		cpath->path.startup_cost = startup_cost;
		cpath->path.total_cost = startup_cost + run_cost;
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
	ListCell   *lc;

	if (prev_set_rel_pathlist_hook)
		prev_set_rel_pathlist_hook(root, rel, rti, rte);

	if (!intersect_enabled || rte->rtekind != RTE_RELATION ||
		rte->relkind != RELKIND_RELATION ||
		rel->reloptkind != RELOPT_BASEREL || root->query_pathkeys == NIL ||
		IS_DUMMY_REL(rel) || rel->indexlist == NIL)
		return;

	/* the sort column must be the leading column of some index */
	pathkey = linitial_node(PathKey, root->query_pathkeys);
	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, lc);
		AttrNumber	attno = index->indexkeys[0];

		if (attno > 0 && pathkey_is_column(pathkey, rti, attno) &&
			is_int8_column(rte, attno) && is_notnull_column(rel, attno))
		{
			sort_attno = attno;
			break;
		}
	}

	if (sort_attno == InvalidAttrNumber)
		return;

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *outer = lfirst_node(IndexOptInfo, lc);
		OuterCandidate candidate;
		ListCell   *lc2;

		if (!find_outer_candidate(root, rel, rti, rte, outer, sort_attno,
								  pathkey, &candidate))
			continue;

		foreach(lc2, rel->indexlist)
		{
			IndexOptInfo *inner = lfirst_node(IndexOptInfo, lc2);

			if (inner != outer && is_inner_index(inner, sort_attno, pathkey))
				add_intersect_path(root, rel, rti, sort_attno, pathkey,
								   outer, inner, &candidate);
		}
	}
}

/*
 * is_candidate_equality
 *		Is the clause one of the equalities the outer index enforces: column
 *		i of the index compared with the i-th value expression?
 */
static bool
is_candidate_equality(RestrictInfo *rinfo, Index rti, IndexOptInfo *outer,
					  List *exprs)
{
	int			i = 0;
	ListCell   *lc;

	foreach(lc, exprs)
	{
		Node	   *other;

		if (is_int8_equality(rinfo, rti, outer->indexkeys[i], &other) &&
			equal(other, lfirst(lc)))
			return true;
		i++;
	}

	return false;
}

/*
 * intersect_scan_qual
 *		The quals the node still has to evaluate, as create_indexscan_plan
 *		computes qpqual: the equalities on the outer index columns are
 *		enforced by the scan keys and rechecked under EvalPlanQual by
 *		intersect_recheck, so they are dropped.  Clauses implied by the inner
 *		index predicate are dropped as well, except for a target relation of
 *		UPDATE/DELETE/SELECT FOR UPDATE, where check_index_predicates keeps
 *		them in the plan for EvalPlanQual.
 */
static List *
intersect_scan_qual(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *clauses, Oid outer_indexoid)
{
	List	   *exprs = lfourth(best_path->custom_private);
	List	   *indpred = list_nth(best_path->custom_private, 4);
	IndexOptInfo *outer = NULL;
	bool		is_target_rel;
	List	   *qpqual = NIL;
	ListCell   *lc;

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = lfirst_node(IndexOptInfo, lc);

		if (index->indexoid == outer_indexoid)
			outer = index;
	}
	Assert(outer != NULL);

	is_target_rel = (bms_is_member(rel->relid, root->all_result_relids) ||
					 get_plan_rowmark(root->rowMarks, rel->relid) != NULL);

	foreach(lc, clauses)
	{
		RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);

		if (rinfo->pseudoconstant)
			continue;
		if (is_candidate_equality(rinfo, rel->relid, outer, exprs))
			continue;
		if (!is_target_rel &&
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
 */
static Plan *
intersect_plan_path(PlannerInfo *root, RelOptInfo *rel, CustomPath *best_path,
					List *tlist, List *clauses, List *custom_plans)
{
	CustomScan *cscan = makeNode(CustomScan);
	Oid			outer_indexoid;
	Oid			inner_indexoid;

	/*
	 * The plan depends on both indexes: a cached plan must be invalidated
	 * when one of them is dropped, as it is for the indexes of an IndexScan
	 * (which setrefs.c records from the plan's indexid).
	 */
	outer_indexoid = DatumGetObjectId(linitial_node(Const,
													best_path->custom_private)->constvalue);
	inner_indexoid = DatumGetObjectId(lsecond_node(Const,
												   best_path->custom_private)->constvalue);
	root->glob->relationOids = lappend_oid(root->glob->relationOids,
										   outer_indexoid);
	root->glob->relationOids = lappend_oid(root->glob->relationOids,
										   inner_indexoid);

	cscan->scan.plan.targetlist = tlist;
	cscan->scan.plan.qual = intersect_scan_qual(root, rel, best_path,
												clauses, outer_indexoid);
	cscan->scan.scanrelid = rel->relid;
	cscan->flags = best_path->flags;
	cscan->custom_private = list_truncate(list_copy(best_path->custom_private),
										  3);
	cscan->custom_exprs = list_make2(lfourth(best_path->custom_private),
									 list_nth(best_path->custom_private, 4));
	cscan->custom_scan_tlist = NIL;
	cscan->methods = &intersect_scan_methods;

	return &cscan->scan.plan;
}

static Node *
intersect_create_scan_state(CustomScan *cscan)
{
	IntersectScanState *state;

	state = (IntersectScanState *) newNode(sizeof(IntersectScanState),
										   T_CustomScanState);
	state->css.methods = &intersect_exec_methods;
	/* index_fetch_heap stores a buffer-pinned heap tuple */
	state->css.slotOps = &TTSOpsBufferHeapTuple;

	return (Node *) state;
}

static void
intersect_begin(CustomScanState *node, EState *estate, int eflags)
{
	IntersectScanState *state = (IntersectScanState *) node;
	CustomScan *cscan = (CustomScan *) node->ss.ps.plan;
	Relation	heap = node->ss.ss_currentRelation;
	List	   *private = cscan->custom_private;
	ListCell   *lc;
	int			i = 0;

	state->outer_index =
		index_open(DatumGetObjectId(linitial_node(Const, private)->constvalue),
				   AccessShareLock);
	state->inner_index =
		index_open(DatumGetObjectId(lsecond_node(Const, private)->constvalue),
				   AccessShareLock);
	state->descending =
		DatumGetBool(lthird_node(Const, private)->constvalue);

	foreach(lc, linitial_node(List, cscan->custom_exprs))
	{
		Expr	   *expr = (Expr *) lfirst(lc);

		state->equal_exprs[i] = ExecInitExpr(expr, &node->ss.ps);
		state->equal_types[i] = exprType((Node *) expr);
		state->equal_attnos[i] = state->outer_index->rd_index->indkey.values[i];
		i++;
	}
	state->nequal = i;
	state->inner_pred = ExecInitQual(lsecond_node(List, cscan->custom_exprs),
									 &node->ss.ps);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	state->outer_scan = index_beginscan(heap, state->outer_index,
										estate->es_snapshot, NULL,
										state->nequal, 0);
	state->inner_scan = index_beginscan(heap, state->inner_index,
										estate->es_snapshot, NULL, 0, 0);
	state->outer_scan->xs_want_itup = true;
	state->inner_scan->xs_want_itup = true;

	/* the group array never grows past the work_mem budget */
	state->group_limit = (int) Min((double) INT_MAX / 2,
								   work_mem * 1024.0 / sizeof(ItemPointerData));
	state->group_capacity = Max(1, Min(16, state->group_limit));
	state->group_tids = palloc(state->group_capacity * sizeof(ItemPointerData));
	state->outer_read = 0;
	state->inner_read = 0;
	state->matched = 0;
	state->pred_checked = 0;
	state->heap_fetches = 0;
	state->group_overflows = 0;
	state->peak_capacity = state->group_capacity;

	intersect_rescan(node);
}

/*
 * evaluate_equal_values
 *		Evaluate the equality values once per (re)scan.  Also used by the
 *		EvalPlanQual recheck, which runs on a planstate copy whose scan was
 *		never started.  Returns false when a value is NULL.
 */
static bool
evaluate_equal_values(IntersectScanState *state)
{
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;

	if (state->values_ready)
		return !state->values_null;

	state->values_ready = true;
	state->values_null = false;

	for (int i = 0; i < state->nequal; i++)
	{
		Datum		value;
		bool		isnull;

		value = ExecEvalExprSwitchContext(state->equal_exprs[i], econtext,
										  &isnull);
		if (isnull)
		{
			state->values_null = true;
			return false;
		}

		state->equal_values[i] = datum_get_int64(value, state->equal_types[i]);
	}

	return true;
}

/*
 * intersect_start
 *		Evaluate the equality values and position both index scans.
 *		Returns false when a value is NULL: nothing can match then.
 */
static bool
intersect_start(IntersectScanState *state)
{
	ScanKeyData keys[INDEX_MAX_KEYS];

	if (!evaluate_equal_values(state))
		return false;

	for (int i = 0; i < state->nequal; i++)
		ScanKeyInit(&keys[i], i + 1, BTEqualStrategyNumber, F_INT8EQ,
					Int64GetDatum(state->equal_values[i]));

	index_rescan(state->outer_scan, keys, state->nequal, NULL, 0);
	index_rescan(state->inner_scan, NULL, 0, NULL, 0);

	return true;
}

/*
 * read_index_entry
 *		Fetch the next (sortcol value, heap TID) entry from an index without
 *		visiting the heap.  *entries_read counts every entry taken from the
 *		index, including the skipped ones.
 *
 * The planner accepts the sort column only when it is NOT NULL, but that
 * describes the live rows: an index can still hold dead entries with NULL
 * until VACUUM, for instance when a NULL was updated away before SET NOT
 * NULL.  Such entries are skipped.  They cannot belong to a row the merge
 * has to return, since NULL never satisfies the equality the merge is
 * built on, and treating them as a value would derail it: a backward scan
 * reads them first.
 */
static bool
read_index_entry(IndexScanDesc scan, ScanDirection dir, int attno,
				 int64 *value, ItemPointer tid, int64 *entries_read)
{
	for (;;)
	{
		Datum		datum;
		bool		isnull;

		if (index_getnext_tid(scan, dir) == NULL)
			return false;
		(*entries_read)++;

		/* xs_want_itup is set and btree always returns the index tuple */
		Assert(scan->xs_itup != NULL);

		datum = index_getattr(scan->xs_itup, attno, scan->xs_itupdesc,
							  &isnull);
		if (isnull)
		{
			CHECK_FOR_INTERRUPTS();
			continue;
		}

		*value = DatumGetInt64(datum);
		ItemPointerCopy(&scan->xs_heaptid, tid);

		return true;
	}
}

static int
tid_compare(const void *a, const void *b)
{
	return ItemPointerCompare((ItemPointer) a, (ItemPointer) b);
}

/*
 * read_inner_entry
 *		Advance the inner side; remembers when it is exhausted.
 */
static void
read_inner_entry(IntersectScanState *state, ScanDirection dir)
{
	if (read_index_entry(state->inner_scan, dir, 1, &state->inner_value,
						 &state->inner_tid, &state->inner_read))
		state->have_inner = true;
	else
		state->inner_eof = true;
}

/*
 * collect_group
 *		Gather the TIDs of all inner entries whose value equals the current
 *		one, leaving the first entry of the next value pending.
 *
 * A group larger than work_mem is not kept: the remaining inner entries of
 * the value are skipped, and every outer entry of the value is treated as a
 * match for the node's qual to filter.
 */
static void
collect_group(IntersectScanState *state, ScanDirection dir)
{
	uint32		iterations = 0;

	state->in_group = true;
	state->group_overflow = false;
	state->group_value = state->inner_value;
	state->group_count = 0;

	while (state->have_inner && state->inner_value == state->group_value)
	{
		if ((++iterations & 1023) == 0)
			CHECK_FOR_INTERRUPTS();

		if (state->group_overflow)
			;					/* skip the rest of the value */
		else if (state->group_count == state->group_limit)
		{
			state->group_overflow = true;
			state->group_overflows++;
		}
		else
		{
			if (state->group_count == state->group_capacity)
			{
				state->group_capacity = Min(state->group_capacity * 2,
											state->group_limit);
				state->group_tids = repalloc(state->group_tids,
											 state->group_capacity *
											 sizeof(ItemPointerData));
				state->peak_capacity = Max(state->peak_capacity,
										   state->group_capacity);
			}
			state->group_tids[state->group_count++] = state->inner_tid;
		}

		state->have_inner = false;
		read_inner_entry(state, dir);
	}

	if (state->group_overflow)
		state->group_count = 0;
	else if (state->group_count > 1)
		qsort(state->group_tids, state->group_count, sizeof(ItemPointerData),
			  tid_compare);
}

static bool
group_contains(IntersectScanState *state, ItemPointer tid)
{
	if (state->group_overflow)
		return true;

	return bsearch(tid, state->group_tids, state->group_count,
				   sizeof(ItemPointerData), tid_compare) != NULL;
}

/*
 * intersect_next
 *		Merge the two sorted index streams, the counterpart of MySQL's
 *		RowIDIntersectionIterator::DoRead: advance the lagging side until
 *		the values meet, then match the entries of that value by TID.
 */
static TupleTableSlot *
intersect_next(ScanState *ss)
{
	IntersectScanState *state = (IntersectScanState *) ss;
	TupleTableSlot *slot = ss->ss_ScanTupleSlot;
	ScanDirection dir;
	uint32		iterations = 0;

	dir = state->descending ? BackwardScanDirection : ForwardScanDirection;

	if (!state->started)
	{
		state->started = true;
		if (!intersect_start(state))
			state->done = true;
	}

	while (!state->done)
	{
		bool		outer_lags;

		/* long stretches without a match must stay interruptible */
		if ((++iterations & 1023) == 0)
			CHECK_FOR_INTERRUPTS();

		/*
		 * Finish the heap fetch of the last matched entry first, the way
		 * index_getnext_slot does: a HOT chain may hold more than one visible
		 * member under a non-MVCC snapshot.
		 */
		if (state->fetching_match)
		{
			bool		found = index_fetch_heap(state->outer_scan, slot);

			state->heap_fetches++;
			state->fetching_match = state->outer_scan->xs_heap_continue;
			if (!found)
				continue;

			/*
			 * An entry of an overflowed group was not matched against the
			 * inner index: check its predicate on the row itself.
			 */
			if (state->match_by_pred)
			{
				ExprContext *econtext = ss->ps.ps_ExprContext;

				econtext->ecxt_scantuple = slot;
				if (!ExecQualAndReset(state->inner_pred, econtext))
					continue;
			}

			return slot;
		}

		if (!state->have_outer)
		{
			if (!read_index_entry(state->outer_scan, dir, state->nequal + 1,
								  &state->outer_value, &state->outer_tid,
								  &state->outer_read))
				break;
			state->have_outer = true;
		}

		/* the outer entries of the collected value are looked up by TID */
		if (state->in_group)
		{
			if (state->outer_value != state->group_value)
			{
				state->in_group = false;
				continue;
			}

			state->have_outer = false;
			if (group_contains(state, &state->outer_tid))
			{
				if (state->group_overflow)
					state->pred_checked++;
				else
					state->matched++;
				state->fetching_match = true;
				state->match_by_pred = state->group_overflow;
			}

			continue;
		}

		if (!state->have_inner)
		{
			if (state->inner_eof)
				break;
			read_inner_entry(state, dir);
			continue;
		}

		if (state->outer_value == state->inner_value)
		{
			collect_group(state, dir);
			continue;
		}

		/* the lagging side is the one still ahead in scan direction */
		if (state->descending)
			outer_lags = state->outer_value > state->inner_value;
		else
			outer_lags = state->outer_value < state->inner_value;

		if (outer_lags)
			state->have_outer = false;
		else
			state->have_inner = false;
	}

	state->done = true;

	return ExecClearTuple(slot);
}

/*
 * intersect_recheck
 *		EvalPlanQual recheck: the row version may have changed since the
 *		index entries were matched, so the conditions the scan guaranteed by
 *		construction are evaluated again on the new version.  The node's
 *		qual is applied by ExecScan afterwards.
 */
static bool
intersect_recheck(ScanState *ss, TupleTableSlot *slot)
{
	IntersectScanState *state = (IntersectScanState *) ss;
	ExprContext *econtext = ss->ps.ps_ExprContext;

	if (!evaluate_equal_values(state))
		return false;

	for (int i = 0; i < state->nequal; i++)
	{
		bool		isnull;
		Datum		value;

		value = slot_getattr(slot, state->equal_attnos[i], &isnull);
		if (isnull || DatumGetInt64(value) != state->equal_values[i])
			return false;
	}

	econtext->ecxt_scantuple = slot;

	return ExecQualAndReset(state->inner_pred, econtext);
}

static TupleTableSlot *
intersect_exec(CustomScanState *node)
{
	return ExecScan(&node->ss, (ExecScanAccessMtd) intersect_next,
					(ExecScanRecheckMtd) intersect_recheck);
}

static void
intersect_end(CustomScanState *node)
{
	IntersectScanState *state = (IntersectScanState *) node;

	if (state->outer_scan)
		index_endscan(state->outer_scan);
	if (state->inner_scan)
		index_endscan(state->inner_scan);
	if (state->outer_index)
		index_close(state->outer_index, AccessShareLock);
	if (state->inner_index)
		index_close(state->inner_index, AccessShareLock);
	if (state->group_tids)
		pfree(state->group_tids);
}

static void
intersect_rescan(CustomScanState *node)
{
	IntersectScanState *state = (IntersectScanState *) node;

	/* clear the scan slot and EPQ substitution state, as every scan node */
	ExecScanReScan(&node->ss);

	state->started = false;
	state->done = false;
	state->values_ready = false;
	state->values_null = false;
	state->have_outer = false;
	state->have_inner = false;
	state->inner_eof = false;
	state->fetching_match = false;
	state->match_by_pred = false;
	state->in_group = false;
	state->group_overflow = false;
	state->group_count = 0;
}

static void
intersect_explain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	IntersectScanState *state = (IntersectScanState *) node;

	ExplainPropertyText("Outer Index",
						RelationGetRelationName(state->outer_index), es);
	ExplainPropertyText("Inner Index",
						RelationGetRelationName(state->inner_index), es);
	/* summed over all rescans, like the executor's own counters */
	if (es->analyze)
	{
		ExplainPropertyInteger("Outer Entries Read", NULL, state->outer_read,
							   es);
		ExplainPropertyInteger("Inner Entries Read", NULL, state->inner_read,
							   es);
		ExplainPropertyInteger("Matched TIDs", NULL, state->matched, es);
		ExplainPropertyInteger("Heap Fetches", NULL, state->heap_fetches, es);
		ExplainPropertyInteger("Peak Group Memory", "B",
							   (int64) state->peak_capacity *
							   sizeof(ItemPointerData), es);
		if (state->group_overflows > 0)
		{
			ExplainPropertyInteger("Group Overflows", NULL,
								   state->group_overflows, es);
			ExplainPropertyInteger("Rows Checked by Predicate", NULL,
								   state->pred_checked, es);
		}
	}
}

/*
 * Module load callback
 */
void
_PG_init(void)
{
	DefineCustomBoolVariable("leapfrog.enabled",
							 "Enables the planner's use of Index Merge Intersect.",
							 NULL,
							 &intersect_enabled,
							 true,
							 PGC_USERSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	DefineCustomBoolVariable("leapfrog.force",
							 "Chooses Index Merge Intersect regardless of cost.",
							 "The counterpart of MySQL's INDEX_MERGE hint.",
							 &intersect_force,
							 false,
							 PGC_USERSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	MarkGUCPrefixReserved("leapfrog");

	RegisterCustomScanMethods(&intersect_scan_methods);

	prev_set_rel_pathlist_hook = set_rel_pathlist_hook;
	set_rel_pathlist_hook = intersect_set_rel_pathlist;
	intersect_hook_installed = true;
}

/*
 * leapfrog_version
 *		SQL-callable: version of the loaded library.
 */
Datum
leapfrog_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(LEAPFROG_VERSION));
}

/*
 * leapfrog_is_loaded
 *		SQL-callable: is the planner hook active in this session?  Calling
 *		the function loads the library, so the answer is true whenever the
 *		call succeeds; it exists for scripts that need an explicit check.
 */
Datum
leapfrog_is_loaded(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(intersect_hook_installed);
}
