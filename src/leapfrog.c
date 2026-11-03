/*-------------------------------------------------------------------------
 *
 * leapfrog.c
 *	  Index Merge Intersect custom scan: intersection of btree indexes by
 *	  merging their sorted streams.  Module entry point, settings and
 *	  SQL-callable functions.
 *
 * With every column before sortcol fixed by equality with a value known at
 * execution time, the scans of the indexes produce sortcol values in the same
 * order (planner.c).  The merge column may be of any type with a btree
 * operator family: values compare with the comparator of the query's sort
 * key, and NULLs are values of the merge, in the order the query asks for.
 *
 * The entries of one value are matched by heap TID as well (executor.c), so
 * the merge stays correct when sortcol is not unique or dead row versions are
 * still in the index.  The TIDs of one value are not in a usable order on both
 * sides (a backward scan returns posting-list TIDs ascending), so the inner
 * entries of the value are collected into a sorted group and the outer entries
 * are looked up in it.  The path is offered only when the estimated inner
 * entries per value fit into work_mem, and at execution time a group that
 * outgrows work_mem is abandoned for that value: its outer entries are all
 * fetched from the heap and checked against the inner index conditions
 * (equalities and predicate) before the node's qual sees them, so the fallback
 * does not depend on what the qual holds.  The heap is otherwise visited only
 * for matches, walking HOT chains the way index_getnext_slot does.
 *
 * leapfrog.force chooses the intersection whenever a suitable set of indexes
 * exists, regardless of the cost of other plans; the cheapest set still wins.
 * It is a diagnostic knob and can make a query far slower.
 *
 * Under EvalPlanQual the scan rechecks what it guaranteed by construction, as
 * an index scan rechecks indexqualorig: the equalities on the columns of the
 * indexes and the predicate of an inner index.
 *
 * Limitations: the scan covers a single relation only; a partitioned table
 * gets one per partition.
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

#include "fmgr.h"
#include "utils/builtins.h"
#include "utils/guc.h"

#include "leapfrog.h"

PG_MODULE_MAGIC_EXT(
					.name = "leapfrog",
					.version = LEAPFROG_VERSION
);

/*
 * A lagging scan is re-positioned once it has read this many entries in a row
 * without catching up.  A re-descent costs tree_height buffer accesses plus
 * restarting the scan, while a leaf page holds about 400 int8 entries, so a
 * skip pays only when it moves past the next leaf page.  This is the start of
 * each side's adaptive threshold (SkipAhead in executor.c); measurements are
 * in the README, 16 and 32 differ from 64 by less than 5 %.
 */
#define INTERSECT_SKIP_AFTER 64

bool		intersect_enabled = true;
bool		intersect_force = false;
int			intersect_skip_after = INTERSECT_SKIP_AFTER;
bool		intersect_trace_planner = false;
PlannerTrace lf_trace;
int			intersect_max_streams = 4;
int			intersect_min_streams = 2;

static bool intersect_hook_installed = false;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(leapfrog_version);
PG_FUNCTION_INFO_V1(leapfrog_is_loaded);

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

	DefineCustomBoolVariable("leapfrog.trace_planner",
							 "Reports what planning an Index Merge Intersect did.",
							 "A developer setting: the tests check the work of the planner by these counts.",
							 &intersect_trace_planner,
							 false,
							 PGC_USERSET,
							 GUC_NOT_IN_SAMPLE,
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

	DefineCustomIntVariable("leapfrog.max_indexes",
							"The most indexes one Index Merge Intersect node combines.",
							"Streams are added one at a time while each one lowers the estimated cost.",
							&intersect_max_streams,
							4,
							2,
							INTERSECT_MAX_STREAMS,
							PGC_USERSET,
							0,
							NULL,
							NULL,
							NULL);

	DefineCustomIntVariable("leapfrog.min_indexes",
							"The fewest indexes an Index Merge Intersect node combines.",
							"Developer option: smaller sets are not offered, so that a larger "
							"set can be run against the stock plans.",
							&intersect_min_streams,
							2,
							2,
							INTERSECT_MAX_STREAMS,
							PGC_USERSET,
							GUC_NOT_IN_SAMPLE,
							NULL,
							NULL,
							NULL);

	MarkGUCPrefixReserved("leapfrog");

	RegisterCustomScanMethods(&lf_scan_methods);

	lf_planner_init();
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
 *		SQL-callable: is the planner hook active in this session?  Calling it
 *		loads the library, so the answer is true whenever the call succeeds;
 *		it exists for scripts that need an explicit check.
 */
Datum
leapfrog_is_loaded(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(intersect_hook_installed);
}
