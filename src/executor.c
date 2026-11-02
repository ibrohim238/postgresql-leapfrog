/*-------------------------------------------------------------------------
 *
 * executor.c
 *	  Executor side of the Index Merge Intersect custom scan: the merge of
 *	  the index streams, TID groups, skip-ahead, the overflow fallback, the
 *	  EvalPlanQual recheck and EXPLAIN.
 *
 * IDENTIFICATION
 *	  src/executor.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "access/relscan.h"
#include "access/stratnum.h"
#include "catalog/pg_attribute.h"
#include "commands/explain_format.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"

#include "leapfrog.h"

/*
 * Skip-ahead state of one stream.  A skip that lands on the leaf page it
 * left or on the next one in scan direction saved less than the descent
 * cost, and the stream's threshold doubles; a skip that lands further
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
 * One index of the intersection, read as a sorted stream of (sortcol value,
 * heap TID).  Stream 0 is the outer index: its matched entries are fetched
 * from the heap.  Every other stream is an inner one: the entries of the
 * current value are collected into a sorted TID group that the outer
 * entries are looked up in.
 */
typedef struct IndexStream
{
	Relation	index;
	IndexScanDesc scan;
	EqualityKeys keys;			/* equalities on the columns before sortcol */
	int			sort_attno;		/* sortcol's position in the index tuple */
	ScanDirection dir;			/* gives the query's order in this index */
	ExprState  *pred;			/* predicate of a partial inner index */
	bool		have;			/* current entry is not consumed yet */
	bool		eof;
	Datum		value;			/* points into the scan's index tuple */
	bool		isnull;
	bool		bounded;		/* a skip's bound keeps NULLs still ahead out */
	ItemPointerData tid;
	SkipAhead	skip;
	MemoryContext bound_cxt;	/* the bound of the last skip, which nbtree
								 * evaluates until the next rescan */

	/* TID group of the value being matched, sorted (inner streams) */
	bool		group_overflow; /* group exceeded its share of work_mem */
	ItemPointerData *group_tids;
	int			group_count;
	int			group_capacity;

	/* instrumentation, summed over all rescans */
	int64		read;
	int64		group_overflows;
	double		estimate;		/* entries the cost model expected */
} IndexStream;

/* How two values compare: inline for the comparators that are plain integers. */
typedef enum SortCompareKind
{
	SORT_COMPARE_GENERIC,
	SORT_COMPARE_INT64,
	SORT_COMPARE_INT32,
} SortCompareKind;

/*
 * Execution state of an Index Merge Intersect scan.
 */
typedef struct IntersectScanState
{
	CustomScanState css;
	int			nstreams;
	IndexStream *streams;
	bool		values_ready;	/* key values are evaluated */
	bool		values_null;	/* some equality value is NULL */
	MemoryContext values_cxt;	/* copies of the values, reset per rescan */
	bool		descending;
	bool		started;
	bool		done;
	bool		fetching_match; /* heap fetch of a matched entry in progress */
	bool		match_by_pred;	/* some inner group overflowed: check the row */
	bool		in_group;		/* groups of group_value are collected */
	Datum		group_value;	/* copied into group_cxt: the streams move on */
	bool		group_isnull;
	MemoryContext group_cxt;	/* reset when the next group starts */
	int			group_limit;	/* entries of one group that fit into work_mem */
	SortSupportData ssup;		/* compares values in query order */
	SortCompareKind compare_kind;	/* what compare_values does with them */
	int16		sort_typlen;
	bool		sort_typbyval;
	bool		sort_notnull;	/* NULL entries are dead: skip them */
	bool		nulls_ahead;	/* NULLs come after every value in the merge */

	/* instrumentation, summed over all rescans */
	int64		matched;		/* TIDs found in every stream */
	int64		pred_checked;	/* overflow entries checked by predicate */
	int64		heap_fetches;
	int			peak_capacity;	/* largest total of the group arrays */
	int64		skips;			/* re-descents of a lagging scan */
	int64		short_skips;	/* skips that landed on the next leaf page */
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
 *		Prepare the equality value expressions of one stream; the i-th
 *		expression is compared with the i-th key column of the index.
 */
static void
init_equality_keys(EqualityKeys *keys, List *exprs, List *operators,
				   List *collations, Relation index, Oid sort_type,
				   Oid sort_opfamily, Oid sort_collation, bool descending,
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
		keys->operators[i] = list_nth_oid(operators, i);
		keys->collations[i] = list_nth_oid(collations, i);
		fmgr_info(get_opcode(keys->operators[i]), &keys->eqfns[i]);
		i++;
	}
	keys->nequal = i;
	lf_init_key_procs(keys, sort_type, sort_opfamily, sort_collation,
					  descending);
}

