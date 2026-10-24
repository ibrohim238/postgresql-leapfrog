/*-------------------------------------------------------------------------
 *
 * indexstream.c
 *	  Reading one btree index as a sorted stream of (sortcol value, heap
 *	  TID) entries: positioning it on the equality values and a bound on
 *	  sortcol, and taking entries without visiting the heap.  Used by the
 *	  executor's merge and by the planner's range probe.
 *
 * IDENTIFICATION
 *	  src/indexstream.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/itup.h"
#include "access/relscan.h"
#include "access/stratnum.h"
#include "catalog/pg_opfamily_d.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "utils/fmgroids.h"
#include "utils/lsyscache.h"

#include "leapfrog.h"

/*
 * lf_datum_get_int64
 *		Return an int2/int4/int8 datum as int64.
 */
int64
lf_datum_get_int64(Datum value, Oid type)
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

/*
 * lf_rescan_with_keys
 *		Position an index scan on the current equality values of one side
 *		and on a bound for sortcol (the key column right after them): values
 *		>= bound for a forward scan, <= bound for a backward one.  The scan
 *		was opened with nequal + 1 keys, and index_rescan must get that many.
 */
void
lf_rescan_with_keys(IndexScanDesc scan, EqualityKeys *keys, bool descending,
					int64 bound)
{
	ScanKeyData scankeys[INDEX_MAX_KEYS + 1];

	for (int i = 0; i < keys->nequal; i++)
		ScanKeyEntryInitialize(&scankeys[i], 0, i + 1, BTEqualStrategyNumber,
							   keys->subtypes[i], keys->collations[i],
							   keys->procs[i], keys->values[i]);

	if (descending)
		ScanKeyEntryInitialize(&scankeys[keys->nequal], 0, keys->nequal + 1,
							   BTLessEqualStrategyNumber, INT8OID, InvalidOid,
							   keys->bound_le, Int64GetDatum(bound));
	else
		ScanKeyEntryInitialize(&scankeys[keys->nequal], 0, keys->nequal + 1,
							   BTGreaterEqualStrategyNumber, INT8OID,
							   InvalidOid, keys->bound_ge,
							   Int64GetDatum(bound));

	index_rescan(scan, scankeys, keys->nequal + 1, NULL, 0);
}

/*
 * lf_init_key_procs
 *		Look up what the scan keys need once the operators are set: each
 *		equality operator's function and right input type, and the integer
 *		family's ">=" and "<=" of the sort column's type against int8 for the
 *		bound.  Every integer type has those cross-type operators in
 *		integer_ops, so a bound is always an int8.
 */
void
lf_init_key_procs(EqualityKeys *keys, Oid sort_type)
{
	Oid			ge;
	Oid			le;

	for (int i = 0; i < keys->nequal; i++)
	{
		Oid			lefttype;

		keys->procs[i] = get_opcode(keys->operators[i]);
		op_input_types(keys->operators[i], &lefttype, &keys->subtypes[i]);
	}

	keys->sort_type = sort_type;
	ge = get_opfamily_member(INTEGER_BTREE_FAM_OID, sort_type, INT8OID,
							 BTGreaterEqualStrategyNumber);
	le = get_opfamily_member(INTEGER_BTREE_FAM_OID, sort_type, INT8OID,
							 BTLessEqualStrategyNumber);
	if (!OidIsValid(ge) || !OidIsValid(le))
		elog(ERROR, "no integer_ops comparison of type %u with bigint",
			 sort_type);
	keys->bound_ge = get_opcode(ge);
	keys->bound_le = get_opcode(le);
}

/*
 * lf_no_bound
 *		The sortcol bound that lets every value through.
 */
int64
lf_no_bound(bool descending)
{
	return descending ? PG_INT64_MAX : PG_INT64_MIN;
}

/*
 * lf_read_index_entry
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
bool
lf_read_index_entry(IndexScanDesc scan, ScanDirection dir, int attno,
					Oid sort_type, int64 *value, ItemPointer tid,
					int64 *entries_read)
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

		*value = lf_datum_get_int64(datum, sort_type);
		ItemPointerCopy(&scan->xs_heaptid, tid);

		return true;
	}
}
