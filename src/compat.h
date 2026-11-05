/*-------------------------------------------------------------------------
 *
 * compat.h
 *	  Every difference between the PostgreSQL major versions this extension
 *	  builds against, in one place, after PG-Strom's pg_compat.h and Citus's
 *	  pg_version_constants.h.  The .c files test no PG_VERSION_NUM of their
 *	  own: they use the shims below.
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
#include "utils/sortsupport.h"

#define PG_VERSION_18 180000
#define PG_VERSION_19 190000

#if PG_VERSION_NUM < PG_VERSION_18
#error "leapfrog needs PostgreSQL 18 or later"
#endif

/*
 * index_beginscan with no instrumentation and no ORDER BY keys.
 *
 * PostgreSQL 19 (commit dcd8cc1c852c, "Thread flags through begin-scan
 * APIs") adds a table AM flags argument to index_beginscan.
 */
#if PG_VERSION_NUM >= PG_VERSION_19
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0, SO_NONE)
#else
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0)
#endif

/*
 * The node's instrumentation under EXPLAIN ANALYZE.
 *
 * PostgreSQL 19 (commit 5a79e78501f4, "instrumentation: Separate per-node
 * logic from other uses") makes PlanState.instrument a NodeInstrumentation,
 * which keeps the loop count and wraps the timer and buffer usage flags in
 * an Instrumentation of its own (field instr).
 */
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

/* nloops stays a field of PlanState.instrument in both versions */
static inline double
lf_node_nloops(PlanState *ps)
{
	return ps->instrument != NULL ? ps->instrument->nloops : 0;
}

/*
 * LF_DATUM_IS_64BIT: Datum holds an int64 by value, so sort support may pick
 * ssup_datum_signed_cmp, which sortsupport.h declares only then.
 *
 * PostgreSQL 19 (commit 2a600a93c7be, "Make type Datum be 8 bytes wide
 * everywhere") makes it so on every platform; before, only where
 * SIZEOF_DATUM is 8.
 */
#if PG_VERSION_NUM >= PG_VERSION_19 || SIZEOF_DATUM >= 8
#define LF_DATUM_IS_64BIT 1
#else
#define LF_DATUM_IS_64BIT 0
#endif

#endif							/* LEAPFROG_COMPAT_H */
