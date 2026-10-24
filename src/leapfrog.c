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
 *	- the inner index (j1, ..., jM, sortcol, ...), M >= 0: every jI is
 *	  compared for equality in the same way, and if the index is partial its
 *	  predicate is implied by the query's restrictions.  With M = 0 it must
 *	  be partial, or it would not narrow anything down; an ordinary index
 *	  whose equality columns all appear in the outer index is not used
 *	  either.  Typical inner sides: (sortcol) WHERE deleted_at IS NULL, or
 *	  another (filter_column, sortcol).
 *
 * With every column before sortcol fixed by equality, both scans produce
 * sortcol values in the same order.
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
 * checked against the inner index conditions explicitly (its equalities and
 * its predicate), before the node's qual sees them, so the fallback does not
 * depend on what the qual holds.
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
 *	  run = index_read_cost(outer, entries matching its equalities)
 *		   + index_read_cost(inner, entries matching its equalities)
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
 * uncorrelated case by the squared correlation btcostestimate would use for
 * an Index Scan on the outer index, which visits the same heap rows in the
 * same order.  Tablespace page costs are honoured.
 *
 * Documented assumptions, not derived from statistics: the matches are
 * spread evenly along both indexes (so a LIMIT is served by a proportional
 * fraction of the total, as the planner assumes for every path), and the
 * TID group of one value has the average size.  Skewed data can make either
 * side much more expensive than predicted.
 *
 * leapfrog.force is the counterpart of MySQL's INDEX_MERGE hint
 * (ignore_cost in ROR_intersect_plan::add): the intersection is chosen
 * whenever a suitable index pair exists, regardless of the cost of the
 * other plans.  Among several pairs the cheapest one still wins.  It is a
 * diagnostic knob and can make a query far slower.
 *
 * Under EvalPlanQual the scan rechecks what it guaranteed by construction,
 * as an index scan rechecks indexqualorig: the equalities on the columns of
 * both indexes and the predicate of the inner index.
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

/*
 * Under leapfrog.force the paths keep their relative costs, scaled down so
 * far that no other path can be cheaper: add_path compares costs by ratio,
 * so the cheapest index pair still wins among the pairs.
 */
#define INTERSECT_FORCE_SCALE 1e-12

/*
 * A lagging scan is re-positioned once it has read this many entries in a
 * row without catching up with the other side.  A re-descent through
 * index_rescan costs tree_height buffer accesses plus restarting the scan,
 * while a leaf page holds about 400 int8 entries, so a skip pays only when
 * it moves past the next leaf page.  The threshold is the starting point of
 * each side's adaptive threshold (SkipAhead): it doubles after a skip that
 * landed on the next leaf page, and halves back after a longer one.
 * Measured on 1M-row tables (tests/performance/skip_bench.sh): with clustered
 * gaps, 64 read up to 1.9 times fewer buffers than 1024; with matches spread
 * evenly it costs 0.2 % more buffers than not skipping, where a fixed 128
 * cost 38 %; 16 and 32 differ from 64 by less than 5 %.  The developer
 * setting leapfrog.skip_after overrides it for measurements; 0 turns
 * skipping off.
 */
#define INTERSECT_SKIP_AFTER 64

/*
 * Layout of CustomPath.custom_private.  The plan keeps the first
 * PRIVATE_COUNT entries in custom_private; the expression lists move to
 * custom_exprs at the EXPRS_* positions.
 */
#define PRIVATE_OUTER_INDEX		0
#define PRIVATE_INNER_INDEX		1
#define PRIVATE_DESCENDING		2
#define PRIVATE_INNER_SORTPOS	3
#define PRIVATE_COUNT			4
#define EXPRS_OUTER_KEYS		0	/* value expressions of the outer
									 * equalities */
#define EXPRS_INNER_PRED		1	/* predicate of the inner index, or NIL */
#define EXPRS_INNER_KEYS		2	/* value expressions of the inner
									 * equalities */

/* GUC variables */
static bool intersect_enabled = true;
static bool intersect_force = false;
static int	intersect_skip_after = INTERSECT_SKIP_AFTER;

/* Saved hook value */
static set_rel_pathlist_hook_type prev_set_rel_pathlist_hook = NULL;

/* Set once the hook is installed */
static bool intersect_hook_installed = false;