static Datum
private_datum(List *private, int pos)
{
	return list_nth_node(Const, private, pos)->constvalue;
}

static Datum
stream_datum(List *private, int stream, int pos)
{
	return private_datum(private,
						 PRIVATE_COUNT + stream * STREAM_PRIVATE_COUNT + pos);
}

static List *
stream_oids(List *private, int stream, int pos)
{
	List	   *oids = list_nth(private,
								PRIVATE_COUNT + stream * STREAM_PRIVATE_COUNT + pos);

	Assert(oids == NIL || IsA(oids, OidList));
	return oids;
}

static void
intersect_begin(CustomScanState *node, EState *estate, int eflags)
{
	IntersectScanState *state = (IntersectScanState *) node;
	CustomScan *cscan = (CustomScan *) node->ss.ps.plan;
	Relation	heap = node->ss.ss_currentRelation;
	List	   *private = cscan->custom_private;
	Oid			sort_type = DatumGetObjectId(private_datum(private,
														   PRIVATE_SORT_TYPE));
	Oid			sort_opfamily = DatumGetObjectId(private_datum(private,
															   PRIVATE_SORT_OPFAMILY));
	Oid			sort_collation = DatumGetObjectId(private_datum(private,
																PRIVATE_SORT_COLLATION));

	state->descending =
		DatumGetBool(private_datum(private, PRIVATE_DESCENDING));
	state->nstreams = DatumGetInt32(private_datum(private, PRIVATE_NSTREAMS));
	state->streams = palloc0(state->nstreams * sizeof(IndexStream));

	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];
		List	   *keys = list_nth_node(List, cscan->custom_exprs,
										 i * STREAM_EXPRS_COUNT + STREAM_EXPRS_KEYS);
		List	   *pred = list_nth_node(List, cscan->custom_exprs,
										 i * STREAM_EXPRS_COUNT + STREAM_EXPRS_PRED);

		stream->index =
			index_open(DatumGetObjectId(stream_datum(private, i,
													 STREAM_PRIVATE_INDEX)),
					   AccessShareLock);
		stream->sort_attno =
			DatumGetInt32(stream_datum(private, i, STREAM_PRIVATE_SORTPOS)) + 1;
		stream->dir =
			DatumGetBool(stream_datum(private, i, STREAM_PRIVATE_BACKWARD)) ?
			BackwardScanDirection : ForwardScanDirection;
		stream->estimate =
			DatumGetFloat8(stream_datum(private, i, STREAM_PRIVATE_ESTIMATE));
		init_equality_keys(&stream->keys, keys,
						   stream_oids(private, i, STREAM_PRIVATE_OPERATORS),
						   stream_oids(private, i, STREAM_PRIVATE_COLLATIONS),
						   stream->index, sort_type, sort_opfamily,
						   sort_collation, state->descending, &node->ss.ps);
		stream->pred = ExecInitQual(pred, &node->ss.ps);
	}
	state->values_cxt = AllocSetContextCreate(CurrentMemoryContext,
											  "leapfrog equality values",
											  ALLOCSET_SMALL_SIZES);

	if (eflags & EXEC_FLAG_EXPLAIN_ONLY)
		return;

	state->ssup.ssup_cxt = CurrentMemoryContext;
	state->ssup.ssup_collation = sort_collation;
	state->ssup.ssup_nulls_first = DatumGetBool(private_datum(private,
															  PRIVATE_SORT_NULLS_FIRST));
	state->sort_notnull = DatumGetBool(private_datum(private,
													 PRIVATE_SORT_NOTNULL));
	state->nulls_ahead = !state->sort_notnull && !state->ssup.ssup_nulls_first;
	PrepareSortSupportFromOrderingOp(get_opfamily_member(sort_opfamily, sort_type,
														 sort_type,
														 state->descending ?
														 BTGreaterStrategyNumber :
														 BTLessStrategyNumber),
									 &state->ssup);
	state->compare_kind = SORT_COMPARE_GENERIC;
