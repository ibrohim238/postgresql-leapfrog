/*-------------------------------------------------------------------------
 *
 * indexstream.c
 *	  Reading one btree index as a sorted stream of (sortcol value, heap
 *	  TID) entries without visiting the heap.
 *
 * IDENTIFICATION
 *	  src/indexstream.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/itup.h"
#include "access/nbtree.h"
#include "access/relscan.h"
#include "access/stratnum.h"
#include "catalog/pg_opfamily_d.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "storage/bufmgr.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"

#include "leapfrog.h"

/*
 * lf_scan_leaf_position
 *		The leaf page the scan is on and its neighbour in scan direction;
 *		false when it is positioned nowhere.  Reads nbtree's private state.
 */
bool
lf_scan_leaf_position(IndexScanDesc scan, bool backward, BlockNumber *page,
					  BlockNumber *next_page)
{
	BTScanOpaque so = (BTScanOpaque) scan->opaque;

	*page = so->currPos.currPage;
	*next_page = backward ? so->currPos.prevPage : so->currPos.nextPage;

	return BTScanPosIsValid(so->currPos);
}

/*
 * lf_rescan_with_keys
 *		Position an index scan on the stream's equality values and on what is
 *		asked of sortcol.  The scan is opened with room for nequal + 1 keys.
 */
void
lf_rescan_with_keys(IndexScanDesc scan, EqualityKeys *keys, SortBound kind,
					Datum bound)
{
	ScanKeyData scankeys[INDEX_MAX_KEYS + 1];
	int			nkeys = keys->nequal;

	for (int i = 0; i < keys->nequal; i++)
		ScanKeyEntryInitialize(&scankeys[i], 0, i + 1, BTEqualStrategyNumber,
							   keys->subtypes[i], keys->collations[i],
							   keys->procs[i], keys->values[i]);

	switch (kind)
	{
		case SORT_BOUND_NONE:
			break;
		case SORT_BOUND_VALUE:
			ScanKeyEntryInitialize(&scankeys[nkeys], 0, keys->nequal + 1,
								   keys->bound_strategy, keys->sort_type,
								   keys->sort_collation, keys->bound_proc,
								   bound);
			nkeys++;
			break;
		case SORT_BOUND_NOT_NULL:
			ScanKeyEntryInitialize(&scankeys[nkeys],
								   SK_ISNULL | SK_SEARCHNOTNULL,
								   keys->nequal + 1, InvalidStrategy,
								   InvalidOid, InvalidOid, InvalidOid,
								   (Datum) 0);
			nkeys++;
			break;
		case SORT_BOUND_NULL:
			ScanKeyEntryInitialize(&scankeys[nkeys], SK_ISNULL | SK_SEARCHNULL,
								   keys->nequal + 1, InvalidStrategy,
								   InvalidOid, InvalidOid, InvalidOid,
								   (Datum) 0);
			nkeys++;
			break;
	}

	scan->numberOfKeys = nkeys;
	index_rescan(scan, scankeys, nkeys, NULL, 0);
}

/*
 * lf_init_key_procs
 *		Look up the functions of the equality and the sortcol bound operators.
 */
void
lf_init_key_procs(EqualityKeys *keys, Oid sort_type, Oid opfamily,
				  Oid collation, bool descending)
{
	Oid			bound_op;

	for (int i = 0; i < keys->nequal; i++)
	{
		Oid			lefttype;

		keys->procs[i] = get_opcode(keys->operators[i]);
		op_input_types(keys->operators[i], &lefttype, &keys->subtypes[i]);
	}

	keys->sort_type = sort_type;
	keys->sort_collation = collation;
	keys->bound_strategy = descending ? BTLessEqualStrategyNumber :
		BTGreaterEqualStrategyNumber;
	bound_op = get_opfamily_member(opfamily, sort_type, sort_type,
								   keys->bound_strategy);
	if (!OidIsValid(bound_op))
		elog(ERROR, "missing operator %d(%u,%u) in opfamily %u",
			 keys->bound_strategy, sort_type, sort_type, opfamily);
	keys->bound_proc = get_opcode(bound_op);
}

/* Whether the next entry comes from another leaf page. */
static inline bool
scan_will_step(IndexScanDesc scan, ScanDirection dir)
{
	BTScanOpaque so = (BTScanOpaque) scan->opaque;

	if (!BTScanPosIsValid(so->currPos))
		return true;
	if (ScanDirectionIsForward(dir))
		return so->currPos.itemIndex >= so->currPos.lastItem;
	return so->currPos.itemIndex <= so->currPos.firstItem;
}

/* Prefetch the next leaf page, unless nbtree knows the scan ends here. */
static inline bool
prefetch_next_leaf(IndexScanDesc scan, ScanDirection dir)
{
	BTScanOpaque so = (BTScanOpaque) scan->opaque;
	bool		forward = ScanDirectionIsForward(dir);
	BlockNumber next;

	if (!BTScanPosIsValid(so->currPos))
		return false;
	if (forward ? !so->currPos.moreRight : !so->currPos.moreLeft)
		return false;
	next = forward ? so->currPos.nextPage : so->currPos.prevPage;
	if (!BlockNumberIsValid(next))
		return false;
	PrefetchBuffer(scan->indexRelation, MAIN_FORKNUM, next);
	return true;
}

/*
 * lf_read_index_entry
 *		Fetch the next (sortcol value, heap TID) entry.  A by-reference value
 *		points into the scan's index tuple: valid until the scan moves on.
 *		skip_nulls drops NULL entries, which may be dead even under NOT NULL
 *		(docs/design.md).  instr is NULL for a planner probe.
 */
bool
lf_read_index_entry(IndexScanDesc scan, ScanDirection dir, int attno,
					bool skip_nulls, Datum *value, bool *isnull,
					ItemPointer tid, int64 *entries_read, StreamInstr *instr)
{
	for (;;)
	{
		Datum		datum;
		bool		datum_isnull;
		bool		found;

		if (instr != NULL && scan_will_step(scan, dir))
		{
			StreamClock clock;

			lf_instr_start(instr, &clock);
			found = index_getnext_tid(scan, dir) != NULL;
			lf_instr_stop(instr, &clock);
			if (found && intersect_prefetch && prefetch_next_leaf(scan, dir))
				instr->prefetches++;
		}
		else
			found = index_getnext_tid(scan, dir) != NULL;
		if (!found)
			return false;
		(*entries_read)++;

		Assert(scan->xs_itup != NULL);

		datum = index_getattr(scan->xs_itup, attno, scan->xs_itupdesc,
							  &datum_isnull);
		if (datum_isnull && skip_nulls)
		{
			CHECK_FOR_INTERRUPTS();
			continue;
		}

		*value = datum;
		*isnull = datum_isnull;
		ItemPointerCopy(&scan->xs_heaptid, tid);

		return true;
	}
}
