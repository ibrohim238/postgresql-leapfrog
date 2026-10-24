/*-------------------------------------------------------------------------
 *
 * costsize.c
 *	  Cost model of the Index Merge Intersect path.
 *
 * Costing follows ROR_intersect_plan::add, with every component expressed
 * through the planner's own cost functions:
 *
 *	  run = index_read_cost(each stream, entries read through the merge)
 *		   + cost of grouping the entries of one value, per inner stream
 *		   + cost of fetching the matched rows from the heap
 *		   + cost of the node's qual per fetched row and of the target list
 *			 per result row
 *	  startup = descent into every btree (CPU, as btcostestimate charges it)
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
 * Documented assumptions, not derived from statistics: inside the overlap
 * of the streams' sort ranges the matches are spread evenly along every
 * index (so a LIMIT is served by a proportional fraction of the total, as
 * the planner assumes for every path), and the TID group of one value has
 * the average size.  Skew inside the overlap can make a stream more
 * expensive than predicted.
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
 *		Cost of sorting the entries of each value of one inner stream and
 *		looking the outer entries up in them: log2 of the group size
 *		comparisons per entry.  The comparisons are inline
 *		ItemPointerCompare calls, not operator calls through the function
 *		manager, and are charged as cost_bitmap_tree_node charges the per-TID
 *		work of a bitmap: 0.1 * cpu_operator_cost each.  Measured
 *		(cost_bench.sh, two ordinary indexes, 15,000 entries, the same 118
 *		buffers as BitmapAnd): the node runs 3 times faster than BitmapAnd,
 *		while a full cpu_operator_cost per comparison made it the dearer
 *		plan.
 */