#if PG_VERSION_NUM >= 190000 || SIZEOF_DATUM >= 8
	if (state->ssup.comparator == ssup_datum_signed_cmp)
		state->compare_kind = SORT_COMPARE_INT64;
#endif
	if (state->ssup.comparator == ssup_datum_int32_cmp)
		state->compare_kind = SORT_COMPARE_INT32;
	{
		Form_pg_attribute attr =
			TupleDescAttr(RelationGetDescr(state->streams[0].index),
						  state->streams[0].sort_attno - 1);

		state->sort_typlen = attr->attlen;
		state->sort_typbyval = attr->attbyval;
	}
	state->group_cxt = AllocSetContextCreate(CurrentMemoryContext,
											 "leapfrog group value",
											 ALLOCSET_SMALL_SIZES);

	/* the group arrays together never grow past the work_mem budget */
	state->group_limit = (int) Min((double) INT_MAX / 2,
								   work_mem * 1024.0 / sizeof(ItemPointerData) /
								   (state->nstreams - 1));
	state->peak_capacity = 0;

	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];

		/* the equality keys plus the bound on sortcol used for skipping ahead */
		stream->scan = lf_index_beginscan(heap, stream->index,
										  estate->es_snapshot,
										  stream->keys.nequal + 1);
		stream->scan->xs_want_itup = true;
		stream->bound_cxt = AllocSetContextCreate(CurrentMemoryContext,
												  "leapfrog skip bound",
												  ALLOCSET_SMALL_SIZES);
		if (i > 0)
		{
			stream->group_capacity = Max(1, Min(16, state->group_limit));
			stream->group_tids = palloc(stream->group_capacity *
										sizeof(ItemPointerData));
			state->peak_capacity += stream->group_capacity;
		}
	}

	intersect_rescan(node);
}

/*
 * evaluate_keys
 *		Evaluate the equality values of one stream.  Returns false when a
 *		value is NULL.
 */
static bool
evaluate_keys(EqualityKeys *keys, ExprContext *econtext, MemoryContext cxt)
{
	for (int i = 0; i < keys->nequal; i++)
	{
		Datum		value;
		bool		isnull;
		int16		typlen;
		bool		typbyval;
		MemoryContext oldcxt;

		value = ExecEvalExprSwitchContext(keys->exprs[i], econtext, &isnull);
		if (isnull)
			return false;

		/*
		 * The value lives in the per-tuple memory the next row resets; a text
		 * or uuid key must outlast the scan positioned on it.
		 */
		get_typlenbyval(keys->types[i], &typlen, &typbyval);
		oldcxt = MemoryContextSwitchTo(cxt);
		keys->values[i] = datumCopy(value, typbyval, typlen);
		MemoryContextSwitchTo(oldcxt);
	}

	return true;
}

/*
 * evaluate_equal_values
 *		Evaluate the equality values of every stream once per (re)scan.
 *		Also used by the EvalPlanQual recheck, which runs on a planstate
 *		copy whose scan was never started.  Returns false when a value is
 *		NULL.
 */
