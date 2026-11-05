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
#include "catalog/pg_am_d.h"
#include "catalog/pg_attribute.h"
#include "commands/explain_format.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "rewrite/rewriteManip.h"
#include "storage/bufmgr.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/ruleutils.h"
#include "utils/snapmgr.h"
#include "utils/spccache.h"

#include "leapfrog.h"

/* The most matches gathered ahead of their heap fetches. */
#define HEAP_QUEUE_MAX 32
/* Entries passed without a match before fetching what is queued. */
#define HEAP_QUEUE_MAX_WALK 4096
/* What a skip counts for: its descent reads a few pages. */
#define HEAP_QUEUE_SKIP_WALK 256
/* Fetches to see before changing the target. */
#define HEAP_QUEUE_WINDOW 16

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
 * One index of the intersection.  Stream 0 is the outer index: its matched
 * entries are fetched from the heap.  Of an inner stream, the entries of the
 * current value are collected into a sorted TID group the outer entries are
 * looked up in.
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
	int64		skips;			/* re-descents of this scan */
	int64		short_skips;	/* skips that landed on the next leaf page */
	bool		started;		/* has read its first entry of this loop */
	StreamInstr instr;			/* descents and page steps, under ANALYZE */
	instr_time	startup;		/* of that time, until the first entry of each
								 * loop, summed */
	instr_time	loop_base;		/* instr.time when the loop started */
	double		estimate;		/* entries the cost model expected */
} IndexStream;

/* How two values compare: inline for the comparators that are plain integers. */
typedef enum SortCompareKind
{
	SORT_COMPARE_GENERIC,
	SORT_COMPARE_INT64,
	SORT_COMPARE_INT32,
} SortCompareKind;

typedef struct IntersectScanState
{
	CustomScanState css;
	int			nstreams;
	IndexStream *streams;
	IndexStream **merge_order;	/* the streams, sparsest first */
	bool		values_ready;	/* key values are evaluated */
	bool		values_null;	/* some equality value is NULL */
	MemoryContext values_cxt;	/* copies of the values, reset per rescan */
	bool		descending;
	bool		started;
	bool		done;
	bool		fetching_match; /* heap fetch of a matched entry in progress */
	bool		match_by_pred;	/* some inner group overflowed: check the row */

	/*
	 * Matches found ahead, whose heap pages were asked for; see
	 * heap_queue_add.  They are fetched in the order found.
	 */
	ItemPointerData heap_queue[HEAP_QUEUE_MAX];
	int			heap_queue_len;
	int			heap_queue_next;
	int			heap_queue_target;	/* matches to gather before fetching */
	int			heap_queue_limit;	/* its largest value */
	int			heap_queue_walked;	/* entries passed since the first match */
	bool		heap_queue_drain;	/* fetch what is queued, then go on */
	bool		merge_ended;	/* no more matches once the queue is empty */
	BlockNumber heap_prefetch_block;	/* the heap page asked for last */
	int64		rows_fetched;	/* heap fetches since the target's last change */
	int64		rows_emitted;	/* of those, rows that passed the Filter */
	int64		heap_prefetches;
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
} IntersectScanState;


/*
 * The node's instrumentation under EXPLAIN ANALYZE: PostgreSQL 19 wraps
 * Instrumentation in a NodeInstrumentation with the loop count.
 */
static inline bool
node_need_timer(PlanState *ps)
{
#if PG_VERSION_NUM >= 190000
	return ps->instrument != NULL && ps->instrument->instr.need_timer;
#else
	return ps->instrument != NULL && ps->instrument->need_timer;
#endif
}

static inline bool
node_need_bufusage(PlanState *ps)
{
#if PG_VERSION_NUM >= 190000
	return ps->instrument != NULL && ps->instrument->instr.need_bufusage;
#else
	return ps->instrument != NULL && ps->instrument->need_bufusage;
#endif
}

