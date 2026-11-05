/*-------------------------------------------------------------------------
 *
 * costsize.c
 *	  Cost model of the Index Merge Intersect path.
 *
 * Every component is expressed through the planner's own cost functions:
 *
 *	  run = index_read_cost(each stream, entries read through the merge)
 *		   + cost of grouping the entries of each value, per inner stream
 *		   + cost of fetching the matched rows from the heap
 *		   + cost of the node's qual per fetched row and of the target list
 *			 per result row
 *	  startup = descent into every btree (CPU, as btcostestimate charges it)
 *			  + the share of run spent before the first match, no less than
 *				reading and sorting the first group of every inner stream
 *	  total = descents + startup costs of the qual and target list + run
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
 * the planner assumes for every path), and a TID group out of the most common
 * values has the average size.  Skew among the others can make a stream more
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
#include "catalog/pg_statistic.h"
#include "catalog/pg_attribute.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "optimizer/cost.h"
#include "optimizer/optimizer.h"
#include "optimizer/restrictinfo.h"
#include "parser/parse_oper.h"
#include "parser/parsetree.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"
#include "utils/snapmgr.h"
#include "utils/spccache.h"
#include "utils/typcache.h"

#include "leapfrog.h"

/* Where the streams of a set can meet (stream_overlap). */
typedef struct StreamOverlap
{
	RangeTblEntry *rte;
	IndexCandidate **streams;
	int			nstreams;
	bool		probed;
	bool		empty;
	Datum		lo;
	Datum		hi;
	double		table_share;
	double		null_frac;
} StreamOverlap;

/* Cached result of stream_holds_group. */
typedef struct GroupProbe
{
	Datum		value;
	bool		isnull;
	bool		present;
} GroupProbe;

/*
 * index_read_cost
 *		Cost of reading the given number of index entries sequentially, charged
 *		as genericcostestimate does: random_page_cost of the tablespace per
 *		page, and for a scan repeated loop_count times the Mackert-Lohman
 *		estimate of the pages fetched, divided by the repetitions.
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
 *		Correlation of the heap with the outer index, as btcostestimate
 *		estimates it for an Index Scan on that index: of its leading column,
 *		times 0.75 for a multicolumn index.  Zero without statistics.
 *
 * With the leading columns fixed the rows may well be more correlated, but an
 * Index Scan on the outer index visits the same rows in the same order and is
 * costed with this estimate; a better one would let the node win on heap pages
 * both plans read alike.
 */
static double column_correlation(PlannerInfo *root, Index rti,
								 AttrNumber attno);

double
lf_outer_index_correlation(PlannerInfo *root, Index rti, IndexOptInfo *outer)
{
	double		correlation;

	lf_trace.correlations++;
	correlation = column_correlation(root, rti, outer->indexkeys[0]);
	if (outer->nkeycolumns > 1)
		correlation *= 0.75;

	return correlation;
}

/*
 * column_var
 *		A Var for column attno of relation rti, as the selectivity functions
 *		expect it.  A domain column gets its base type, which the operators
 *		are found for.
 */
static Var *
column_var(PlannerInfo *root, Index rti, AttrNumber attno)
{
	Oid			type;
	int32		typmod;
	Oid			collation;

	get_atttypetypmodcoll(planner_rt_fetch(rti, root)->relid, attno,
						  &type, &typmod, &collation);

	return makeVar(rti, attno, getBaseTypeAndTypmod(type, &typmod), typmod,
				   collation, 0);
}

/*
 * column_correlation
 *		Correlation of a column with the heap order, from the pg_statistic
 *		slot of its type's default "<" operator, which ANALYZE uses.
 */