static bool
evaluate_equal_values(IntersectScanState *state)
{
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;

	if (state->values_ready)
		return !state->values_null;

	state->values_ready = true;
	state->values_null = false;
	MemoryContextReset(state->values_cxt);
	for (int i = 0; i < state->nstreams; i++)
	{
		if (!evaluate_keys(&state->streams[i].keys, econtext,
						   state->values_cxt))
			state->values_null = true;
	}

	return !state->values_null;
}

/*
 * compare_values
 *		Compare two values of the merge in query order: above zero when a is
 *		further along than b.  bigint, timestamptz and the like compare as
 *		plain integers, inline: on a merge of bigint values the indirect call
 *		costs about a tenth of the node's time (BENCHMARKS.md).
 */
static inline int
compare_values(IntersectScanState *state, Datum a, bool a_isnull, Datum b,
			   bool b_isnull)
{
	SortSupport ssup = &state->ssup;
	int			compare;

	if (a_isnull || b_isnull)
	{
		if (a_isnull && b_isnull)
			return 0;
		return (a_isnull == ssup->ssup_nulls_first) ? -1 : 1;
	}

	switch (state->compare_kind)
	{
		case SORT_COMPARE_INT64:
			compare = (DatumGetInt64(a) > DatumGetInt64(b)) -
				(DatumGetInt64(a) < DatumGetInt64(b));
			break;
		case SORT_COMPARE_INT32:
			compare = (DatumGetInt32(a) > DatumGetInt32(b)) -
				(DatumGetInt32(a) < DatumGetInt32(b));
			break;
		default:
			compare = ssup->comparator(a, b, ssup);
			break;
	}
	if (ssup->ssup_reverse)
		INVERT_COMPARE_RESULT(compare);

	return compare;
}

/*
 * init_skip
 *		Start a stream's skip-ahead at leapfrog.skip_after; 0 never skips.
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
 *		Re-position a lagging stream on the frontmost value, remembering the
 *		leaf page it leaves so that check_landing can tell how far it went.
 *		A bound on a value excludes NULLs, which read_stream_entry goes back
 *		for when they come later in the merge; a NULL bound is the last group.
 */
static void
skip_ahead(IntersectScanState *state, IndexStream *stream, Datum bound,
		   bool bound_isnull)
{
	MemoryContext oldcxt;

	SkipAhead  *skip = &stream->skip;

	skip->landing = lf_scan_leaf_position(stream->scan,
										  ScanDirectionIsBackward(stream->dir),
										  &skip->from_page, &skip->from_next);

	/* bound belongs to another stream, which will move on */
	MemoryContextReset(stream->bound_cxt);
	if (bound_isnull)
	{
		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NULL,
							(Datum) 0);
		stream->bounded = false;
	}
	else
	{
		oldcxt = MemoryContextSwitchTo(stream->bound_cxt);
		bound = datumCopy(bound, state->sort_typbyval, state->sort_typlen);
		MemoryContextSwitchTo(oldcxt);
		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_VALUE, bound);
		stream->bounded = state->nulls_ahead;
	}
	skip->behind = 0;
	state->skips++;
}

/*
 * check_landing
 *		After the first entry read since a skip: a skip that stayed on the
 *		leaf page it left or moved to the next one did not pay for its
 *		descent, so the stream waits twice as long before the next one; a
 *		longer skip halves the wait, down to leapfrog.skip_after.  The
 *		threshold stays within 64 times leapfrog.skip_after.
 */
static void
check_landing(IntersectScanState *state, IndexStream *stream)
{
	SkipAhead  *skip = &stream->skip;
	BlockNumber page;
	BlockNumber next_page;

	if (!skip->landing)
		return;
	skip->landing = false;

	(void) lf_scan_leaf_position(stream->scan,
								 ScanDirectionIsBackward(stream->dir), &page,
								 &next_page);
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
 *		Evaluate the equality values and position every index scan.
 *		Returns false when a value is NULL: nothing can match then.
 */
static bool
intersect_start(IntersectScanState *state)
{
	if (!evaluate_equal_values(state))
		return false;

	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];

		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NONE,
							(Datum) 0);
		stream->bounded = false;
		init_skip(&stream->skip);
	}

	return true;
}