/*
 * The equality conditions on the leading columns of one index: the value
 * expressions, their values for the current (re)scan, and the heap columns
 * they apply to (for the EvalPlanQual recheck and the overflow fallback).
 */
typedef struct EqualityKeys
{
	int			nequal;
	ExprState  *exprs[INDEX_MAX_KEYS];
	Oid			types[INDEX_MAX_KEYS];
	int64		values[INDEX_MAX_KEYS];
	AttrNumber	attnos[INDEX_MAX_KEYS];
} EqualityKeys;

/*
 * Skip-ahead state of one side of the merge.  A skip that lands on the leaf
 * page it left or on the next one in scan direction saved less than the
 * descent cost, and the side's threshold doubles; a skip that lands further
 * halves it, down to leapfrog.skip_after.
 */
typedef struct SkipAhead
{
	int64		behind;			/* entries read in a row without catching up */
	int64		threshold;		/* entries read before the next skip */
	bool		landing;		/* a skip happened, its landing page is not
								 * checked yet */
	BlockNumber from_page;		/* leaf page the skip left */
	BlockNumber from_next;		/* its neighbour in scan direction */
} SkipAhead;

/*
 * Execution state of an Index Merge Intersect scan.
 */
typedef struct IntersectScanState
{
	CustomScanState css;
	Relation	outer_index;	/* (k1, ..., kN, sortcol) */
	Relation	inner_index;	/* (j1, ..., jM, sortcol, ...) */
	IndexScanDesc outer_scan;
	IndexScanDesc inner_scan;
	EqualityKeys outer_keys;	/* k1 ... kN */
	EqualityKeys inner_keys;	/* j1 ... jM */
	int			inner_sortpos;	/* position of sortcol in the inner index */
	bool		values_ready;	/* key values are evaluated */
	bool		values_null;	/* some equality value is NULL */
	ExprState  *inner_pred;		/* predicate of the inner index, if partial */
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
	int64		skips;			/* re-descents of a lagging scan */
	int64		short_skips;	/* skips that landed on the next leaf page */

	SkipAhead	outer_skip;
	SkipAhead	inner_skip;
} IntersectScanState;

/*
 * Index candidate for either side of the intersection: equality clauses of
 * the columns before sortcol, the value expressions compared against, the
 * outer rels they refer to, and the position of sortcol among the key
 * columns.  Built once per index while the relation's paths are planned and
 * shared by every pair the index takes part in; heapkeyspace is looked up on
 * first use (-1 until then) because it opens the index.
 */
typedef struct IndexCandidate
{
	IndexOptInfo *index;
	bool		usable;
	List	   *clauses;
	List	   *exprs;
	Relids		required_outer;
	int			sortpos;
	int			heapkeyspace;
} IndexCandidate;

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
 * outer_index_correlation
 *		Correlation of the heap with the outer index, estimated the way
 *		btcostestimate estimates it for an Index Scan on that index: the
 *		correlation of its leading column, times 0.75 for a multicolumn
 *		index.  Zero (no correlation) when there are no statistics.
 *
 * The node visits the heap rows in sort column order, which with the
 * leading columns fixed may well be more correlated than that.  But an
 * Index Scan on the outer index visits the same rows in the same order and
 * is costed with this estimate; giving the node a better one would let it
 * win on heap pages both plans read alike.
 */
static double column_correlation(PlannerInfo *root, Index rti,
								 AttrNumber attno);

static double
outer_index_correlation(PlannerInfo *root, Index rti, IndexOptInfo *outer)
{
	double		correlation;

	correlation = column_correlation(root, rti, outer->indexkeys[0]);
	if (outer->nkeycolumns > 1)
		correlation *= 0.75;

	return correlation;
}

/*
 * column_correlation
 *		Correlation of a bigint column with the heap order, from the
 *		pg_statistic slot of the "<" operator of the integer family.
 */
