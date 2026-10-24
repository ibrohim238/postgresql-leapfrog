/*-------------------------------------------------------------------------
 *
 * executor.c
 *	  Executor side of the Index Merge Intersect custom scan: the merge of
 *	  the two index streams, TID groups, skip-ahead, the overflow fallback,
 *	  the EvalPlanQual recheck and EXPLAIN.
 *
 * IDENTIFICATION
 *	  src/executor.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "access/nbtree.h"
#include "access/relscan.h"
#include "commands/explain_format.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "utils/rel.h"

#include "leapfrog.h"

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

static Node *intersect_create_scan_state(CustomScan *cscan);
static void intersect_begin(CustomScanState *node, EState *estate,
							int eflags);
static TupleTableSlot *intersect_exec(CustomScanState *node);
static void intersect_end(CustomScanState *node);
static void intersect_rescan(CustomScanState *node);
static void intersect_explain(CustomScanState *node, List *ancestors,
							  ExplainState *es);

const CustomScanMethods lf_scan_methods = {
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

		keys->values[i] = lf_datum_get_int64(value, keys->types[i]);
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

	lf_rescan_with_keys(scan, keys, state->descending, bound);
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

	lf_rescan_with_keys(state->outer_scan, &state->outer_keys,
						state->descending, lf_no_bound(state->descending));
	lf_rescan_with_keys(state->inner_scan, &state->inner_keys,
						state->descending, lf_no_bound(state->descending));
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
	if (lf_read_index_entry(state->inner_scan, dir, state->inner_sortpos + 1,
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
			if (!lf_read_index_entry(state->outer_scan, dir,
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
		lf_rescan_with_keys(state->outer_scan, &state->outer_keys,
							state->descending, lf_no_bound(state->descending));
		lf_rescan_with_keys(state->inner_scan, &state->inner_keys,
							state->descending, lf_no_bound(state->descending));
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

	/* the cost model's expectation, to set against the counters below */
	if (es->verbose && es->costs)
	{
		List	   *private = ((CustomScan *) node->ss.ps.plan)->custom_private;

		ExplainPropertyFloat("Outer Entries Estimated", NULL,
							 DatumGetFloat8(private_datum(private,
														  PRIVATE_OUTER_ESTIMATE)),
							 0, es);
		ExplainPropertyFloat("Inner Entries Estimated", NULL,
							 DatumGetFloat8(private_datum(private,
														  PRIVATE_INNER_ESTIMATE)),
							 0, es);
	}

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