/*
 * row_matches_keys
 *		Do the heap row's columns equal the current values of one stream?
 */
static bool
row_matches_keys(TupleTableSlot *slot, EqualityKeys *keys)
{
	for (int i = 0; i < keys->nequal; i++)
	{
		bool		isnull;
		Datum		value;

		value = slot_getattr(slot, keys->attnos[i], &isnull);
		if (isnull ||
			!DatumGetBool(FunctionCall2Coll(&keys->eqfns[i],
											keys->collations[i], value,
											keys->values[i])))
			return false;
	}

	return true;
}

/*
 * row_matches_stream
 *		Would the stream's index hold an entry for this row version: does it
 *		satisfy the stream's equalities and, for a partial index, its
 *		predicate?  Used where the row was not matched against the index by
 *		TID.
 */
static bool
row_matches_stream(IntersectScanState *state, IndexStream *stream,
				   TupleTableSlot *slot)
{
	ExprContext *econtext = state->css.ss.ps.ps_ExprContext;

	if (!row_matches_keys(slot, &stream->keys))
		return false;

	econtext->ecxt_scantuple = slot;

	return ExecQualAndReset(stream->pred, econtext);
}

static int
tid_compare(const void *a, const void *b)
{
	return ItemPointerCompare((ItemPointer) a, (ItemPointer) b);
}

/*
 * read_stream_entry
 *		Advance a stream by one entry; remembers when it is exhausted.  A
 *		stream that ran out under a skip's bound has not seen the NULLs after
 *		the values yet.
 */
static void
read_stream_entry(IntersectScanState *state, IndexStream *stream)
{
	for (;;)
	{
		if (lf_read_index_entry(stream->scan, stream->dir, stream->sort_attno,
								state->sort_notnull, &stream->value,
								&stream->isnull, &stream->tid, &stream->read))
		{
			stream->have = true;
			check_landing(state, stream);
			return;
		}
		if (!stream->bounded)
			break;
		stream->bounded = false;
		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NULL,
							(Datum) 0);
	}
	stream->eof = true;
}

/*
 * collect_group
 *		Gather the TIDs of all entries of an inner stream whose value equals
 *		the current one, leaving the first entry of the next value pending.
 *
 * A group larger than its share of work_mem is not kept: the remaining
 * entries of the value are skipped, and every outer entry of the value is
 * treated as a match for the stream's conditions to be checked on the row.
 */
static void
collect_group(IntersectScanState *state, IndexStream *stream)
{
	uint32		iterations = 0;

	stream->group_overflow = false;
	stream->group_count = 0;

	while (stream->have &&
		   compare_values(state, stream->value, stream->isnull,
						  state->group_value, state->group_isnull) == 0)
	{
		if ((++iterations & 1023) == 0)
			CHECK_FOR_INTERRUPTS();

		if (stream->group_overflow)
			;					/* skip the rest of the value */
		else if (stream->group_count == state->group_limit)
		{
			stream->group_overflow = true;
			stream->group_overflows++;
		}
		else
		{
			if (stream->group_count == stream->group_capacity)
			{
				state->peak_capacity -= stream->group_capacity;
				stream->group_capacity = Min(stream->group_capacity * 2,
											 state->group_limit);
				stream->group_tids = repalloc(stream->group_tids,
											  stream->group_capacity *
											  sizeof(ItemPointerData));
				state->peak_capacity += stream->group_capacity;
			}
			stream->group_tids[stream->group_count++] = stream->tid;
		}

		stream->have = false;
		read_stream_entry(state, stream);
	}

	if (stream->group_overflow)
		stream->group_count = 0;
	else if (stream->group_count > 1)
		qsort(stream->group_tids, stream->group_count, sizeof(ItemPointerData),
			  tid_compare);
}

