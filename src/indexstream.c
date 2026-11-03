/*-------------------------------------------------------------------------
 *
 * indexstream.c
 *	  Reading one btree index as a sorted stream of (sortcol value, heap
 *	  TID) entries without visiting the heap.  Used by the executor's merge
 *	  and by the planner's range probe.
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
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"

#include "leapfrog.h"

/*
 * lf_scan_leaf_position
 *		The leaf page the scan is positioned on and its neighbour in scan
 *		direction; false when it is positioned nowhere.  The only read of
 *		nbtree's private scan state, for the skip-ahead's landing check.
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
 *		asked of sortcol.  Opened with room for nequal + 1 keys; numberOfKeys
 *		follows the keys used, as no value lets every entry through.
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
 *		Look up each equality operator's function and right input type, and
 *		for the bound the opfamily's ">=" or "<=" of the sort type, by the
 *		direction of the pathkey.
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

/*
 * lf_read_index_entry
 *		Fetch the next (sortcol value, heap TID) entry.  *entries_read counts
 *		every entry taken, skipped ones too.  A by-reference value points into
 *		the scan's index tuple: it stays valid until the scan moves on.
 *
 * skip_nulls means the planner found sortcol NOT NULL, but that describes the
 * live rows: an index can hold dead NULL entries until VACUUM, for instance
 * when a NULL was updated away before SET NOT NULL.  They cannot belong to a
 * row the merge returns, since NULL never satisfies the equality the merge is
 * built on, and treated as values they would derail it: a backward scan reads
 * them first.  Otherwise a NULL is a value of the merge like any other.
 */
bool
lf_read_index_entry(IndexScanDesc scan, ScanDirection dir, int attno,
					bool skip_nulls, Datum *value, bool *isnull,
					ItemPointer tid, int64 *entries_read)
{
	for (;;)
	{
		Datum		datum;
		bool		datum_isnull;

		if (index_getnext_tid(scan, dir) == NULL)
			return false;
		(*entries_read)++;

		/* xs_want_itup is set and btree always returns the index tuple */
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