static Cost
group_cost(double outer_entries, double inner_entries, double group_size)
{
	return (outer_entries + inner_entries) * 0.1 * cpu_operator_cost *
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
 *		Cost of reading the index streams through the merge, with the
 *		skip-ahead of intersect_next.  reads[] holds the entries of each
 *		stream inside the overlap and is updated to what the merge reads.
 *
 * The two sparsest streams set the pace.  With the matches spread evenly,
 * the denser of the two has dense/sparse entries between two entries of the
 * sparser one.  Up to leapfrog.skip_after of them are read one by one; a gap
 * longer by more than two leaf pages is crossed by one more descent of the
 * B-tree, charged as btcostestimate charges a descent plus the leaf page it
 * lands on.  A shorter gap is read through: the executor backs off from
 * skips that land on the next leaf page (check_landing).
 *
 * Every further stream is pulled along: the merge advances a lagging stream
 * by one entry per iteration, and the entries read so far count the
 * iterations.  A stream clearly denser than that (more than twice) reads
 * about one entry per iteration and descends again every
 * leapfrog.skip_after of them (measured: 40,000 entries behind a pair of
 * 2,000 each read 5,200 with 46 skips, 460,000 behind 5,000 each read
 * 12,100 with 166); one near the pace keeps up and reads all its entries
 * (20,000 behind 5,000 and 10,000: all of them, 2 skips).
 */
static Cost
merge_read_cost(PlannerInfo *root, IndexCandidate **streams, int nstreams,
				double *reads, double loop_count)
{
	int			order[INTERSECT_MAX_STREAMS] = {0};
	double		sparse_entries;
	double		iterations;
	Cost		cost = 0;

	/* streams by entries, sparsest first (insertion sort, a few streams) */
	for (int i = 0; i < nstreams; i++)
		order[i] = i;
	for (int i = 1; i < nstreams; i++)
	{
		for (int j = i; j > 0 && reads[order[j - 1]] > reads[order[j]]; j--)
		{
			int			tmp = order[j];

			order[j] = order[j - 1];
			order[j - 1] = tmp;
		}
	}

	sparse_entries = Max(reads[order[0]], 1.0);
	iterations = sparse_entries;

	for (int n = 0; n < nstreams; n++)
	{
		int			i = order[n];
		IndexOptInfo *index = streams[i]->index;
		double		leaf_entries = index->tuples / Max(index->pages, 1);
		double		descents = 0;
		double		spc_random_page_cost;

		if (n == 1 && intersect_skip_after > 0 &&
			reads[i] / sparse_entries >
			intersect_skip_after + 2 * leaf_entries)
		{
			reads[i] = sparse_entries * intersect_skip_after;
			descents = sparse_entries;
		}
		else if (n >= 2 && reads[i] > 2 * iterations)
		{
			reads[i] = iterations;
			if (intersect_skip_after > 0)
				descents = iterations / intersect_skip_after;
		}
		if (n >= 1)
			iterations += reads[i];

		get_tablespace_page_costs(index->reltablespace, &spc_random_page_cost,
								  NULL);
		cost += index_read_cost(root, index, reads[i], loop_count) +
			descents * (descent_cost(index) + spc_random_page_cost);
	}

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
	candidate->range_sel = -1.0;
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
 *		Where the streams can meet: the merge reads only the entries inside
 *		the overlap of their sortcol ranges, skipping ahead into it, and
 *		matches can only lie there.  Sets the share of each stream's entries
 *		inside the overlap, and the factor that turns a row estimate made
 *		with the conditions independent over the whole table into one where
 *		they are independent inside the overlap:
 *
 *			rows' = rows * prod(share_i) / table_share^(nstreams - 1)
 *
 *		A stream is assumed to follow the table's distribution of sortcol
 *		within its own range.  All are 1 when a range cannot be probed; an
 *		empty overlap gives 0.
 */
static void
stream_overlap(PlannerInfo *root, RangeTblEntry *rte, Index rti,
			   AttrNumber sort_attno, IndexCandidate **streams, int nstreams,
			   double *shares, double *rows_factor)
{
	int64		lo;
	int64		hi;
	Selectivity table_share;

	for (int i = 0; i < nstreams; i++)
		shares[i] = 1.0;
	*rows_factor = 1.0;

	for (int i = 0; i < nstreams; i++)
	{
		if (!probe_range(rte, streams[i]))
			return;
	}

	lo = PG_INT64_MIN;
	hi = PG_INT64_MAX;
	for (int i = 0; i < nstreams; i++)
	{
		if (streams[i]->range_empty)
		{
			lo = 1;
			hi = 0;
			break;
		}
		lo = Max(lo, streams[i]->range_lo);
		hi = Min(hi, streams[i]->range_hi);
	}
	if (lo > hi)
	{
		for (int i = 0; i < nstreams; i++)
			shares[i] = 0.0;
		*rows_factor = 0.0;
		return;
	}

	/*
	 * The share of each stream's own range is computed once per candidate;
	 * the overlap is usually the range of the narrowest stream.
	 */
	table_share = -1.0;
	for (int i = 0; i < nstreams; i++)
	{
		IndexCandidate *stream = streams[i];

		if (stream->range_sel < 0)
			stream->range_sel = sortcol_range_selectivity(root, rti, sort_attno,
														  stream->range_lo,
														  stream->range_hi);
		if (stream->range_lo == lo && stream->range_hi == hi)
			table_share = stream->range_sel;
	}
	if (table_share < 0)
		table_share = sortcol_range_selectivity(root, rti, sort_attno, lo, hi);

	for (int i = 0; i < nstreams; i++)
	{
		Selectivity sel = streams[i]->range_sel;

		if (sel > 0)
			shares[i] = Min(table_share / sel, 1.0);
		if (table_share > 0)
			*rows_factor *= shares[i] / (i > 0 ? table_share : 1.0);
	}
}

/*
 * lf_index_entries
 *		Entries of an index matching the equalities on its leading columns.
 *		A partial index holds index->tuples entries to begin with.
 */
double
lf_index_entries(PlannerInfo *root, Index rti, IndexCandidate *candidate)
{
	double		entries = candidate->index->tuples;

	if (candidate->clauses != NIL)
		entries *= clauselist_selectivity(root, candidate->clauses, rti,
										  JOIN_INNER, NULL);

	return clamp_row_est(entries);
}

/*
 * stream_rows
 *		Rows of the relation that satisfy the conditions the streams
 *		enforce: the equalities of every stream and the predicates of the
 *		partial indexes, estimated the way the planner estimates the
 *		relation's rows from its restrictions.  The node fetches these rows
 *		from the heap; the remaining restrictions filter them afterwards.
 */
static double
stream_rows(PlannerInfo *root, RelOptInfo *rel, Index rti,
			IndexCandidate **streams, int nstreams)
{
	List	   *clauses = NIL;

	/* two streams on the same column share the clause: count it once */
	for (int i = 0; i < nstreams; i++)
	{
		clauses = list_concat_unique_ptr(clauses, streams[i]->clauses);
		clauses = list_concat_unique(clauses, streams[i]->index->indpred);
	}

	return clamp_row_est(rel->tuples *
						 clauselist_selectivity(root, clauses, rti,
												JOIN_INNER, NULL));
}

/*
 * lf_cost_intersect_path
 *		Set the rows, startup and total cost of an Index Merge Intersect path
 *		whose parameterization is set and whose rows hold the planner's
 *		estimate for the relation, as cost_index does for an index path.
 *		streams[0] is the outer index; every candidate has its entries set.
 *		ndistinct is lf_sortcol_ndistinct, correlation
 *		lf_outer_index_correlation of the outer index.  Returns in reads[]
 *		the entries each stream is expected to read, for EXPLAIN VERBOSE.
 */
void
lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
					   RangeTblEntry *rte, AttrNumber sort_attno,
					   IndexCandidate **streams, int nstreams,
					   double ndistinct, double correlation, double *reads)
{
	RelOptInfo *rel = cpath->path.parent;
	ParamPathInfo *param_info = cpath->path.param_info;
	double		rows = cpath->path.rows;
	double		shares[INTERSECT_MAX_STREAMS];
	double		rows_factor;
	double		loop_count;
	double		fetched;
	double		matches;
	double		pages_scanned = 0;
	QualCost	qpqual_cost;
	Cost		run_cost;
	Cost		first_match;
	Cost		startup_cost;

	loop_count = loop_count_for(root, PATH_REQ_OUTER(&cpath->path));
	restriction_qual_cost(root, rel, param_info, &qpqual_cost);

	/*
	 * Only the entries inside the overlap of the streams' sortcol ranges are
	 * read, and the matches lie there (stream_overlap); a stream that starts
	 * outside it skips in with one more descent.
	 */
	stream_overlap(root, rte, rel->relid, sort_attno, streams, nstreams,
				   shares, &rows_factor);
	for (int i = 0; i < nstreams; i++)
	{
		reads[i] = streams[i]->entries * shares[i];
		pages_scanned += streams[i]->index->pages;
	}

	/*
	 * The rows the streams agree on are fetched from the heap and the node's
	 * qual filters them; the result rows are the planner's estimate inside
	 * the overlap.  Neither exceeds the entries of the sparsest stream.
	 */
	fetched = stream_rows(root, rel, rel->relid, streams, nstreams) *
		rows_factor;
	matches = rows * rows_factor;
	for (int i = 0; i < nstreams; i++)
		fetched = Min(fetched, reads[i]);
	matches = Min(matches, fetched);

	/*
	 * Reading the indexes, grouping the entries of each value of every inner
	 * stream, fetching the agreed rows and running the qual on them, the
	 * target list on the result rows.  The heap fetches are charged as for an
	 * Index Scan on the outer index (see lf_outer_index_correlation).
	 */
	run_cost = merge_read_cost(root, streams, nstreams, reads, loop_count);
	for (int i = 1; i < nstreams; i++)
		run_cost += group_cost(reads[0], reads[i],
							   Max(1.0, streams[i]->entries / ndistinct));
	run_cost += heap_fetch_cost(root, rel, fetched, loop_count, correlation,
								pages_scanned) +
		fetched * (cpu_tuple_cost + qpqual_cost.per_tuple) +
		matches * rel->reltarget->cost.per_tuple;
	for (int i = 0; i < nstreams; i++)
	{
		if (shares[i] < 1.0)
			run_cost += descent_cost(streams[i]->index);
	}

	/*
	 * Every stream advances through run/(matches+1) of the merge before the
	 * first match: that share is startup, the rest is the run after it, and
	 * the total is the descents plus the whole merge.
	 */
	first_match = run_cost / (matches + 1);
	startup_cost = qpqual_cost.startup + rel->reltarget->cost.startup +
		first_match;
	for (int i = 0; i < nstreams; i++)
		startup_cost += descent_cost(streams[i]->index);

	/*
	 * The row estimate of the path is the matches: a Limit above takes the
	 * share limit/rows of the run, which is right only when rows counts what
	 * the node returns.  Without a probe this is the planner's estimate.
	 */
	cpath->path.rows = clamp_row_est(matches);
	cpath->path.startup_cost = startup_cost;
	cpath->path.total_cost = startup_cost + run_cost - first_match;
}
