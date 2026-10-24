/*-------------------------------------------------------------------------
 *
 * costsize.c
 *	  Cost model of the Index Merge Intersect path.
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
 * IDENTIFICATION
 *	  src/costsize.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <math.h>

#include "access/relscan.h"
#include "access/stratnum.h"
#include "access/table.h"
#include "catalog/pg_opfamily_d.h"
#include "catalog/pg_statistic.h"
#include "catalog/pg_type.h"
#include "nodes/makefuncs.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "utils/lsyscache.h"
#include "utils/selfuncs.h"
#include "utils/snapmgr.h"
#include "utils/spccache.h"

#include "leapfrog.h"

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
 * lf_outer_index_correlation
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

double
lf_outer_index_correlation(PlannerInfo *root, Index rti, IndexOptInfo *outer)
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
 * lf_sortcol_ndistinct
 *		Number of distinct sortcol values in the whole relation, which
 *		divides the inner entries into TID groups.  Taken from the column
 *		statistics: estimate_num_groups would clamp it to the relation's row
 *		estimate after the query's restrictions, and with a unique sort
 *		column and a selective query the groups would come out hundreds of
 *		entries large instead of one.
 */
double
lf_sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 AttrNumber sort_attno)
{
	Var		   *var = makeVar(rti, sort_attno, INT8OID, -1, InvalidOid, 0);
	VariableStatData vardata;
	bool		isdefault;
	double		ndistinct;

	examine_variable(root, (Node *) var, 0, &vardata);
	ndistinct = get_variable_numdistinct(&vardata, &isdefault);
	ReleaseVariableStats(vardata);

	return Max(ndistinct, 1.0);
}

/*
 * probe_range
 *		The smallest and the largest sortcol value of the stream, read from
 *		the index with one descent from each end, as get_actual_variable_range
 *		reads the ends of a column for the selectivity functions.  Only when
 *		every equality value is a constant at plan time: a parameterized path
 *		or a generic plan is costed without it.  Entries are read regardless
 *		of visibility (SnapshotAny); a dead entry at an end only widens the
 *		range.  The result is cached in the candidate; returns false when the
 *		range cannot be probed.
 */
static bool
probe_range(RangeTblEntry *rte, IndexCandidate *candidate)
{
	EqualityKeys keys;
	Relation	heap;
	Relation	index;
	IndexScanDesc scan;
	ItemPointerData tid;
	int64		entries = 0;
	ListCell   *lc;

	if (candidate->range_known >= 0)
		return candidate->range_known == 1;
	candidate->range_known = 0;

	keys.nequal = 0;
	foreach(lc, candidate->exprs)
	{
		Const	   *value = (Const *) lfirst(lc);

		if (!IsA(value, Const) || value->constisnull)
			return false;
		keys.values[keys.nequal++] = lf_datum_get_int64(value->constvalue,
														value->consttype);
	}

	/* the planner holds locks on the table and its indexes */
	heap = table_open(rte->relid, NoLock);
	index = index_open(candidate->index->indexoid, NoLock);
	scan = index_beginscan(heap, index, SnapshotAny, NULL, keys.nequal + 1, 0);
	scan->xs_want_itup = true;

	lf_rescan_with_keys(scan, &keys, false, lf_no_bound(false));
	candidate->range_empty = !lf_read_index_entry(scan, ForwardScanDirection,
												  keys.nequal + 1,
												  &candidate->range_lo, &tid,
												  &entries);
	if (!candidate->range_empty)
	{
		lf_rescan_with_keys(scan, &keys, true, lf_no_bound(true));
		if (!lf_read_index_entry(scan, BackwardScanDirection, keys.nequal + 1,
								 &candidate->range_hi, &tid, &entries))
			candidate->range_hi = candidate->range_lo;
	}

	index_endscan(scan);
	index_close(index, NoLock);
	table_close(heap, NoLock);

	candidate->range_known = 1;
	return true;
}

