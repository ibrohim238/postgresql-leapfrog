/*-------------------------------------------------------------------------
 *
 * compat.h
 *	  Shims for the PostgreSQL major versions; the .c files test no
 *	  PG_VERSION_NUM themselves.  See docs/compat.md.
 *
 * IDENTIFICATION
 *	  src/compat.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LEAPFROG_COMPAT_H
#define LEAPFROG_COMPAT_H

#include "access/genam.h"
#include "access/tableam.h"
#include "executor/instrument.h"
#include "nodes/execnodes.h"
#include "optimizer/planner.h"
#include "utils/sortsupport.h"

#define PG_VERSION_18 180000
#define PG_VERSION_19 190000

#if PG_VERSION_NUM < PG_VERSION_18
#error "leapfrog needs PostgreSQL 18 or later"
#endif

/* PostgreSQL 19, commit dcd8cc1c852c: index_beginscan takes flags */
#if PG_VERSION_NUM >= PG_VERSION_19
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0, SO_NONE)
#else
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0)
#endif

/* PostgreSQL 19, commit 5a79e78501f4: the flags move to instrument->instr */
static inline bool
lf_node_need_timer(PlanState *ps)
{
#if PG_VERSION_NUM >= PG_VERSION_19
	return ps->instrument != NULL && ps->instrument->instr.need_timer;
#else
	return ps->instrument != NULL && ps->instrument->need_timer;
#endif
}

static inline bool
lf_node_need_bufusage(PlanState *ps)
{
#if PG_VERSION_NUM >= PG_VERSION_19
	return ps->instrument != NULL && ps->instrument->instr.need_bufusage;
#else
	return ps->instrument != NULL && ps->instrument->need_bufusage;
#endif
}

static inline double
lf_node_nloops(PlanState *ps)
{
	return ps->instrument != NULL ? ps->instrument->nloops : 0;
}

/* PostgreSQL 19, commit 2a600a93c7be: Datum is 8 bytes everywhere */
#if PG_VERSION_NUM >= PG_VERSION_19 || SIZEOF_DATUM >= 8
#define LF_DATUM_IS_64BIT 1
#else
#define LF_DATUM_IS_64BIT 0
#endif

/* PostgreSQL 19, commit c83ac02ec730: planner_hook takes an ExplainState */
#if PG_VERSION_NUM >= PG_VERSION_19
#define LF_PLANNER_ARGS \
	Query *parse, const char *query_string, int cursorOptions, \
	ParamListInfo boundParams, ExplainState *es
#define LF_PLANNER_CALL(fn) \
	fn(parse, query_string, cursorOptions, boundParams, es)
#else
#define LF_PLANNER_ARGS \
	Query *parse, const char *query_string, int cursorOptions, \
	ParamListInfo boundParams
#define LF_PLANNER_CALL(fn) \
	fn(parse, query_string, cursorOptions, boundParams)
#endif

#endif							/* LEAPFROG_COMPAT_H */