static bool
group_contains(IndexStream *stream, ItemPointer tid)
{
	if (stream->group_overflow)
		return true;

	return bsearch(tid, stream->group_tids, stream->group_count,
				   sizeof(ItemPointerData), tid_compare) != NULL;
}

/*
 * intersect_next
 *		Merge the sorted index streams, the counterpart of MySQL's
 *		RowIDIntersectionIterator::DoRead: advance the lagging streams until
 *		every value meets, then match the entries of that value by TID.
 */
static TupleTableSlot *
intersect_next(ScanState *ss)
{
	IntersectScanState *state = (IntersectScanState *) ss;
	TupleTableSlot *slot = ss->ss_ScanTupleSlot;
	IndexStream *outer = &state->streams[0];
	uint32		iterations = 0;

	if (!state->started)
	{
		state->started = true;
		if (!intersect_start(state))
			state->done = true;
	}

	while (!state->done)
	{
		Datum		front;
		bool		front_isnull;
		bool		all_equal;
		bool		pending;
		bool		exhausted = false;

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
			bool		found = index_fetch_heap(outer->scan, slot);

			state->heap_fetches++;
			state->fetching_match = outer->scan->xs_heap_continue;
			if (!found)
				continue;

			/*
			 * An entry of an overflowed group was not matched against that
			 * inner index: check the index's conditions on the row itself.
			 */
			if (state->match_by_pred)
			{
				bool		matches = true;

				for (int i = 1; i < state->nstreams && matches; i++)
				{
					IndexStream *stream = &state->streams[i];

					if (stream->group_overflow &&
						!row_matches_stream(state, stream, slot))
						matches = false;
				}
				if (!matches)
					continue;
			}

			return slot;
		}

		if (!outer->have)
		{
			read_stream_entry(state, outer);
			if (outer->eof)
				break;
		}

		/* the outer entries of the collected value are looked up by TID */
		if (state->in_group)
		{
			bool		found = true;
			bool		by_pred = false;

			if (compare_values(state, outer->value, outer->isnull,
							   state->group_value, state->group_isnull) != 0)
			{
				state->in_group = false;
				continue;
			}

			outer->have = false;
			for (int i = 1; i < state->nstreams && found; i++)
			{
				IndexStream *stream = &state->streams[i];

				found = group_contains(stream, &outer->tid);
				by_pred |= stream->group_overflow;
			}
			if (found)
			{
				if (by_pred)
					state->pred_checked++;
				else
					state->matched++;
				state->fetching_match = true;
				state->match_by_pred = by_pred;
			}

			continue;
		}

		/* every inner stream needs a current entry */
		pending = false;
		for (int i = 1; i < state->nstreams && !pending; i++)
		{
			IndexStream *stream = &state->streams[i];

			if (!stream->have)
			{
				if (stream->eof)
					exhausted = true;
				else
					read_stream_entry(state, stream);
				pending = true;
			}
		}
		if (exhausted)
			break;
		if (pending)
			continue;

		/* the frontmost value in scan direction */
		front = outer->value;
		front_isnull = outer->isnull;
		all_equal = true;
		for (int i = 1; i < state->nstreams; i++)
		{
			int			cmp = compare_values(state, state->streams[i].value,
											 state->streams[i].isnull,
											 front, front_isnull);

			if (cmp != 0)
				all_equal = false;
			if (cmp > 0)
			{
				front = state->streams[i].value;
				front_isnull = state->streams[i].isnull;
			}
		}

		if (all_equal)
		{
			MemoryContext oldcxt;

			state->in_group = true;
			MemoryContextReset(state->group_cxt);
			oldcxt = MemoryContextSwitchTo(state->group_cxt);
			state->group_isnull = front_isnull;
			state->group_value = front_isnull ? (Datum) 0 :
				datumCopy(front, state->sort_typbyval, state->sort_typlen);
			MemoryContextSwitchTo(oldcxt);
			for (int i = 0; i < state->nstreams; i++)
				state->streams[i].skip.behind = 0;
			for (int i = 1; i < state->nstreams; i++)
				collect_group(state, &state->streams[i]);
			continue;
		}

		/*
		 * Advance every lagging stream by one entry, or, once it has read its
		 * threshold of entries in a row without catching up, descend its
		 * B-tree again straight to the frontmost value.  The entries in
		 * between cannot match: the frontmost stream has consumed every value
		 * before its current one.
		 */
		for (int i = 0; i < state->nstreams; i++)
		{
			IndexStream *stream = &state->streams[i];

			if (compare_values(state, stream->value, stream->isnull, front,
							   front_isnull) == 0)
			{
				stream->skip.behind = 0;
				continue;
			}
			stream->have = false;
			if (++stream->skip.behind >= stream->skip.threshold)
				skip_ahead(state, stream, front, front_isnull);
		}
	}

	/*
	 * The merge ends when one stream runs out, with the others still
	 * positioned on a leaf page.  The scans keep their leaf page pinned, as
	 * an Index Only Scan does, since the sort value is read from the index
	 * tuple (xs_want_itup); VACUUM of the index would wait for that pin as
	 * long as an exhausted cursor stays open.  Resetting the scans releases
	 * the pins; a rescan positions them again.
	 */
	if (!state->done)
	{
		for (int i = 0; i < state->nstreams; i++)
		{
			IndexStream *stream = &state->streams[i];

			lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NONE,
								(Datum) 0);
		}
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

	for (int i = 0; i < state->nstreams; i++)
	{
		if (!row_matches_stream(state, &state->streams[i], slot))
			return false;
	}

	return true;
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

	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];

		if (stream->scan)
			index_endscan(stream->scan);
		if (stream->index)
			index_close(stream->index, AccessShareLock);
		if (stream->group_tids)
			pfree(stream->group_tids);
	}
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
	state->fetching_match = false;
	state->match_by_pred = false;
	state->in_group = false;
	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];

		stream->have = false;
		stream->eof = false;
		stream->group_overflow = false;
		stream->group_count = 0;
	}
}