static inline double
node_nloops(PlanState *ps)
{
	return ps->instrument != NULL ? ps->instrument->nloops : 0;
}

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
	state->merge_order = palloc(state->nstreams * sizeof(IndexStream *));

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
		state->merge_order[DatumGetInt32(stream_datum(private, i,
													  STREAM_PRIVATE_RANK))] = stream;
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

	/*
	 * Asking for a TID's block as a page of the main fork takes a table whose
	 * TIDs are that: the heap, not any table access method.
	 */
	state->heap_queue_limit = 1;
	if (intersect_prefetch && node->ss.ps.qual != NULL &&
		IsMVCCSnapshot(estate->es_snapshot) &&
		node->ss.ss_currentRelation->rd_rel->relam == HEAP_TABLE_AM_OID)
		state->heap_queue_limit =
			Max(Min(get_tablespace_io_concurrency(node->ss.ss_currentRelation->rd_rel->reltablespace),
					HEAP_QUEUE_MAX), 1);

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
 *		Evaluate the equality values of every stream once per (re)scan; false
 *		when a value is NULL.  Also used by the EvalPlanQual recheck, which
 *		runs on a planstate copy whose scan was never started.
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
 *		plain integers, inline, to spare the indirect call (BENCHMARKS.md).
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
	StreamClock clock;

	SkipAhead  *skip = &stream->skip;

	lf_instr_start(&stream->instr, &clock);
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
	lf_instr_stop(&stream->instr, &clock);
	skip->behind = 0;
	stream->skips++;
}

/*
 * check_landing
 *		After the first entry read since a skip, adapt the stream's threshold
 *		(see SkipAhead), within 64 times leapfrog.skip_after.
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
		stream->short_skips++;
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
		StreamClock clock;

		/* allocated after BeginCustomScan: read here, before the first use */
		stream->instr.timer = node_need_timer(&state->css.ss.ps);
		stream->instr.bufusage = node_need_bufusage(&state->css.ss.ps);
		stream->loop_base = stream->instr.time;
		stream->started = false;
		lf_instr_start(&stream->instr, &clock);
		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NONE,
							(Datum) 0);
		lf_instr_stop(&stream->instr, &clock);
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
 *		Would the stream's index hold an entry for this row version?  For
 *		where the row was not matched against the index by TID.
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
		StreamClock clock;

		if (lf_read_index_entry(stream->scan, stream->dir, stream->sort_attno,
								state->sort_notnull, &stream->value,
								&stream->isnull, &stream->tid, &stream->read,
								&stream->instr))
		{
			if (!stream->started)
			{
				stream->started = true;
				INSTR_TIME_ACCUM_DIFF(stream->startup, stream->instr.time,
									  stream->loop_base);
			}
			stream->have = true;
			check_landing(state, stream);
			return;
		}
		if (!stream->bounded)
			break;
		stream->bounded = false;
		lf_instr_start(&stream->instr, &clock);
		lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NULL,
							(Datum) 0);
		lf_instr_stop(&stream->instr, &clock);
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
 * find_common_value
 *		Advance the streams until all of them stand on one value, and keep a
 *		copy of it as the group value.  Returns false when a stream runs out,
 *		or to fetch what is queued (heap_queue_drain) before going on from
 *		where every stream stands.
 *
 * One stream holds the candidate and the others catch up with it in turn.  A
 * stream that reaches it confirms it; one that passes it holds the new
 * candidate.  The candidate's stream does not move meanwhile, so its value
 * stays valid.  The turns start again from the sparsest stream after each new
 * candidate: a dense stream then has to reach only the values all the sparser
 * ones agree on, and skips the rest in one descent, where taking turns in a
 * circle makes it read nearly all of its entries.
 *
 * A stream that has read its threshold of entries without catching up descends
 * its B-tree straight to the candidate: the entries in between cannot match,
 * since the candidate's stream has consumed every value before its current one.
 */
static bool
find_common_value(IntersectScanState *state)
{
	IndexStream *candidate = state->merge_order[0];
	int			turn = 1;
	uint32		iterations = 0;
	MemoryContext oldcxt;

	if (!candidate->have)
	{
		if (!candidate->eof)
			read_stream_entry(state, candidate);
		if (candidate->eof)
			return false;
	}

	while (turn < state->nstreams)
	{
		IndexStream *stream = state->merge_order[turn];
		int			cmp;

		if (stream == candidate)
		{
			turn++;
			continue;
		}

		for (;;)
		{
			if (!stream->have)
			{
				if (!stream->eof)
					read_stream_entry(state, stream);
				if (stream->eof)
					return false;
			}

			cmp = compare_values(state, stream->value, stream->isnull,
								 candidate->value, candidate->isnull);
			if (cmp >= 0)
				break;

			/* long stretches without a match must stay interruptible */
			if ((++iterations & 1023) == 0)
				CHECK_FOR_INTERRUPTS();

			stream->have = false;

			/*
			 * Rows found already wait for the next match: fetch them before a
			 * long stretch, which a LIMIT may never need.
			 */
			if (state->heap_queue_len > 0 &&
				++state->heap_queue_walked >= HEAP_QUEUE_MAX_WALK)
			{
				state->heap_queue_drain = true;
				return false;
			}

			if (++stream->skip.behind >= stream->skip.threshold)
			{
				if (state->heap_queue_len > 0)
					state->heap_queue_walked += HEAP_QUEUE_SKIP_WALK;
				skip_ahead(state, stream, candidate->value, candidate->isnull);
			}
		}

		stream->skip.behind = 0;
		if (cmp > 0)
		{
			candidate = stream;
			turn = 0;
		}
		else
			turn++;
	}

	MemoryContextReset(state->group_cxt);
	oldcxt = MemoryContextSwitchTo(state->group_cxt);
	state->group_isnull = candidate->isnull;
	state->group_value = candidate->isnull ? (Datum) 0 :
		datumCopy(candidate->value, state->sort_typbyval, state->sort_typlen);
	MemoryContextSwitchTo(oldcxt);

	return true;
}