static double
column_correlation(PlannerInfo *root, Index rti, AttrNumber attno)
{
	Var		   *var = makeVar(rti, attno, INT8OID, -1, InvalidOid, 0);
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

	sortop = get_opfamily_member(INTEGER_BTREE_FAM_OID, INT8OID, INT8OID,
								 BTLessStrategyNumber);
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
 * merge_read_cost
 *		Cost of reading both index streams through the merge, with the
 *		skip-ahead of intersect_next.
 *
 * With the matches spread evenly, the denser stream has dense/sparse
 * entries between two entries of the sparser one.  Up to
 * leapfrog.skip_after of them are read one by one; a gap longer by more
 * than two leaf pages is crossed by one more descent of the B-tree, charged
 * as btcostestimate charges a descent plus the leaf page it lands on.  A
 * shorter gap is read through: the executor backs off from skips that land
 * on the next leaf page (check_landing).
 */
static Cost
merge_read_cost(PlannerInfo *root, IndexOptInfo *outer, IndexOptInfo *inner,
				double outer_entries, double inner_entries, double loop_count)
{
	bool		outer_dense = outer_entries > inner_entries;
	IndexOptInfo *dense = outer_dense ? outer : inner;
	double		sparse_entries = Max(Min(outer_entries, inner_entries), 1.0);
	double		dense_entries = Max(outer_entries, inner_entries);
	double		dense_read = dense_entries;
	double		descents = 0;
	double		leaf_entries;
	double		spc_random_page_cost;
	Cost		cost;

	leaf_entries = dense->tuples / Max(dense->pages, 1);
	if (intersect_skip_after > 0 &&
		dense_entries / sparse_entries >
		intersect_skip_after + 2 * leaf_entries)
	{
		dense_read = sparse_entries * intersect_skip_after;
		descents = sparse_entries;
	}

	get_tablespace_page_costs(dense->reltablespace, &spc_random_page_cost,
							  NULL);

	cost = index_read_cost(root, outer_dense ? inner : outer, sparse_entries,
						   loop_count) +
		index_read_cost(root, dense, dense_read, loop_count) +
		descents * (descent_cost(dense) + spc_random_page_cost);

	return cost;
}

/*
 * sortcol_ndistinct
 *		Number of distinct sortcol values in the relation, which divides the
 *		inner entries into TID groups.
 */
static double
sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel, Index rti,
				  AttrNumber sort_attno)
{
	Var		   *var = makeVar(rti, sort_attno, INT8OID, -1, InvalidOid, 0);

	return Max(estimate_num_groups(root, list_make1(var), rel->tuples,
								   NULL, NULL), 1.0);
}

/*
 * index_entries
 *		Entries of an index matching the equalities on its leading columns.
 *		A partial index holds index->tuples entries to begin with.
 */
static double
index_entries(PlannerInfo *root, Index rti, IndexOptInfo *index,
			  IndexCandidate *candidate)
{
	double		entries = index->tuples;

	if (candidate->clauses != NIL)
		entries *= clauselist_selectivity(root, candidate->clauses, rti,
										  JOIN_INNER, NULL);

	return clamp_row_est(entries);
}

/*
 * add_intersect_path
 *		Build and cost the Index Merge Intersect path for one index pair and
 *		offer it to add_path.  ndistinct is sortcol_ndistinct and correlation
 *		outer_index_correlation of the outer index, both computed once by the
 *		caller.
 */
