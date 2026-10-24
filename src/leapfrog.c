/*-------------------------------------------------------------------------
 *
 * leapfrog.c
 *	  Index Merge Intersect custom scan: intersection of two btree indexes
 *	  by merging their sorted streams, modeled on MySQL's index merge
 *	  intersection (RowIDIntersectionIterator, ROR_intersect_plan).
 *
 * For every base relation of the query an index pair is chosen
 * automatically (planner.c):
 *
 *	- the outer index (k1, ..., kN, sortcol): every kI is compared for
 *	  equality with a value known at execution time (a constant, a query
 *	  parameter or a column of an outer relation), and its last column is
 *	  the first sort key of the query;
 *	- the inner index (j1, ..., jM, sortcol, ...), M >= 0: every jI is
 *	  compared for equality in the same way, and if the index is partial its
 *	  predicate is implied by the query's restrictions.  With M = 0 it must
 *	  be partial, or it would not narrow anything down; an ordinary index
 *	  whose equality columns all appear in the outer index is not used
 *	  either.  Typical inner sides: (sortcol) WHERE deleted_at IS NULL, or
 *	  another (filter_column, sortcol).
 *
 * With every column before sortcol fixed by equality, both scans produce
 * sortcol values in the same order.
 *
 * Execution (executor.c) follows RowIDIntersectionIterator::DoRead: both
 * indexes are read sequentially in the same direction and the side that
 * lags behind is advanced until the values meet.  MySQL merges rowids; here
 * the entries of one value are matched by heap TID as well, so the merge
 * stays correct when sortcol is not unique or dead row versions are still
 * in the index.  The TIDs of one value are not in a usable order on both
 * sides (a backward scan returns posting-list TIDs ascending), so the inner
 * entries of the value are collected into a sorted group and the outer
 * entries are looked up in it.  The group lives in memory: the path is
 * offered only when the estimated number of inner entries per value fits
 * into work_mem, and at execution time a group that outgrows work_mem is
 * abandoned for that value.  The outer entries of such a value are all
 * fetched from the heap and checked against the inner index conditions
 * explicitly (its equalities and its predicate), before the node's qual sees
 * them, so the fallback does not depend on what the qual holds.
 * The heap is otherwise visited only for matches, walking HOT chains the
 * way index_getnext_slot does.
 *
 * Only the standard integer btree operator family is supported: the scan
 * keys are built with int8 operators, so both the equality columns and the
 * merge column must belong to it.
 *
 * Costing follows ROR_intersect_plan::add, with every component expressed
 * through the planner's own cost functions (costsize.c).
 *
 * leapfrog.force is the counterpart of MySQL's INDEX_MERGE hint
 * (ignore_cost in ROR_intersect_plan::add): the intersection is chosen
 * whenever a suitable index pair exists, regardless of the cost of the
 * other plans.  Among several pairs the cheapest one still wins.  It is a
 * diagnostic knob and can make a query far slower.
 *
 * Under EvalPlanQual the scan rechecks what it guaranteed by construction,
 * as an index scan rechecks indexqualorig: the equalities on the columns of
 * both indexes and the predicate of the inner index.
 *
 * Limitations: key columns must be bigint and the scan covers a single
 * relation only.
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

/* GUC variables */
bool		intersect_enabled = true;
bool		intersect_force = false;
int			intersect_skip_after = INTERSECT_SKIP_AFTER;

/* Set once the hook is installed */
static bool intersect_hook_installed = false;

void		_PG_init(void);

PG_FUNCTION_INFO_V1(leapfrog_version);
PG_FUNCTION_INFO_V1(leapfrog_is_loaded);

/*
 * Module load callback
 */
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
 *		SQL-callable: is the planner hook active in this session?  Calling
 *		the function loads the library, so the answer is true whenever the
 *		call succeeds; it exists for scripts that need an explicit check.
 */
Datum
leapfrog_is_loaded(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(intersect_hook_installed);
}