/*
 * heap_queue_adjust
 *		How many matches to gather before fetching them.  Finding a match
 *		ahead reads the indexes further than a LIMIT may need, which a row
 *		returned would not repay; a row the Filter drops is one more heap page
 *		read for nothing, and so is a row version the snapshot does not see,
 *		where asking for the pages ahead pays.  So the target grows only while
 *		fewer fetches return a row than do not, and a node without a Filter
 *		stays at 1, one match at a time.
 */
static void
heap_queue_adjust(IntersectScanState *state)
{
	int64		wasted = state->rows_fetched - state->rows_emitted;

	if (state->rows_fetched < HEAP_QUEUE_WINDOW)
		return;

	if (wasted > state->rows_emitted)
		state->heap_queue_target = Min(state->heap_queue_target * 2,
									   state->heap_queue_limit);
	else if (state->rows_emitted > wasted)
		state->heap_queue_target = Max(state->heap_queue_target / 2, 1);
	state->rows_fetched = 0;
	state->rows_emitted = 0;
}

/*
 * heap_queue_add
 *		Keep a match for later and ask for its heap page now.  A TID stays
 *		valid while the scan goes on for an MVCC snapshot alone (as in a
 *		bitmap scan): a line pointer reused meanwhile holds a row the snapshot
 *		does not see.  heap_queue_limit is 1 for any other snapshot.
 */
static void
heap_queue_add(IntersectScanState *state, ItemPointer tid)
{
	BlockNumber block = ItemPointerGetBlockNumber(tid);

	state->heap_queue[state->heap_queue_len++] = *tid;
	if (block != state->heap_prefetch_block)
	{
		(void) PrefetchBuffer(state->css.ss.ss_currentRelation, MAIN_FORKNUM,
							  block);
		state->heap_prefetch_block = block;
		state->heap_prefetches++;
	}
	if (state->heap_queue_len >= state->heap_queue_target)
		state->heap_queue_drain = true;
}

/*
 * heap_queue_end_merge
 *		The merge has no more matches.  Returns false when the queue still
 *		holds some, to be fetched before the merge ends.
 */
static bool
heap_queue_end_merge(IntersectScanState *state)
{
	if (state->heap_queue_len == 0)
		return true;
	state->merge_ended = true;
	state->heap_queue_drain = true;
	return false;
}