static double
column_correlation(PlannerInfo *root, Index rti, AttrNumber attno)
{
	Var		   *var = column_var(root, rti, attno);
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

	sortop = lookup_type_cache(var->vartype, TYPECACHE_LT_OPR)->lt_opr;
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
 *		Cost of fetching the result rows from the heap, as cost_index charges
 *		heap pages: the rows are visited in sort column order, so the pages lie
 *		between the perfectly correlated case (consecutive, read sequentially)
 *		and the uncorrelated one (Mackert-Lohman), by the squared correlation.
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

	/* correlated: consecutive pages, the rows' share of the heap */
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
 *		comparisons per entry.  These are inline ItemPointerCompare calls, not
 *		operator calls through the function manager, and are charged as
 *		cost_bitmap_tree_node charges a bitmap's per-TID work: 0.1 *
 *		cpu_operator_cost each.
 */
static Cost
group_cost(double outer_entries, double inner_entries, double group_size)
{
	return (outer_entries + inner_entries) * 0.1 * cpu_operator_cost *
		log2(group_size + 1);
}

/*
 * loop_count_for
 *		Expected rescans of a path parameterized by outer_relids inside a
 *		nestloop: the smallest row estimate among the outer rels, as
 *		get_loop_count computes it (its semijoin adjustment is private to
 *		indxpath.c).
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
 * node_qual_cost
 *		Cost of the quals the node evaluates on a fetched row: the rel's own
 *		restrictions and the clauses pushed down into a parameterized path,
 *		less those the streams enforce (lf_node_quals).
 */
static void
node_qual_cost(PlannerInfo *root, RelOptInfo *rel, ParamPathInfo *param_info,
			   IndexCandidate **streams, int nstreams, QualCost *qpqual_cost)
{
	IndexOptInfo *indexes[INTERSECT_MAX_STREAMS];
	List	   *exprs[INTERSECT_MAX_STREAMS];
	List	   *clauses = rel->baserestrictinfo;

	if (param_info != NULL)
		clauses = list_concat_copy(clauses, param_info->ppi_clauses);

	for (int i = 0; i < nstreams; i++)
	{
		indexes[i] = streams[i]->index;
		exprs[i] = streams[i]->exprs;
	}

	cost_qual_eval(qpqual_cost,
				   lf_node_quals(root, rel, indexes, exprs, nstreams, clauses),
				   root);
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
 * lf_stream_min_cost
 *		The least a stream adds to a set: its descent and one leaf page.
 */
Cost
lf_stream_min_cost(IndexOptInfo *index)
{
	double		spc_random_page_cost;

	get_tablespace_page_costs(index->reltablespace, &spc_random_page_cost, NULL);

	return descent_cost(index) + spc_random_page_cost;
}

/*
 * merge_read_cost
 *		Cost of reading the streams through the merge, with the skip-ahead of
 *		find_common_value.  reads[] holds each stream's entries inside the
 *		overlap and is updated to what the merge reads; ranks[] gets each
 *		stream's turn in the merge, sparsest first.
 *
 * A stream has to reach only the values every sparser stream agrees on.  With
 * the streams independent, the sparsest stream's entries are the first such
 * values, and each further stream keeps the share of them that it holds among
 * the table's rows.  With the matches spread evenly, a stream has
 * entries/values entries between two of those values.  Up to
 * leapfrog.skip_after of them are read one by one; a gap longer by more than
 * two leaf pages is crossed by one more descent, charged as btcostestimate
 * charges a descent plus the leaf page it lands on.  A shorter gap is read
 * through: the executor backs off from skips that land on the next leaf page
 * (check_landing).
 */
static Cost
merge_read_cost(PlannerInfo *root, IndexCandidate **streams, int nstreams,
				double *reads, int *ranks, double table_rows, double loop_count)
{
	int			order[INTERSECT_MAX_STREAMS] = {0};
	double		values;
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

	values = Max(reads[order[0]], 1.0);

	for (int n = 0; n < nstreams; n++)
	{
		int			i = order[n];
		IndexOptInfo *index = streams[i]->index;
		double		leaf_entries = index->tuples / Max(index->pages, 1);
		double		entries = reads[i];
		double		descents = 0;
		double		spc_random_page_cost;

		ranks[i] = n;

		if (n >= 1 && intersect_skip_after > 0 &&
			entries / values > intersect_skip_after + 2 * leaf_entries)
		{
			reads[i] = values * intersect_skip_after;
			descents = values;
		}
		if (n >= 1 && table_rows > 0)
			values = Max(values * Min(entries / table_rows, 1.0), 1.0);

		get_tablespace_page_costs(index->reltablespace, &spc_random_page_cost,
								  NULL);
		cost += index_read_cost(root, index, reads[i], loop_count) +
			descents * (descent_cost(index) + spc_random_page_cost);
	}

	return cost;
}

/*
 * lf_sortcol_ndistinct
 *		Distinct sortcol values in the whole relation, which divide the inner
 *		entries into TID groups.  From the column statistics: with a unique
 *		sort column and a selective query, estimate_num_groups' clamp to the
 *		row estimate would make groups of hundreds of entries instead of one.
 */
double
lf_sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel, Index rti,
					 AttrNumber sort_attno)
{
	Var		   *var = column_var(root, rti, sort_attno);
	VariableStatData vardata;
	bool		isdefault;
	double		ndistinct;

	examine_variable(root, (Node *) var, 0, &vardata);
	ndistinct = get_variable_numdistinct(&vardata, &isdefault);
	ReleaseVariableStats(vardata);

	return Max(ndistinct, 1.0);
}

/*
 * candidate_const_keys
 *		The scan keys of a stream; false unless every equality value is a constant.
 */
static bool
candidate_const_keys(SortColumn *sort, IndexCandidate *candidate,
					 EqualityKeys *keys)
{
	ListCell   *lc;

	keys->nequal = 0;
	foreach(lc, candidate->exprs)
	{
		Node	   *expr = (Node *) lfirst(lc);
		Const	   *value;

		while (IsA(expr, RelabelType))
			expr = (Node *) ((RelabelType *) expr)->arg;
		if (!IsA(expr, Const) || ((Const *) expr)->constisnull)
			return false;
		value = (Const *) expr;
		keys->values[keys->nequal] = value->constvalue;
		keys->operators[keys->nequal] = list_nth_oid(candidate->operators,
													 keys->nequal);
		keys->collations[keys->nequal] = list_nth_oid(candidate->collations,
													  keys->nequal);
		keys->nequal++;
	}
	lf_init_key_procs(keys, sort->type, sort->opfamily, sort->collation,
					  sort->descending);

	return true;
}

/*
 * probe_range
 *		The smallest and the largest sortcol value of the stream, one descent
 *		from each end, as get_actual_variable_range reads a column's ends.
 *		Only when every equality value is a constant at plan time: a
 *		parameterized path or a generic plan is costed without it.  Entries
 *		are read regardless of visibility (SnapshotAny); a dead entry at an end
 *		only widens the range.  The values are copied: they outlive the scan.
 *		Cached in the candidate; false when the range cannot be probed.
 */
static bool
probe_range(RangeTblEntry *rte, SortColumn *sort, IndexCandidate *candidate)
{
	EqualityKeys keys;
	Relation	heap;
	Relation	index;
	IndexScanDesc scan;
	ItemPointerData tid;
	int64		entries = 0;
	Form_pg_attribute attr;
	int			sort_keyno = candidate->sortpos + 1;
	bool		isnull;
	ScanDirection low_end;

	if (candidate->range_known >= 0)
		return candidate->range_known == 1;
	candidate->range_known = 0;

	if (!candidate_const_keys(sort, candidate, &keys))
		return false;

	/* the planner holds locks on the table and its indexes */
	heap = table_open(rte->relid, NoLock);
	index = index_open(candidate->index->indexoid, NoLock);
	lf_trace.range_scans++;
	scan = lf_index_beginscan(heap, index, SnapshotAny, keys.nequal + 1);
	scan->xs_want_itup = true;

	attr = TupleDescAttr(RelationGetDescr(index), sort_keyno - 1);

	/* NULLs are at one end of the index and no end of the range */
	low_end = candidate->index->reverse_sort[candidate->sortpos] ?
		BackwardScanDirection : ForwardScanDirection;
	lf_rescan_with_keys(scan, &keys, SORT_BOUND_NOT_NULL, (Datum) 0);
	candidate->range_empty = !lf_read_index_entry(scan, low_end,
												  sort_keyno, true,
												  &candidate->range_lo, &isnull,
												  &tid, &entries, NULL);
	if (!candidate->range_empty)
	{
		candidate->range_lo = datumCopy(candidate->range_lo, attr->attbyval,
										attr->attlen);
		lf_rescan_with_keys(scan, &keys, SORT_BOUND_NOT_NULL, (Datum) 0);
		if (lf_read_index_entry(scan, -low_end, sort_keyno, true,
								&candidate->range_hi, &isnull, &tid, &entries, NULL))
			candidate->range_hi = datumCopy(candidate->range_hi, attr->attbyval,
											attr->attlen);
		else
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
 *		histogram, with the operators of the type and collation the query
 *		sorts in.
 */
static Selectivity
sortcol_range_selectivity(PlannerInfo *root, Index rti, SortColumn *sort,
						  Datum lo, Datum hi)
{
	Var		   *var = column_var(root, rti, sort->attno);
	Expr	   *column = (Expr *) var;
	Oid			const_type = sort->type;
	int16		typlen;
	bool		typbyval;
	List	   *clauses = NIL;

	/* varchar sorts as text; a polymorphic class takes the column's own type */
	if (IsPolymorphicType(sort->type))
		const_type = var->vartype;
	else if (var->vartype != sort->type)
		column = (Expr *) makeRelabelType(column, sort->type, -1, sort->collation,
										  COERCE_IMPLICIT_CAST);
	get_typlenbyval(const_type, &typlen, &typbyval);

	clauses = lappend(clauses,
					  make_opclause(get_opfamily_member(sort->opfamily, sort->type,
														sort->type,
														BTGreaterEqualStrategyNumber),
									BOOLOID, false, column,
									(Expr *) makeConst(const_type, -1, sort->collation,
													   typlen, lo, false, typbyval),
									InvalidOid, sort->collation));
	clauses = lappend(clauses,
					  make_opclause(get_opfamily_member(sort->opfamily, sort->type,
														sort->type,
														BTLessEqualStrategyNumber),
									BOOLOID, false, column,
									(Expr *) makeConst(const_type, -1, sort->collation,
													   typlen, hi, false, typbyval),
									InvalidOid, sort->collation));

	return clauselist_selectivity(root, clauses, rti, JOIN_INNER, NULL);
}

/*
 * range_compare
 *		Compare two sortcol values in ascending order, in the query's
 *		collation.
 */
static int
range_compare(SortColumn *sort, Datum a, Datum b)
{
	if (!sort->range_ssup_ready)
	{
		Oid			lt = get_opfamily_member(sort->opfamily, sort->type, sort->type,
											 BTLessStrategyNumber);

		memset(&sort->range_ssup, 0, sizeof(SortSupportData));
		sort->range_ssup.ssup_cxt = CurrentMemoryContext;
		sort->range_ssup.ssup_collation = sort->collation;
		PrepareSortSupportFromOrderingOp(lt, &sort->range_ssup);
		sort->range_ssup_ready = true;
	}

	return ApplySortComparator(a, false, b, false, &sort->range_ssup);
}

/* mcv_order_cmp: the most common values by ascending value */
typedef struct McvOrderArg
{
	SortColumn *sort;
	SortStats  *stats;
} McvOrderArg;

static int
mcv_order_cmp(const void *a, const void *b, void *arg)
{
	McvOrderArg *order = (McvOrderArg *) arg;

	return range_compare(order->sort, order->stats->mcv[*(const int *) a],
						 order->stats->mcv[*(const int *) b]);
}

/*
 * sort_stats
 *		The sort column's statistics, read on first use.  The histogram and the
 *		most common values are in the column's default order and collation, and
 *		serve only a query that sorts in those.
 */
static SortStats *
sort_stats(PlannerInfo *root, Index rti, SortColumn *sort)
{
	SortStats  *stats;
	Var		   *var;
	VariableStatData vardata;
	Oid			sortop;
	Oid			eqop;
	AttStatsSlot hist;
	AttStatsSlot mcv;
	double		mcv_total = 0.0;
	double		null_frac;

	if (sort->stats != NULL)
		return sort->stats;

	lf_trace.stat_loads++;
	stats = palloc0(sizeof(SortStats));
	sort->stats = stats;
	var = column_var(root, rti, sort->attno);
	examine_variable(root, (Node *) var, 0, &vardata);
	if (!HeapTupleIsValid(vardata.statsTuple))
	{
		ReleaseVariableStats(vardata);
		return stats;
	}

	get_sort_group_operators(var->vartype, true, false, false, &sortop, &eqop,
							 NULL, NULL);
	null_frac = ((Form_pg_statistic) GETSTRUCT(vardata.statsTuple))->stanullfrac;

	if (sortop == get_opfamily_member(sort->opfamily, sort->type, sort->type,
									  BTLessStrategyNumber))
	{
		bool		mcv_usable = true;

		if (get_attstatsslot(&mcv, vardata.statsTuple, STATISTIC_KIND_MCV,
							 InvalidOid,
							 ATTSTATSSLOT_VALUES | ATTSTATSSLOT_NUMBERS))
		{
			if (mcv.stacoll == sort->collation)
			{
				stats->mcv = mcv.values;
				stats->mcv_freq = mcv.numbers;
				stats->nmcv = mcv.nvalues;
				for (int i = 0; i < mcv.nvalues; i++)
					mcv_total += mcv.numbers[i];
				stats->mcv_total = mcv_total;
			}
			else
				mcv_usable = false;
		}

		if (mcv_usable &&
			get_attstatsslot(&hist, vardata.statsTuple, STATISTIC_KIND_HISTOGRAM,
							 sortop, ATTSTATSSLOT_VALUES) &&
			hist.nvalues >= 2 && hist.stacoll == sort->collation)
		{
			stats->hist = hist.values;
			stats->nhist = hist.nvalues;
			stats->usable = true;
			stats->hist_frac = Max(1.0 - null_frac - mcv_total, 0.0);

			/* the comparators that compare plain integers */
			range_compare(sort, stats->hist[0], stats->hist[0]);
#if LF_DATUM_IS_64BIT
			if (sort->range_ssup.comparator == ssup_datum_signed_cmp)
			{
				stats->interpolate = true;
				stats->signed64 = true;
			}
#endif
			if (sort->range_ssup.comparator == ssup_datum_int32_cmp)
				stats->interpolate = true;
		}

		if (stats->nmcv > 0)
		{
			McvOrderArg arg = {sort, stats};

			stats->mcv_order = palloc(stats->nmcv * sizeof(int));
			for (int i = 0; i < stats->nmcv; i++)
				stats->mcv_order[i] = i;
			qsort_arg(stats->mcv_order, stats->nmcv, sizeof(int),
					  mcv_order_cmp, &arg);
		}
	}

	ReleaseVariableStats(vardata);

	return stats;
}

/*
 * histogram_position
 *		Share of the histogram's rows below the value, and in *bin the bin it
 *		falls in.  Within a bin by value for integers, its middle for the rest.
 */
static double
histogram_position(SortColumn *sort, SortStats *stats, Datum value, int *bin)
{
	int			lo = 0;
	int			hi = stats->nhist - 1;
	double		within = 0.5;

	if (range_compare(sort, value, stats->hist[0]) < 0)
	{
		*bin = -1;
		return 0.0;
	}
	if (range_compare(sort, value, stats->hist[hi]) >= 0)
	{
		*bin = stats->nhist;
		return 1.0;
	}

	while (hi - lo > 1)
	{
		int			mid = (lo + hi) / 2;

		if (range_compare(sort, value, stats->hist[mid]) < 0)
			hi = mid;
		else
			lo = mid;
	}
	*bin = lo;

	if (stats->interpolate)
	{
		double		a = stats->signed64 ? (double) DatumGetInt64(stats->hist[lo]) :
			(double) DatumGetInt32(stats->hist[lo]);
		double		b = stats->signed64 ? (double) DatumGetInt64(stats->hist[hi]) :
			(double) DatumGetInt32(stats->hist[hi]);
		double		v = stats->signed64 ? (double) DatumGetInt64(value) :
			(double) DatumGetInt32(value);

		if (b > a)
			within = (v - a) / (b - a);
	}

	return (lo + within) / (stats->nhist - 1);
}

/*
 * sortcol_range_share
 *		Share of the table's rows with lo <= sortcol <= hi.  From the statistics
 *		read once when they can tell; otherwise, and for a range inside one bin
 *		of a type without interpolation, by the selectivity functions.
 */
static Selectivity
sortcol_range_share(PlannerInfo *root, Index rti, SortColumn *sort, Datum lo,
					Datum hi)
{
	SortStats  *stats = sort_stats(root, rti, sort);
	int			lo_bin;
	int			hi_bin;
	double		lo_pos;
	double		hi_pos;
	double		share;

	if (!stats->usable)
	{
		lf_trace.range_fallbacks++;
		return sortcol_range_selectivity(root, rti, sort, lo, hi);
	}

	lo_pos = histogram_position(sort, stats, lo, &lo_bin);
	hi_pos = histogram_position(sort, stats, hi, &hi_bin);
	if (lo_bin == hi_bin && !stats->interpolate)
	{
		lf_trace.range_fallbacks++;
		return sortcol_range_selectivity(root, rti, sort, lo, hi);
	}

	share = stats->hist_frac * Max(hi_pos - lo_pos, 0.0);
	for (int i = 0; i < stats->nmcv; i++)
	{
		if (range_compare(sort, stats->mcv[i], lo) >= 0 &&
			range_compare(sort, stats->mcv[i], hi) <= 0)
			share += stats->mcv_freq[i];
	}

	return Max(Min(share, 1.0), 1e-10);
}

/*
 * sortcol_null_frac
 *		Share of the table's rows with a NULL in the sort column, from its
 *		statistics; 0 for a NOT NULL column.
 */
static double
sortcol_null_frac(PlannerInfo *root, Index rti, SortColumn *sort)
{
	if (sort->null_frac < 0)
	{
		sort->null_frac = 0.0;
		if (!sort->notnull)
		{
			VariableStatData vardata;

			examine_variable(root, (Node *) column_var(root, rti, sort->attno),
							 0, &vardata);
			if (HeapTupleIsValid(vardata.statsTuple))
				sort->null_frac =
					((Form_pg_statistic) GETSTRUCT(vardata.statsTuple))->stanullfrac;
			ReleaseVariableStats(vardata);
		}
	}

	return sort->null_frac;
}

/*
 * stream_holds_nulls
 *		Can the stream's index hold NULLs of the sort column?
 */
static bool
stream_holds_nulls(PlannerInfo *root, Index rti, SortColumn *sort,
				   IndexCandidate *stream)
{
	if (stream->holds_nulls < 0)
	{
		stream->holds_nulls = sort->notnull ? 0 : 1;
		if (stream->holds_nulls && stream->index->indpred != NIL)
		{
			NullTest   *test = makeNode(NullTest);

			test->arg = (Expr *) column_var(root, rti, sort->attno);
			test->nulltesttype = IS_NOT_NULL;
			test->argisrow = false;
			test->location = -1;
			if (predicate_implied_by(list_make1(test), stream->index->indpred,
									 false))
				stream->holds_nulls = 0;
		}
	}

	return stream->holds_nulls != 0;
}

/*
 * stream_holds_group
 *		Does the stream have entries of this value, or NULLs?  One descent,
 *		cached in the candidate; SnapshotAny, as the merge reads dead entries
 *		too.
 */
static bool
stream_holds_group(RangeTblEntry *rte, SortColumn *sort, IndexCandidate *stream,
				   Datum value, bool isnull)
{
	EqualityKeys keys;
	Relation	heap;
	Relation	index;
	IndexScanDesc scan;
	ItemPointerData tid;
	int64		entries = 0;
	GroupProbe *probe;
	Datum		found;
	bool		found_null;
	ListCell   *lc;

	foreach(lc, stream->group_probes)
	{
		probe = (GroupProbe *) lfirst(lc);
		if (probe->isnull == isnull &&
			(isnull || range_compare(sort, probe->value, value) == 0))
			return probe->present;
	}

	if (!candidate_const_keys(sort, stream, &keys))
		return true;

	heap = table_open(rte->relid, NoLock);
	index = index_open(stream->index->indexoid, NoLock);
	lf_trace.range_scans++;
	scan = lf_index_beginscan(heap, index, SnapshotAny, keys.nequal + 1);
	scan->xs_want_itup = true;
	lf_rescan_with_keys(scan, &keys, isnull ? SORT_BOUND_NULL : SORT_BOUND_VALUE,
						value);

	probe = palloc(sizeof(GroupProbe));
	probe->value = value;
	probe->isnull = isnull;
	probe->present = lf_read_index_entry(scan, stream->backward ?
										 BackwardScanDirection :
										 ForwardScanDirection,
										 stream->sortpos + 1, false, &found,
										 &found_null, &tid, &entries, NULL);
	if (probe->present && !isnull)
		probe->present = !found_null &&
			range_compare(sort, found, value) == 0;
	stream->group_probes = lappend(stream->group_probes, probe);

	index_endscan(scan);
	index_close(index, NoLock);
	table_close(heap, NoLock);

	return probe->present;
}

/*
 * streams_hold_group
 *		Does every stream hold the group?  The merge passes it otherwise.
 *		Assumed without a probe.
 */
static bool
streams_hold_group(SortColumn *sort, StreamOverlap *overlap, Datum value,
				   bool isnull)
{
	if (!overlap->probed)
		return true;

	for (int i = 0; i < overlap->nstreams; i++)
	{
		if (!stream_holds_group(overlap->rte, sort, overlap->streams[i], value,
								isnull))
			return false;
	}

	return true;
}

/*
 * average_group_share
 *		Table share of a value outside the most common ones.
 */
static double
average_group_share(PlannerInfo *root, Index rti, SortColumn *sort,
					SortStats *stats, double ndistinct)
{
	double		rest = 1.0 - stats->mcv_total -
		sortcol_null_frac(root, rti, sort);

	if (rest > 0 && ndistinct > stats->nmcv)
		return rest / (ndistinct - stats->nmcv);

	return 1.0 / Max(ndistinct, 1.0);
}

/*
 * first_group_share
 *		Table share of the largest group read before the rows wanted, which
 *		lie within ahead_limit of the table from the end the merge starts at.
 *		Without a probe the overlap is the whole column.
 */
static double
first_group_share(PlannerInfo *root, Index rti, SortColumn *sort,
				  StreamOverlap *overlap, double ndistinct, double ahead_limit)
{
	SortStats  *stats;
	double		ahead = 0.0;
	double		edge_pos = 0.0;
	double		share = 0.0;
	int			bin;

	/* the group of the NULLs is at the start, or all there is to meet in */
	if ((sort->nulls_first || overlap->empty) && overlap->null_frac > 0 &&
		streams_hold_group(sort, overlap, (Datum) 0, true))
		share = overlap->null_frac;
	if (sort->nulls_first)
		ahead = share;
	if (ahead > ahead_limit || overlap->empty)
		return share;

	stats = sort_stats(root, rti, sort);
	share = Max(share, average_group_share(root, rti, sort, stats, ndistinct));

	if (stats->usable)
	{
		if (overlap->probed)
			edge_pos = histogram_position(sort, stats,
										  sort->descending ? overlap->hi :
										  overlap->lo, &bin);
		else
			edge_pos = sort->descending ? 1.0 : 0.0;
	}

	for (int k = 0; k < stats->nmcv; k++)
	{
		int			i = stats->mcv_order[sort->descending ?
										 stats->nmcv - 1 - k : k];
		double		hist_ahead = 0.0;

		if (overlap->probed)
		{
			int			to_lo = range_compare(sort, stats->mcv[i], overlap->lo);
			int			to_hi = range_compare(sort, stats->mcv[i], overlap->hi);

			if (sort->descending ? to_hi > 0 : to_lo < 0)
				continue;		/* not reached yet */
			if (sort->descending ? to_lo < 0 : to_hi > 0)
				break;			/* past the overlap */
		}
		if (stats->usable)
			hist_ahead = stats->hist_frac *
				fabs(histogram_position(sort, stats, stats->mcv[i], &bin) -
					 edge_pos);
		if (ahead + hist_ahead > ahead_limit)
			break;
		if (stats->mcv_freq[i] > share &&
			streams_hold_group(sort, overlap, stats->mcv[i], false))
			share = stats->mcv_freq[i];
		ahead += stats->mcv_freq[i];
	}

	return share;
}

/*
 * group_part
 *		Part of a stream's entries in a group with this table share, within the
 *		stream's own range.
 */
static double
group_part(PlannerInfo *root, Index rti, SortColumn *sort,
		   IndexCandidate *stream, StreamOverlap *overlap, double share)
{
	double		held = 1.0;

	if (overlap->probed)
	{
		held = stream->range_sel;
		if (stream_holds_nulls(root, rti, sort, stream))
			held += sortcol_null_frac(root, rti, sort);
		if (held <= 0)
			return 0.0;
	}

	return Min(share / held, 1.0);
}

/*
 * inner_group_limit
 *		Entries of one group that fit in a stream's share of work_mem.
 */
static double
inner_group_limit(int nstreams)
{
	return work_mem * 1024.0 / sizeof(ItemPointerData) / (nstreams - 1);
}

/*
 * first_group_cost
 *		What the inner streams pay for that group before the rows wanted:
 *		reading it, and sorting it unless it overflows work_mem.
 */
static Cost
first_group_cost(PlannerInfo *root, Index rti, SortColumn *sort,
				 IndexCandidate **streams, int nstreams, StreamOverlap *overlap,
				 double ndistinct, double matches, double loop_count)
{
	double		wanted = 1.0;
	double		group_limit = inner_group_limit(nstreams);
	double		share;
	Cost		cost = 0;

	if (root->limit_tuples >= 1.0 &&
		bms_membership(root->all_baserels) == BMS_SINGLETON)
		wanted = root->limit_tuples;

	share = first_group_share(root, rti, sort, overlap, ndistinct,
							  overlap->table_share * wanted / (matches + 1));
	if (share <= 0)
		return 0;

	for (int i = 1; i < nstreams; i++)
	{
		double		part = group_part(root, rti, sort, streams[i], overlap,
									  share);
		double		group = part * streams[i]->entries;

		cost += part * index_read_cost(root, streams[i]->index,
									   streams[i]->entries, loop_count);
		if (group <= group_limit)
			cost += group_cost(0, group, group);
	}

	return cost;
}

/*
 * groups_cost
 *		Grouping cost of all values: NULLs and common values inside the overlap
 *		at their own size, the rest at the average.  *overflow_rows gets the
 *		outer entries of groups over work_mem, checked on the heap instead.
 */
static Cost
groups_cost(PlannerInfo *root, Index rti, SortColumn *sort,
			IndexCandidate **streams, int nstreams, StreamOverlap *overlap,
			double *reads, double ndistinct, double *overflow_rows)
{
	SortStats  *stats = sort_stats(root, rti, sort);
	double		group_limit = inner_group_limit(nstreams);
	double		average = average_group_share(root, rti, sort, stats, ndistinct);
	double		rest_outer[INTERSECT_MAX_STREAMS];
	double		rest_inner[INTERSECT_MAX_STREAMS];
	Cost		cost = 0;

	*overflow_rows = 0;
	for (int i = 1; i < nstreams; i++)
	{
		rest_outer[i] = reads[0];
		rest_inner[i] = reads[i];
	}

	for (int k = -1; k < stats->nmcv; k++)
	{
		bool		isnull = (k < 0);
		Datum		value = isnull ? (Datum) 0 : stats->mcv[k];
		double		share = isnull ? overlap->null_frac : stats->mcv_freq[k];
		double		outer;
		bool		overflow = false;

		if (share <= 0 || (!isnull && overlap->empty))
			continue;
		if (!isnull && overlap->probed &&
			(range_compare(sort, value, overlap->lo) < 0 ||
			 range_compare(sort, value, overlap->hi) > 0))
			continue;

		outer = group_part(root, rti, sort, streams[0], overlap, share) *
			streams[0]->entries;
		for (int i = 1; i < nstreams; i++)
		{
			double		inner = group_part(root, rti, sort, streams[i], overlap,
										   share) * streams[i]->entries;

			rest_outer[i] -= outer;
			rest_inner[i] -= inner;
			if (inner > group_limit)
				overflow = true;
			else
				cost += group_cost(outer, inner, inner);
		}
		if (overflow && streams_hold_group(sort, overlap, value, isnull))
			*overflow_rows += outer;
	}

	for (int i = 1; i < nstreams; i++)
	{
		double		size = group_part(root, rti, sort, streams[i], overlap,
									  average) * streams[i]->entries;

		cost += group_cost(Max(rest_outer[i], 0.0), Max(rest_inner[i], 0.0),
						   Max(size, 1.0));
	}

	return cost;
}

/*
 * stream_overlap
 *		Where the streams can meet: the merge reads only the entries inside
 *		the overlap of their sortcol ranges, and matches can only lie there.
 *		Sets the share of each stream's entries inside the overlap, and the
 *		factor that turns a row estimate with the conditions independent over
 *		the whole table into one where they are independent inside the overlap:
 *
 *			rows' = rows * prod(share_i) / table_share^(nstreams - 1)
 *
 *		A stream is assumed to follow the table's distribution of sortcol
 *		within its own range.  All are 1 when a range cannot be probed; an
 *		empty overlap gives 0.  The range holds values only: the NULLs of a
 *		nullable column form one more group, whose share counts in the streams
 *		that hold them and, when every stream does, in the table's.
 */
static void
stream_overlap(PlannerInfo *root, RangeTblEntry *rte, Index rti,
			   SortColumn *sort, IndexCandidate **streams, int nstreams,
			   double *shares, double *rows_factor, StreamOverlap *overlap)
{
	Datum		lo = (Datum) 0;
	Datum		hi = (Datum) 0;
	bool		empty = false;
	double		null_frac = sortcol_null_frac(root, rti, sort);
	Selectivity table_share;

	for (int i = 0; i < nstreams; i++)
		shares[i] = 1.0;
	*rows_factor = 1.0;

	overlap->rte = rte;
	overlap->streams = streams;
	overlap->nstreams = nstreams;
	overlap->probed = false;
	overlap->empty = false;
	overlap->lo = (Datum) 0;
	overlap->hi = (Datum) 0;
	overlap->table_share = 1.0;
	overlap->null_frac = null_frac;
	for (int i = 0; i < nstreams; i++)
	{
		if (!stream_holds_nulls(root, rti, sort, streams[i]))
			overlap->null_frac = 0.0;
	}

	for (int i = 0; i < nstreams; i++)
	{
		if (!probe_range(rte, sort, streams[i]))
			return;
	}
	overlap->probed = true;

	for (int i = 0; i < nstreams && !empty; i++)
	{
		if (streams[i]->range_empty)
			empty = true;
		else if (i == 0)
		{
			lo = streams[i]->range_lo;
			hi = streams[i]->range_hi;
		}
		else
		{
			if (range_compare(sort, streams[i]->range_lo, lo) > 0)
				lo = streams[i]->range_lo;
			if (range_compare(sort, streams[i]->range_hi, hi) < 0)
				hi = streams[i]->range_hi;
		}
	}
	empty = empty || range_compare(sort, lo, hi) > 0;
	overlap->empty = empty;
	overlap->lo = lo;
	overlap->hi = hi;
	if (empty && overlap->null_frac <= 0)
	{
		for (int i = 0; i < nstreams; i++)
			shares[i] = 0.0;
		*rows_factor = 0.0;
		overlap->table_share = 0.0;
		return;
	}

	/*
	 * The share of each stream's own range is computed once per candidate;
	 * the overlap is usually the range of the narrowest stream.
	 */
	table_share = empty ? 0.0 : -1.0;
	for (int i = 0; i < nstreams; i++)
	{
		IndexCandidate *stream = streams[i];

		if (stream->range_empty)
		{
			stream->range_sel = 0.0;
			continue;
		}
		if (stream->range_sel < 0)
			stream->range_sel = sortcol_range_share(root, rti, sort,
													stream->range_lo,
													stream->range_hi);
		if (!empty && range_compare(sort, stream->range_lo, lo) == 0 &&
			range_compare(sort, stream->range_hi, hi) == 0)
			table_share = stream->range_sel;
	}
	if (table_share < 0)
		table_share = sortcol_range_share(root, rti, sort, lo, hi);
	table_share += overlap->null_frac;
	overlap->table_share = table_share;

	for (int i = 0; i < nstreams; i++)
	{
		Selectivity sel = streams[i]->range_sel;

		if (stream_holds_nulls(root, rti, sort, streams[i]))
			sel += null_frac;
		if (sel > 0)
			shares[i] = Min(table_share / sel, 1.0);
		if (table_share > 0)
			*rows_factor *= shares[i] / (i > 0 ? table_share : 1.0);
	}
}

/*
 * add_predicates
 *		The clauses with the predicates of a partial index added, as
 *		RestrictInfos, which extended statistics require.  A predicate the
 *		clauses imply is left out, as in btcostestimate's
 *		add_predicate_to_index_quals: kind = 2 would otherwise count twice for an
 *		equality kind = 2 and a predicate kind = 2.
 */
static List *
add_predicates(PlannerInfo *root, List *clauses, List *indpred)
{
	ListCell   *lc;

	clauses = list_copy(clauses);
	foreach(lc, indpred)
	{
		Expr	   *pred = (Expr *) lfirst(lc);

		if (!predicate_implied_by(list_make1(pred), clauses, false))
			clauses = lappend(clauses, make_simple_restrictinfo(root, pred));
	}

	return clauses;
}

/*
 * lf_index_entries
 *		Entries of an index matching the equalities on its leading columns.
 *		A partial index holds index->tuples entries to begin with.
 */
double
lf_index_entries(PlannerInfo *root, Index rti, IndexCandidate *candidate)
{
	RelOptInfo *rel = root->simple_rel_array[rti];
	double		entries = candidate->index->tuples;

	if (candidate->clauses == NIL)
		return clamp_row_est(entries);

	if (rel->statlist != NIL && candidate->index->indpred != NIL)
	{
		/* the equalities and the predicate may be correlated */
		List	   *clauses = add_predicates(root, candidate->clauses,
											 candidate->index->indpred);

		entries = Min(entries,
					  rel->tuples * clauselist_selectivity(root, clauses, rti,
														   JOIN_INNER, NULL));
	}
	else
		entries *= clauselist_selectivity(root, candidate->clauses, rti,
										  JOIN_INNER, NULL);

	return clamp_row_est(entries);
}

/*
 * stream_rows
 *		Rows that satisfy what the streams enforce: their equalities and the
 *		predicates of partial indexes.  The node fetches these from the heap.
 */
static double
stream_rows(PlannerInfo *root, RelOptInfo *rel, Index rti,
			IndexCandidate **streams, int nstreams)
{
	List	   *clauses = NIL;

	/* two streams on the same column share the clause: count it once */
	for (int i = 0; i < nstreams; i++)
		clauses = list_concat_unique_ptr(clauses, streams[i]->clauses);

	for (int i = 0; i < nstreams; i++)
		clauses = add_predicates(root, clauses, streams[i]->index->indpred);

	return clamp_row_est(rel->tuples *
						 clauselist_selectivity(root, clauses, rti,
												JOIN_INNER, NULL));
}

/*
 * lf_cost_intersect_path
 *		Set the rows, startup and total cost of a path whose parameterization
 *		is set and whose rows hold the planner's estimate for the relation, as
 *		cost_index does.  streams[0] is the outer index; every candidate has
 *		its entries set.  ndistinct is lf_sortcol_ndistinct, correlation
 *		lf_outer_index_correlation of the outer index.  Returns the entries
 *		each stream is expected to read in reads[] (EXPLAIN VERBOSE), its turn
 *		in the merge in ranks[], and in *fetch_cost what the rows fetched from
 *		the heap cost: all a further stream can save.
 */
void
lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
					   RangeTblEntry *rte, SortColumn *sort,
					   IndexCandidate **streams, int nstreams,
					   double ndistinct, double correlation, double *reads,
					   int *ranks, Cost *fetch_cost)
{
	RelOptInfo *rel = cpath->path.parent;
	ParamPathInfo *param_info = cpath->path.param_info;
	double		rows = cpath->path.rows;
	double		shares[INTERSECT_MAX_STREAMS];
	double		rows_factor;
	StreamOverlap overlap;
	Cost		first_group;
	double		loop_count;
	double		fetched;
	double		overflow_rows;
	double		heap_rows;
	double		matches;
	double		pages_scanned = 0;
	QualCost	qpqual_cost;
	Cost		run_cost;
	Cost		first_match;
	Cost		startup_cost;

	loop_count = loop_count_for(root, PATH_REQ_OUTER(&cpath->path));
	node_qual_cost(root, rel, param_info, streams, nstreams, &qpqual_cost);

	/*
	 * Only the entries inside the overlap of the streams' sortcol ranges are
	 * read, and the matches lie there (stream_overlap); a stream that starts
	 * outside it skips in with one more descent.
	 */
	stream_overlap(root, rte, rel->relid, sort, streams, nstreams, shares,
				   &rows_factor, &overlap);
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

	first_group = first_group_cost(root, rel->relid, sort, streams, nstreams,
								   &overlap, ndistinct, matches, loop_count);

	/*
	 * The heap fetches, and the outer entries of a group that overflows
	 * work_mem, are charged as for an Index Scan on the outer index (see
	 * lf_outer_index_correlation).
	 */
	run_cost = merge_read_cost(root, streams, nstreams, reads, ranks,
							   rel->tuples, loop_count);
	run_cost += groups_cost(root, rel->relid, sort, streams, nstreams, &overlap,
							reads, ndistinct, &overflow_rows);
	heap_rows = Min(fetched + overflow_rows, reads[0]);
	*fetch_cost = heap_fetch_cost(root, rel, heap_rows, loop_count, correlation,
								  pages_scanned) +
		heap_rows * (cpu_tuple_cost + qpqual_cost.per_tuple);
	run_cost += *fetch_cost + matches * rel->reltarget->cost.per_tuple;
	for (int i = 0; i < nstreams; i++)
	{
		if (shares[i] < 1.0)
			run_cost += descent_cost(streams[i]->index);
	}

	/*
	 * Every stream advances through run/(matches+1) of the merge before the
	 * first match: that share is startup, the rest is the run after it, and
	 * the total is the descents plus the whole merge.  No row comes before
	 * the inner streams have read the whole group of the first value, however
	 * few rows a Limit wants, and a value with most of the rows makes that
	 * more than the even share.
	 */
	first_match = Max(run_cost / (matches + 1), Min(first_group, run_cost));
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