/*
 * sortcol_range_selectivity
 *		Share of the table's rows with lo <= sortcol <= hi, from the column's
 *		histogram.
 */
static Selectivity
sortcol_range_selectivity(PlannerInfo *root, Index rti, AttrNumber sort_attno,
						  int64 lo, int64 hi)
{
	Var		   *var = makeVar(rti, sort_attno, INT8OID, -1, InvalidOid, 0);
	List	   *clauses = NIL;
	Oid			ge = get_opfamily_member(INTEGER_BTREE_FAM_OID, INT8OID, INT8OID,
										 BTGreaterEqualStrategyNumber);
	Oid			le = get_opfamily_member(INTEGER_BTREE_FAM_OID, INT8OID, INT8OID,
										 BTLessEqualStrategyNumber);

	clauses = lappend(clauses,
					  make_opclause(ge, BOOLOID, false, (Expr *) var,
									(Expr *) makeConst(INT8OID, -1, InvalidOid,
													   sizeof(int64),
													   Int64GetDatum(lo),
													   false, FLOAT8PASSBYVAL),
									InvalidOid, InvalidOid));
	clauses = lappend(clauses,
					  make_opclause(le, BOOLOID, false, (Expr *) var,
									(Expr *) makeConst(INT8OID, -1, InvalidOid,
													   sizeof(int64),
													   Int64GetDatum(hi),
													   false, FLOAT8PASSBYVAL),
									InvalidOid, InvalidOid));

	return clauselist_selectivity(root, clauses, rti, JOIN_INNER, NULL);
}

/*
 * stream_overlap
 *		Where the two streams can meet: the merge reads only the entries
 *		inside the overlap of their sortcol ranges, skipping ahead into it,
 *		and matches can only lie there.  Sets the share of each stream's
 *		entries inside the overlap, and the factor that turns the planner's
 *		row estimate (both conditions independent over the whole table) into
 *		one where they are independent inside the overlap:
 *
 *			rows' = rows * outer_share * inner_share / table_share
 *
 *		A stream is assumed to follow the table's distribution of sortcol
 *		within its own range.  All three are 1 when a range cannot be probed;
 *		an empty overlap gives 0.
 */
static void
stream_overlap(PlannerInfo *root, RangeTblEntry *rte, Index rti,
			   AttrNumber sort_attno, IndexCandidate *outer,
			   IndexCandidate *inner, double *outer_share,
			   double *inner_share, double *rows_factor)
{
	int64		lo;
	int64		hi;
	Selectivity table_share;
	Selectivity outer_sel;
	Selectivity inner_sel;

	*outer_share = 1.0;
	*inner_share = 1.0;
	*rows_factor = 1.0;

	if (!probe_range(rte, outer) || !probe_range(rte, inner))
		return;

	lo = Max(outer->range_lo, inner->range_lo);
	hi = Min(outer->range_hi, inner->range_hi);
	if (outer->range_empty || inner->range_empty || lo > hi)
	{
		*outer_share = 0.0;
		*inner_share = 0.0;
		*rows_factor = 0.0;
		return;
	}

	table_share = sortcol_range_selectivity(root, rti, sort_attno, lo, hi);
	outer_sel = sortcol_range_selectivity(root, rti, sort_attno,
										  outer->range_lo, outer->range_hi);
	inner_sel = sortcol_range_selectivity(root, rti, sort_attno,
										  inner->range_lo, inner->range_hi);

	if (outer_sel > 0)
		*outer_share = Min(table_share / outer_sel, 1.0);
	if (inner_sel > 0)
		*inner_share = Min(table_share / inner_sel, 1.0);
	if (table_share > 0)
		*rows_factor = *outer_share * *inner_share / table_share;
}

/*
 * lf_index_entries
 *		Entries of an index matching the equalities on its leading columns.
 *		A partial index holds index->tuples entries to begin with.
 */