/*
 * intersect_next
 *		Merge the sorted index streams: advance the lagging streams until
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
			/*
			 * What a fetch finds marks the entry the scan stands on as dead.
			 * The scan has moved on from a queued entry, unless it is the
			 * last one read and not passed yet; the fetch may change the TID.
			 */
			bool		moved_on = state->heap_queue_next > 0 &&
				(outer->have ||
				 !ItemPointerEquals(&outer->tid, &outer->scan->xs_heaptid));
			bool		found = index_fetch_heap(outer->scan, slot);

			state->heap_fetches++;
			state->rows_fetched++;
			state->fetching_match = outer->scan->xs_heap_continue;
			if (moved_on)
				outer->scan->kill_prior_tuple = false;
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

		if (state->heap_queue_drain)
		{
			if (state->heap_queue_next < state->heap_queue_len)
			{
				outer->scan->xs_heaptid =
					state->heap_queue[state->heap_queue_next++];
				state->fetching_match = true;
				state->match_by_pred = false;
				continue;
			}
			state->heap_queue_len = 0;
			state->heap_queue_next = 0;
			state->heap_queue_walked = 0;
			state->heap_queue_drain = false;
			if (state->merge_ended)
				break;
		}

		if (!outer->have)
		{
			read_stream_entry(state, outer);
			if (outer->eof)
			{
				if (heap_queue_end_merge(state))
					break;
				continue;
			}
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
				if (state->heap_queue_len == 0)
					heap_queue_adjust(state);
				if (!by_pred && state->heap_queue_target > 1)
				{
					heap_queue_add(state, &outer->tid);
					continue;
				}
				outer->scan->xs_heaptid = outer->tid;
				state->fetching_match = true;
				state->match_by_pred = by_pred;
			}
			else if (state->heap_queue_len > 0 &&
					 ++state->heap_queue_walked >= HEAP_QUEUE_MAX_WALK)
				state->heap_queue_drain = true;

			continue;
		}

		if (!find_common_value(state))
		{
			if (state->heap_queue_drain)
				continue;
			if (heap_queue_end_merge(state))
				break;
			continue;
		}

		state->in_group = true;
		for (int i = 1; i < state->nstreams; i++)
		{
			collect_group(state, &state->streams[i]);

			/*
			 * An overflowed group's stream is read on the row with the state
			 * of this group, which a queue would outlive: fetch what is
			 * queued first, then these entries one by one.
			 */
			if (state->heap_queue_len > 0)
			{
				state->heap_queue_walked += state->streams[i].group_count;
				if (state->streams[i].group_overflow ||
					state->heap_queue_walked >= HEAP_QUEUE_MAX_WALK)
					state->heap_queue_drain = true;
			}
		}
	}

	/*
	 * The merge ends when one stream runs out, with the others still on a
	 * leaf page.  The scans keep it pinned, as an Index Only Scan does, since
	 * the sort value is read from the index tuple (xs_want_itup); VACUUM of
	 * the index would wait for that pin as long as an exhausted cursor stays
	 * open.  Resetting the scans releases the pins; a rescan positions them
	 * again.
	 */
	if (!state->done)
	{
		for (int i = 0; i < state->nstreams; i++)
		{
			IndexStream *stream = &state->streams[i];
			StreamClock clock;

			lf_instr_start(&stream->instr, &clock);
			lf_rescan_with_keys(stream->scan, &stream->keys, SORT_BOUND_NONE,
								(Datum) 0);
			lf_instr_stop(&stream->instr, &clock);
		}
	}
	state->done = true;

	return ExecClearTuple(slot);
}

/*
 * intersect_recheck
 *		EvalPlanQual recheck: the row version may have changed since the index
 *		entries were matched, so what the scan guaranteed by construction is
 *		evaluated again.  ExecScan applies the node's qual afterwards.
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
	IntersectScanState *state = (IntersectScanState *) node;
	TupleTableSlot *slot;

	slot = ExecScan(&node->ss, (ExecScanAccessMtd) intersect_next,
					(ExecScanRecheckMtd) intersect_recheck);
	if (!TupIsNull(slot))
		state->rows_emitted++;
	return slot;
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
	state->heap_queue_len = 0;
	state->heap_queue_next = 0;
	state->heap_queue_target = 1;
	state->heap_queue_walked = 0;
	state->heap_queue_drain = false;
	state->merge_ended = false;
	state->heap_prefetch_block = InvalidBlockNumber;
	state->rows_fetched = 0;
	state->rows_emitted = 0;
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
 * stream_conditions
 *		The equalities of a stream as text, each index column against its
 *		value expression, deparsed like an Index Cond.  NULL without any.
 */
static char *
stream_conditions(IntersectScanState *state, int i, List *context,
				  bool useprefix)
{
	CustomScan *cscan = (CustomScan *) state->css.ss.ps.plan;
	IndexStream *stream = &state->streams[i];
	List	   *exprs = list_nth_node(List, cscan->custom_exprs,
									  i * STREAM_EXPRS_COUNT + STREAM_EXPRS_KEYS);
	TupleDesc	indexdesc = RelationGetDescr(stream->index);
	List	   *clauses = NIL;
	int			k = 0;
	ListCell   *lc;

	foreach(lc, exprs)
	{
		Form_pg_attribute attr = TupleDescAttr(indexdesc, k);
		Var		   *column = makeVar(cscan->scan.scanrelid,
									 stream->keys.attnos[k], attr->atttypid,
									 attr->atttypmod, attr->attcollation, 0);

		clauses = lappend(clauses,
						  make_opclause(stream->keys.operators[k], BOOLOID,
										false, (Expr *) column,
										(Expr *) lfirst(lc), InvalidOid,
										stream->keys.collations[k]));
		k++;
	}
	if (clauses == NIL)
		return NULL;
	return deparse_expression((Node *) make_ands_explicit(clauses), context,
							  useprefix, false);
}