/*
 * stream_property
 *		Name of a per-stream EXPLAIN property: "Outer <name>" for the outer
 *		index, "Inner <name>" for the first inner one and "Inner <name> N"
 *		for the others, so that a two-index node prints what it always did.
 */
static const char *
stream_property(int stream, const char *name)
{
	if (stream == 0)
		return psprintf("Outer %s", name);
	if (stream == 1)
		return psprintf("Inner %s", name);
	return psprintf("Inner %s %d", name, stream);
}

static void
intersect_explain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	IntersectScanState *state = (IntersectScanState *) node;
	int64		group_overflows = 0;

	for (int i = 0; i < state->nstreams; i++)
		ExplainPropertyText(stream_property(i, "Index"),
							RelationGetRelationName(state->streams[i].index),
							es);

	/* the cost model's expectation, to set against the counters below */
	if (es->verbose && es->costs)
	{
		for (int i = 0; i < state->nstreams; i++)
			ExplainPropertyFloat(stream_property(i, "Entries Estimated"), NULL,
								 state->streams[i].estimate, 0, es);
	}

	/* summed over all rescans, like the executor's own counters */
	if (es->analyze)
	{
		for (int i = 0; i < state->nstreams; i++)
		{
			ExplainPropertyInteger(stream_property(i, "Entries Read"), NULL,
								   state->streams[i].read, es);
			group_overflows += state->streams[i].group_overflows;
		}
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
		if (group_overflows > 0)
		{
			ExplainPropertyInteger("Group Overflows", NULL, group_overflows,
								   es);
			ExplainPropertyInteger("Rows Checked by Predicate", NULL,
								   state->pred_checked, es);
		}
	}
}