double
lf_index_entries(PlannerInfo *root, Index rti, IndexOptInfo *index,
				 IndexCandidate *candidate)
{
	double		entries = index->tuples;

	if (candidate->clauses != NIL)
		entries *= clauselist_selectivity(root, candidate->clauses, rti,
										  JOIN_INNER, NULL);

	return clamp_row_est(entries);
}

/*
 * lf_cost_intersect_path
 *		Set the rows, startup and total cost of an Index Merge Intersect path
 *		whose parameterization is set and whose rows hold the planner's
 *		estimate for the relation, as cost_index does for an index path.
 *		outer_entries and inner_entries are lf_index_entries of both sides,
 *		group_size the expected TID group, correlation
 *		lf_outer_index_correlation of the outer index.  Returns the entries
 *		each side is expected to read, for EXPLAIN VERBOSE.
 */
void
lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
					   RangeTblEntry *rte, AttrNumber sort_attno,
					   IndexCandidate *outer_candidate,
					   IndexCandidate *inner_candidate,
					   double outer_entries, double inner_entries,
					   double group_size, double correlation,
					   double *outer_read_p, double *inner_read_p)
{
	RelOptInfo *rel = cpath->path.parent;
	ParamPathInfo *param_info = cpath->path.param_info;
	IndexOptInfo *outer = outer_candidate->index;
	IndexOptInfo *inner = inner_candidate->index;
	double		rows = cpath->path.rows;
	double		loop_count;
	double		outer_share;
	double		inner_share;
	double		rows_factor;
	double		outer_read;
	double		inner_read;
	double		matches;
	QualCost	qpqual_cost;
	Cost		run_cost;
	Cost		startup_cost;

	loop_count = loop_count_for(root, PATH_REQ_OUTER(&cpath->path));
	restriction_qual_cost(root, rel, param_info, &qpqual_cost);

	/*
	 * Only the entries inside the overlap of the two streams' sortcol ranges
	 * are read, and the matches lie there (stream_overlap); a stream that
	 * starts outside it skips in with one more descent.
	 */
	stream_overlap(root, rte, rel->relid, sort_attno, outer_candidate,
				   inner_candidate, &outer_share, &inner_share, &rows_factor);
	outer_read = outer_entries * outer_share;
	inner_read = inner_entries * inner_share;
	matches = Min(rows * rows_factor, Min(outer_read, inner_read));

	/*
	 * Reading both indexes, grouping the entries of each value, fetching the
	 * matched rows and running the qual and the target list on them.  The
	 * heap fetches are charged as for an Index Scan on the outer index (see
	 * lf_outer_index_correlation).
	 */
	run_cost = merge_read_cost(root, outer, inner, outer_read, inner_read,
							   loop_count) +
		group_cost(outer_read, inner_read, group_size) +
		heap_fetch_cost(root, rel, matches, loop_count, correlation,
						(double) outer->pages + inner->pages) +
		matches * (cpu_tuple_cost + qpqual_cost.per_tuple +
				   rel->reltarget->cost.per_tuple);
	if (outer_share < 1.0)
		run_cost += descent_cost(outer);
	if (inner_share < 1.0)
		run_cost += descent_cost(inner);

	/* both streams advance through run/(matches+1) before the first match */
	startup_cost = descent_cost(outer) + descent_cost(inner) +
		qpqual_cost.startup + rel->reltarget->cost.startup +
		run_cost / (matches + 1);

	/*
	 * The row estimate of the path is the matches: a Limit above takes the
	 * share limit/rows of the run, which is right only when rows counts what
	 * the node returns.  Without a probe this is the planner's estimate.
	 */
	cpath->path.rows = clamp_row_est(matches);
	cpath->path.startup_cost = startup_cost;
	cpath->path.total_cost = startup_cost + run_cost;
}
	*outer_read_p = outer_read;
	*inner_read_p = inner_read;