/*
 * stream_predicate
 *		The predicate of a partial index as text, from the index itself, so
 *		that the outer stream shows it too (the node checks it on the row,
 *		as Filter, not in the stream).  NULL for a full index.
 */
static char *
stream_predicate(IntersectScanState *state, int i, List *context,
				 bool useprefix)
{
	CustomScan *cscan = (CustomScan *) state->css.ss.ps.plan;
	List	   *pred = RelationGetIndexPredicate(state->streams[i].index);

	if (pred == NIL)
		return NULL;
	/* a copy of the relcache's list: free to rewrite */
	ChangeVarNodes((Node *) pred, 1, cscan->scan.scanrelid, 0);
	return deparse_expression((Node *) make_ands_explicit(pred), context,
							  useprefix, false);
}

/* One kind of buffers in the text form: " shared hit=N read=M", nonzero parts. */
static void
buffers_text(StringInfo str, const char *kind, int64 hit, int64 read,
			 int64 dirtied, int64 written)
{
	appendStringInfoString(str, kind);
	if (hit > 0)
		appendStringInfo(str, " hit=%lld", (long long) hit);
	if (read > 0)
		appendStringInfo(str, " read=%lld", (long long) read);
	if (dirtied > 0)
		appendStringInfo(str, " dirtied=%lld", (long long) dirtied);
	if (written > 0)
		appendStringInfo(str, " written=%lld", (long long) written);
}

/* The buffers of a stream's index calls, in the manner of a node's. */
static void
stream_buffers(IndexStream *stream, ExplainState *es)
{
	BufferUsage *usage = &stream->instr.buffers;

	bool		has_shared = usage->shared_blks_hit + usage->shared_blks_read +
		usage->shared_blks_dirtied + usage->shared_blks_written > 0;
	bool		has_local = usage->local_blks_hit + usage->local_blks_read +
		usage->local_blks_dirtied + usage->local_blks_written > 0;

	if (es->format == EXPLAIN_FORMAT_TEXT)
	{
		if (!has_shared && !has_local)
			return;
		ExplainIndentText(es);
		appendStringInfoString(es->str, "Buffers:");
		if (has_shared)
			buffers_text(es->str, " shared", usage->shared_blks_hit,
						 usage->shared_blks_read, usage->shared_blks_dirtied,
						 usage->shared_blks_written);
		if (has_local)
			buffers_text(es->str, " local", usage->local_blks_hit,
						 usage->local_blks_read, usage->local_blks_dirtied,
						 usage->local_blks_written);
		appendStringInfoChar(es->str, '\n');
	}
	else
	{
		ExplainPropertyInteger("Shared Hit Blocks", NULL,
							   usage->shared_blks_hit, es);
		ExplainPropertyInteger("Shared Read Blocks", NULL,
							   usage->shared_blks_read, es);
		ExplainPropertyInteger("Shared Dirtied Blocks", NULL,
							   usage->shared_blks_dirtied, es);
		ExplainPropertyInteger("Shared Written Blocks", NULL,
							   usage->shared_blks_written, es);
		ExplainPropertyInteger("Local Hit Blocks", NULL,
							   usage->local_blks_hit, es);
		ExplainPropertyInteger("Local Read Blocks", NULL,
							   usage->local_blks_read, es);
		ExplainPropertyInteger("Local Dirtied Blocks", NULL,
							   usage->local_blks_dirtied, es);
		ExplainPropertyInteger("Local Written Blocks", NULL,
							   usage->local_blks_written, es);
	}
}

/*
 * intersect_explain
 *		The node's counters, then one block per stream in the manner of a
 *		child node: its index, conditions, time, entries read and buffers.
 *		Counters are summed over all rescans like the executor's own; the
 *		text form shows entries and times per loop, as a node's rows.
 */