static void
add_intersect_path(PlannerInfo *root, RelOptInfo *rel, Index rti,
				   PathKey *pathkey, IndexCandidate *outer_candidate,
				   IndexCandidate *inner_candidate, double ndistinct,
				   double correlation)
{
	IndexOptInfo *outer = outer_candidate->index;
	IndexOptInfo *inner = inner_candidate->index;
	CustomPath *cpath;
	ParamPathInfo *param_info = NULL;
	Relids		required_outer;
	double		rows;
	double		loop_count;
	double		outer_entries;
	double		inner_entries;
	double		group_size;
	QualCost	qpqual_cost;
	Cost		run_cost;
	Cost		startup_cost;

	outer_entries = index_entries(root, rti, outer, outer_candidate);
	inner_entries = index_entries(root, rti, inner, inner_candidate);

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

	rows = param_info ? param_info->ppi_rows : rel->rows;
	loop_count = loop_count_for(root, required_outer);
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
									copyObject(outer_candidate->exprs));
	cpath->custom_private = lappend(cpath->custom_private,
									copyObject(inner->indpred));
	cpath->custom_private = lappend(cpath->custom_private,
									copyObject(inner_candidate->exprs));

	/*
	 * Reading both indexes, grouping the entries of each value, fetching the
	 * result rows and running the qual and the target list on them.  The heap
	 * fetches are charged as for an Index Scan on the outer index (see
	 * outer_index_correlation).
	 */
	run_cost = merge_read_cost(root, outer, inner, outer_entries,
							   inner_entries, loop_count) +
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
	 * With leapfrog.force the competition with the other plans is skipped,
	 * like MySQL does for the INDEX_MERGE hint, but the pairs still compete
	 * among themselves.  The path can still be passed over for reasons other
	 * than cost, such as disabled_nodes or a parameterization the join order
	 * cannot provide.
	 */
	if (intersect_force)
	{
		startup_cost *= INTERSECT_FORCE_SCALE;
		run_cost *= INTERSECT_FORCE_SCALE;
	}
	cpath->path.startup_cost = startup_cost;
	cpath->path.total_cost = startup_cost + run_cost;

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
				ndistinct = sortcol_ndistinct(root, rel, rti, sort_attno);
			if (!has_correlation)
			{
				correlation = outer_index_correlation(root, rti, outer->index);
				has_correlation = true;
			}
			add_intersect_path(root, rel, rti, pathkey, outer, inner,
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

/*
 * init_equality_keys
 *		Prepare the equality value expressions of one index side; the i-th
 *		expression is compared with the i-th key column of the index.
 */
static void
init_equality_keys(EqualityKeys *keys, List *exprs, Relation index,
				   PlanState *parent)
{
	ListCell   *lc;
	int			i = 0;

	foreach(lc, exprs)
	{
		Expr	   *expr = (Expr *) lfirst(lc);

		keys->exprs[i] = ExecInitExpr(expr, parent);
		keys->types[i] = exprType((Node *) expr);
		keys->attnos[i] = index->rd_index->indkey.values[i];
		i++;
	}
	keys->nequal = i;
}

static Datum
private_datum(List *private, int pos)
{
	return list_nth_node(Const, private, pos)->constvalue;
}

static void
intersect_begin(CustomScanState *node, EState *estate, int eflags)
{
	IntersectScanState *state = (IntersectScanState *) node;
	CustomScan *cscan = (CustomScan *) node->ss.ps.plan;
	Relation	heap = node->ss.ss_currentRelation;
	List	   *private = cscan->custom_private;

	state->outer_index =
		index_open(DatumGetObjectId(private_datum(private, PRIVATE_OUTER_INDEX)),
				   AccessShareLock);
	state->inner_index =
		index_open(DatumGetObjectId(private_datum(private, PRIVATE_INNER_INDEX)),
				   AccessShareLock);
	state->descending =
		DatumGetBool(private_datum(private, PRIVATE_DESCENDING));
	state->inner_sortpos =
		DatumGetInt32(private_datum(private, PRIVATE_INNER_SORTPOS));

	init_equality_keys(&state->outer_keys,
					   list_nth_node(List, cscan->custom_exprs, EXPRS_OUTER_KEYS),
					   state->outer_index, &node->ss.ps);
	init_equality_keys(&state->inner_keys,
					   list_nth_node(List, cscan->custom_exprs, EXPRS_INNER_KEYS),
					   state->inner_index, &node->ss.ps);
	state->inner_pred =
		ExecInitQual(list_nth_node(List, cscan->custom_exprs, EXPRS_INNER_PRED),
					 &node->ss.ps);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	/* the equality keys plus the bound on sortcol used for skipping ahead */
	state->outer_scan = index_beginscan(heap, state->outer_index,
										estate->es_snapshot, NULL,
										state->outer_keys.nequal + 1, 0);
	state->inner_scan = index_beginscan(heap, state->inner_index,
										estate->es_snapshot, NULL,
										state->inner_keys.nequal + 1, 0);
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
	state->skips = 0;
	state->peak_capacity = state->group_capacity;

	intersect_rescan(node);
}

/*
 * evaluate_keys
 *		Evaluate the equality values of one side.  Returns false when a
 *		value is NULL.
 */
static bool
evaluate_keys(EqualityKeys *keys, ExprContext *econtext)
{
	for (int i = 0; i < keys->nequal; i++)
	{
		Datum		value;
		bool		isnull;

		value = ExecEvalExprSwitchContext(keys->exprs[i], econtext, &isnull);
		if (isnull)
			return false;

		keys->values[i] = datum_get_int64(value, keys->types[i]);
	}

	return true;
}

/*
 * evaluate_equal_values
 *		Evaluate the equality values of both sides once per (re)scan.  Also
 *		used by the EvalPlanQual recheck, which runs on a planstate copy
 *		whose scan was never started.  Returns false when a value is NULL.
 */
static bool
evaluate_equal_values(IntersectScanState *state)
{
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;

	if (state->values_ready)
		return !state->values_null;

	state->values_ready = true;
	state->values_null = !evaluate_keys(&state->outer_keys, econtext) ||
		!evaluate_keys(&state->inner_keys, econtext);

	return !state->values_null;
}

/*
 * rescan_with_keys
 *		Position an index scan on the current equality values of one side
 *		and on a bound for sortcol (the key column right after them): values
 *		>= bound for a forward scan, <= bound for a backward one.  The scan
 *		was opened with nequal + 1 keys, and index_rescan must get that many.
 */
static void
rescan_with_keys(IndexScanDesc scan, EqualityKeys *keys, bool descending,
				 int64 bound)
{
	ScanKeyData scankeys[INDEX_MAX_KEYS + 1];

	for (int i = 0; i < keys->nequal; i++)
		ScanKeyInit(&scankeys[i], i + 1, BTEqualStrategyNumber, F_INT8EQ,
					Int64GetDatum(keys->values[i]));

	if (descending)
		ScanKeyInit(&scankeys[keys->nequal], keys->nequal + 1,
					BTLessEqualStrategyNumber, F_INT8LE, Int64GetDatum(bound));
	else
		ScanKeyInit(&scankeys[keys->nequal], keys->nequal + 1,
					BTGreaterEqualStrategyNumber, F_INT8GE,
					Int64GetDatum(bound));

	index_rescan(scan, scankeys, keys->nequal + 1, NULL, 0);
}

/*
 * no_bound
 *		The sortcol bound that lets every value through.
 */
static int64
no_bound(bool descending)
{
	return descending ? PG_INT64_MAX : PG_INT64_MIN;
}

/*
 * init_skip
 *		Start a side's skip-ahead at leapfrog.skip_after; 0 never skips.
 */
static void
init_skip(SkipAhead *skip)
{
	skip->behind = 0;
	skip->threshold = intersect_skip_after > 0 ?
		intersect_skip_after : PG_INT64_MAX;
	skip->landing = false;
}

/*
 * skip_ahead
 *		Re-position a lagging scan on the other side's value, remembering the
 *		leaf page it leaves so that check_landing can tell how far it went.
 */
static void
skip_ahead(IntersectScanState *state, IndexScanDesc scan, EqualityKeys *keys,
		   SkipAhead *skip, int64 bound)
{
	BTScanOpaque so = (BTScanOpaque) scan->opaque;

	skip->landing = BTScanPosIsValid(so->currPos);
	if (skip->landing)
	{
		skip->from_page = so->currPos.currPage;
		skip->from_next = state->descending ?
			so->currPos.prevPage : so->currPos.nextPage;
	}

	rescan_with_keys(scan, keys, state->descending, bound);
	skip->behind = 0;
	state->skips++;
}

/*
 * check_landing
 *		After the first entry read since a skip: a skip that stayed on the
 *		leaf page it left or moved to the next one did not pay for its
 *		descent, so the side waits twice as long before the next one; a
 *		longer skip halves the wait, down to leapfrog.skip_after.  The
 *		threshold stays within 64 times leapfrog.skip_after.
 */
static void
check_landing(IntersectScanState *state, IndexScanDesc scan, SkipAhead *skip)
{
	BTScanOpaque so = (BTScanOpaque) scan->opaque;
	BlockNumber page;

	if (!skip->landing)
		return;
	skip->landing = false;

	page = so->currPos.currPage;
	if (page == skip->from_page || page == skip->from_next)
	{
		state->short_skips++;
		skip->threshold = Min(skip->threshold * 2,
							  (int64) intersect_skip_after * 64);
	}
	else
		skip->threshold = Max(skip->threshold / 2, intersect_skip_after);
}

/*
 * intersect_start
 *		Evaluate the equality values and position both index scans.
 *		Returns false when a value is NULL: nothing can match then.
 */
static bool
intersect_start(IntersectScanState *state)
{
	if (!evaluate_equal_values(state))
		return false;

	rescan_with_keys(state->outer_scan, &state->outer_keys,
					 state->descending, no_bound(state->descending));
	rescan_with_keys(state->inner_scan, &state->inner_keys,
					 state->descending, no_bound(state->descending));
	init_skip(&state->outer_skip);
	init_skip(&state->inner_skip);

	return true;
}

/*
 * row_matches_keys
 *		Do the heap row's columns equal the current values of one side?
 */
static bool
row_matches_keys(TupleTableSlot *slot, EqualityKeys *keys)
{
	for (int i = 0; i < keys->nequal; i++)
	{
		bool		isnull;
		Datum		value;

		value = slot_getattr(slot, keys->attnos[i], &isnull);
		if (isnull || DatumGetInt64(value) != keys->values[i])
			return false;
	}

	return true;
}

/*
 * row_matches_inner
 *		Would the inner index hold an entry for this row version: does it
 *		satisfy the inner equalities and the inner predicate?  Used where
 *		the row was not matched against the inner index by TID.
 */
static bool
row_matches_inner(IntersectScanState *state, TupleTableSlot *slot)
{
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;

	if (!row_matches_keys(slot, &state->inner_keys))
		return false;

	econtext->ecxt_scantuple = slot;

	return ExecQualAndReset(state->inner_pred, econtext);
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
	if (read_index_entry(state->inner_scan, dir, state->inner_sortpos + 1,
						 &state->inner_value,
						 &state->inner_tid, &state->inner_read))
	{
		state->have_inner = true;
		check_landing(state, state->inner_scan, &state->inner_skip);
	}
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
			 * inner index: check the inner conditions on the row itself.
			 */
			if (state->match_by_pred && !row_matches_inner(state, slot))
				continue;

			return slot;
		}

		if (!state->have_outer)
		{
			if (!read_index_entry(state->outer_scan, dir,
								  state->outer_keys.nequal + 1,
								  &state->outer_value, &state->outer_tid,
								  &state->outer_read))
				break;
			state->have_outer = true;
			check_landing(state, state->outer_scan, &state->outer_skip);
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
			state->outer_skip.behind = 0;
			state->inner_skip.behind = 0;
			collect_group(state, dir);
			continue;
		}

		/* the lagging side is the one still ahead in scan direction */
		if (state->descending)
			outer_lags = state->outer_value > state->inner_value;
		else
			outer_lags = state->outer_value < state->inner_value;

		/*
		 * Advance the lagging side by one entry, or, once it has read its
		 * threshold of entries in a row without catching up, descend its
		 * B-tree again straight to the other side's value.  The entries in
		 * between cannot match: the other side has consumed every value
		 * before its current one.
		 */
		if (outer_lags)
		{
			state->have_outer = false;
			state->inner_skip.behind = 0;
			if (++state->outer_skip.behind >= state->outer_skip.threshold)
				skip_ahead(state, state->outer_scan, &state->outer_keys,
						   &state->outer_skip, state->inner_value);
		}
		else
		{
			state->have_inner = false;
			state->outer_skip.behind = 0;
			if (++state->inner_skip.behind >= state->inner_skip.threshold)
				skip_ahead(state, state->inner_scan, &state->inner_keys,
						   &state->inner_skip, state->outer_value);
		}
	}

	/*
	 * The merge ends when one stream runs out, with the other one still
	 * positioned on a leaf page.  The scans keep their leaf page pinned, as
	 * an Index Only Scan does, since the sort value is read from the index
	 * tuple (xs_want_itup); VACUUM of the index would wait for that pin as
	 * long as an exhausted cursor stays open.  Resetting both scans releases
	 * the pins; a rescan positions them again.
	 */
	if (!state->done)
	{
		rescan_with_keys(state->outer_scan, &state->outer_keys,
						 state->descending, no_bound(state->descending));
		rescan_with_keys(state->inner_scan, &state->inner_keys,
						 state->descending, no_bound(state->descending));
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

	if (!evaluate_equal_values(state))
		return false;

	return row_matches_keys(slot, &state->outer_keys) &&
		row_matches_inner(state, slot);
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
		if (state->skips > 0)
		{
			ExplainPropertyInteger("Skips", NULL, state->skips, es);
			ExplainPropertyInteger("Short Skips", NULL, state->short_skips,
								   es);
		}
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

	DefineCustomIntVariable("leapfrog.skip_after",
							"Entries a lagging scan reads in a row before it re-descends its B-tree.",
							"Developer option for measuring skip-ahead; 0 turns skipping off.",
							&intersect_skip_after,
							INTERSECT_SKIP_AFTER,
							0,
							INT_MAX,
							PGC_USERSET,
							GUC_NOT_IN_SAMPLE,
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
