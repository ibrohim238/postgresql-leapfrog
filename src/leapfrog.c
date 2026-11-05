/*-------------------------------------------------------------------------
 *
 * leapfrog.c
 *	  Index Merge Intersect custom scan: module entry point, settings and
 *	  SQL-callable functions.  Design notes are in docs/design.md.
 *
 * IDENTIFICATION
 *	  src/leapfrog.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <limits.h>

#include "fmgr.h"
#include "miscadmin.h"
#include "nodes/plannodes.h"
#include "optimizer/planner.h"
#include "utils/builtins.h"
#include "utils/guc.h"

#include "leapfrog.h"

PG_MODULE_MAGIC_EXT(
					.name = "leapfrog",
					.version = LEAPFROG_VERSION
);

/* Starting skip-ahead threshold, in entries; see docs/design.md. */
#define INTERSECT_SKIP_AFTER 64

bool		intersect_enabled = true;
bool		intersect_force = false;
int			intersect_skip_after = INTERSECT_SKIP_AFTER;
bool		intersect_trace_planner = false;
bool		intersect_prefetch = true;
PlannerTrace lf_trace;
int			intersect_max_streams = 4;
int			intersect_min_streams = 2;

typedef enum RequireNode
{
	REQUIRE_NODE_ALLOW,
	REQUIRE_NODE_REQUIRE,
	REQUIRE_NODE_FORBID,
} RequireNode;

static const struct config_enum_entry require_node_options[] = {
	{"allow", REQUIRE_NODE_ALLOW, false},
	{"require", REQUIRE_NODE_REQUIRE, false},
	{"forbid", REQUIRE_NODE_FORBID, false},
	{NULL, 0, false}
};

static int	intersect_require_node = REQUIRE_NODE_ALLOW;

static planner_hook_type prev_planner_hook = NULL;

static bool intersect_hook_installed = false;

static PlannedStmt *intersect_planner(LF_PLANNER_ARGS);
static bool plan_has_node(Plan *plan);
static bool plan_list_has_node(List *plans);

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

	DefineCustomBoolVariable("leapfrog.prefetch",
							 "Prefetches the next leaf page of every index stream, and heap pages of rows ahead where the Filter drops most of them.",
							 NULL,
							 &intersect_prefetch,
							 true,
							 PGC_USERSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	DefineCustomEnumVariable("leapfrog.require_node",
							 "Raises an error when a plan lacks, or has, an Index Merge Intersect node.",
							 "Developer setting for the tests: \"require\" fails a query whose "
							 "plan has no Index Merge Intersect node, \"forbid\" one whose plan "
							 "has it, \"allow\" checks nothing.",
							 &intersect_require_node,
							 REQUIRE_NODE_ALLOW,
							 require_node_options,
							 PGC_USERSET,
							 GUC_NOT_IN_SAMPLE,
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

	MarkGUCPrefixReserved("leapfrog");

	RegisterCustomScanMethods(&lf_scan_methods);

	lf_planner_init();

	prev_planner_hook = planner_hook;
	planner_hook = intersect_planner;

	intersect_hook_installed = true;
}

/*
 * intersect_planner
 *		planner_hook: plan as usual, then enforce leapfrog.require_node on
 *		the final plan.
 */
static PlannedStmt *
intersect_planner(LF_PLANNER_ARGS)
{
	PlannedStmt *stmt;
	bool		has_node;

	if (prev_planner_hook)
		stmt = LF_PLANNER_CALL(prev_planner_hook);
	else
		stmt = LF_PLANNER_CALL(standard_planner);

	if (intersect_require_node == REQUIRE_NODE_ALLOW)
		return stmt;

	has_node = plan_has_node(stmt->planTree) ||
		plan_list_has_node(stmt->subplans);

	if (intersect_require_node == REQUIRE_NODE_REQUIRE && !has_node)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("plan has no Index Merge Intersect node, but leapfrog.require_node is \"require\"")));
	if (intersect_require_node == REQUIRE_NODE_FORBID && has_node)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("plan has an Index Merge Intersect node, but leapfrog.require_node is \"forbid\"")));

	return stmt;
}

/*
 * plan_has_node
 *		Does the plan tree contain the node?  PlannedStmt.subplans are not
 *		in the tree; the caller checks them.
 */
static bool
plan_has_node(Plan *plan)
{
	if (plan == NULL)
		return false;

	check_stack_depth();

	switch (nodeTag(plan))
	{
		case T_CustomScan:
			if (((CustomScan *) plan)->methods == &lf_scan_methods)
				return true;
			if (plan_list_has_node(((CustomScan *) plan)->custom_plans))
				return true;
			break;
		case T_Append:
			if (plan_list_has_node(((Append *) plan)->appendplans))
				return true;
			break;
		case T_MergeAppend:
			if (plan_list_has_node(((MergeAppend *) plan)->mergeplans))
				return true;
			break;
		case T_BitmapAnd:
			if (plan_list_has_node(((BitmapAnd *) plan)->bitmapplans))
				return true;
			break;
		case T_BitmapOr:
			if (plan_list_has_node(((BitmapOr *) plan)->bitmapplans))
				return true;
			break;
		case T_SubqueryScan:
			if (plan_has_node(((SubqueryScan *) plan)->subplan))
				return true;
			break;
		default:
			break;
	}

	return plan_has_node(plan->lefttree) || plan_has_node(plan->righttree);
}

/*
 * plan_list_has_node
 *		plan_has_node over a list; an entry may be NULL (an unused subplan).
 */
static bool
plan_list_has_node(List *plans)
{
	ListCell   *lc;

	foreach(lc, plans)
	{
		if (plan_has_node((Plan *) lfirst(lc)))
			return true;
	}
	return false;
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
 *		SQL-callable: is the planner hook active in this session?
 */
Datum
leapfrog_is_loaded(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(intersect_hook_installed);
}