static void
intersect_explain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	IntersectScanState *state = (IntersectScanState *) node;
	List	   *context = set_deparse_context_plan(es->deparse_cxt,
												   node->ss.ps.plan, ancestors);
	bool		useprefix = es->verbose || es->rtable_size > 1;
	double		nloops = node_nloops(&node->ss.ps);
	int64		skips = 0;
	int64		short_skips = 0;
	int64		group_overflows = 0;

	for (int i = 0; i < state->nstreams; i++)
	{
		skips += state->streams[i].skips;
		short_skips += state->streams[i].short_skips;
		group_overflows += state->streams[i].group_overflows;
	}

	if (es->analyze)
	{
		ExplainPropertyInteger("Matched TIDs", NULL, state->matched, es);
		ExplainPropertyInteger("Heap Fetches", NULL, state->heap_fetches, es);
		if (state->heap_prefetches > 0)
			ExplainPropertyInteger("Heap Prefetches", NULL,
								   state->heap_prefetches, es);
		ExplainPropertyInteger("Peak Group Memory", "B",
							   (int64) state->peak_capacity *
							   sizeof(ItemPointerData), es);
		if (skips > 0)
		{
			ExplainPropertyInteger("Skips", NULL, skips, es);
			ExplainPropertyInteger("Short Skips", NULL, short_skips, es);
		}
		if (group_overflows > 0)
		{
			ExplainPropertyInteger("Group Overflows", NULL, group_overflows,
								   es);
			ExplainPropertyInteger("Rows Checked by Predicate", NULL,
								   state->pred_checked, es);
		}
	}

	if (es->format != EXPLAIN_FORMAT_TEXT)
		ExplainOpenGroup("Index Streams", "Index Streams", false, es);
	for (int i = 0; i < state->nstreams; i++)
	{
		IndexStream *stream = &state->streams[i];
		const char *role = i == 0 ? "Outer" : "Inner";
		const char *index_name = RelationGetRelationName(stream->index);
		char	   *cond = stream_conditions(state, i, context, useprefix);
		char	   *pred = stream_predicate(state, i, context, useprefix);

		if (es->format == EXPLAIN_FORMAT_TEXT)
		{
			ExplainIndentText(es);
			appendStringInfo(es->str, "->  %s Stream on %s", role, index_name);
			if (es->analyze)
			{
				if (nloops <= 0)
					appendStringInfoString(es->str, " (never executed)");
				else if (es->timing)
					appendStringInfo(es->str,
									 " (actual time=%.3f..%.3f rows=%.2f loops=%.0f)",
									 INSTR_TIME_GET_MILLISEC(stream->startup) / nloops,
									 INSTR_TIME_GET_MILLISEC(stream->instr.time) / nloops,
									 stream->read / nloops, nloops);
				else
					appendStringInfo(es->str,
									 " (actual rows=%.2f loops=%.0f)",
									 stream->read / nloops, nloops);
			}
			appendStringInfoChar(es->str, '\n');
			es->indent += 3;
		}
		else
		{
			ExplainOpenGroup("Index Stream", NULL, true, es);
			ExplainPropertyText("Role", role, es);
			ExplainPropertyText("Index Name", index_name, es);
		}
		if (cond != NULL)
			ExplainPropertyText("Index Cond", cond, es);
		if (pred != NULL)
			ExplainPropertyText("Index Pred", pred, es);
		if (es->verbose && es->costs)
			ExplainPropertyFloat("Entries Estimated", NULL, stream->estimate,
								 0, es);
		if (es->analyze)
		{
			if (es->format != EXPLAIN_FORMAT_TEXT)
			{
				if (es->timing && nloops > 0)
				{
					ExplainPropertyFloat("Actual Startup Time", "ms",
										 INSTR_TIME_GET_MILLISEC(stream->startup) / nloops,
										 3, es);
					ExplainPropertyFloat("Actual Total Time", "ms",
										 INSTR_TIME_GET_MILLISEC(stream->instr.time) / nloops,
										 3, es);
				}
				ExplainPropertyInteger("Entries Read", NULL, stream->read, es);
			}
			if (stream->skips > 0)
			{
				ExplainPropertyInteger("Skips", NULL, stream->skips, es);
				ExplainPropertyInteger("Short Skips", NULL,
									   stream->short_skips, es);
			}
			if (stream->group_overflows > 0)
				ExplainPropertyInteger("Group Overflows", NULL,
									   stream->group_overflows, es);
			if (stream->instr.prefetches > 0)
				ExplainPropertyInteger("Prefetches", NULL,
									   stream->instr.prefetches, es);
			if (es->buffers)
				stream_buffers(stream, es);
		}
		if (es->format == EXPLAIN_FORMAT_TEXT)
			es->indent -= 3;
		else
			ExplainCloseGroup("Index Stream", NULL, true, es);
	}
	if (es->format != EXPLAIN_FORMAT_TEXT)
		ExplainCloseGroup("Index Streams", "Index Streams", false, es);
}
