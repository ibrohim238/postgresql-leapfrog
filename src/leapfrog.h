/*-------------------------------------------------------------------------
 *
 * leapfrog.h
 *	  Declarations shared by the parts of the Index Merge Intersect custom
 *	  scan:
 *
 *	  leapfrog.c	module entry point, settings, SQL-callable functions
 *	  planner.c		planner hook: index pairs, paths, plans
 *	  costsize.c	cost model
 *	  indexstream.c	reading one index as a sorted stream of (sortcol, TID)
 *	  executor.c	the merge, TID groups, skip-ahead, EvalPlanQual, EXPLAIN
 *
 * IDENTIFICATION
 *	  src/leapfrog.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef LEAPFROG_H
#define LEAPFROG_H

#include "access/genam.h"
#include "nodes/execnodes.h"
#include "nodes/extensible.h"
#include "nodes/pathnodes.h"

#define INTERSECT_NAME "Index Merge Intersect"

/*
 * Layout of CustomPath.custom_private.  The plan keeps the first
 * PRIVATE_COUNT entries in custom_private; the expression lists move to
 * custom_exprs at the EXPRS_* positions.
 */
#define PRIVATE_OUTER_INDEX		0
#define PRIVATE_INNER_INDEX		1
#define PRIVATE_DESCENDING		2
#define PRIVATE_INNER_SORTPOS	3
#define PRIVATE_OUTER_ESTIMATE	4	/* entries the cost model expects each
									 * side to read; EXPLAIN VERBOSE */
#define PRIVATE_INNER_ESTIMATE	5
#define PRIVATE_COUNT			6
#define EXPRS_OUTER_KEYS		0	/* value expressions of the outer
									 * equalities */
#define EXPRS_INNER_PRED		1	/* predicate of the inner index, or NIL */
#define EXPRS_INNER_KEYS		2	/* value expressions of the inner
									 * equalities */

/*
 * The equality conditions on the leading columns of one index: the value
 * expressions, their values for the current (re)scan, and the heap columns
 * they apply to (for the EvalPlanQual recheck and the overflow fallback).
 */
typedef struct EqualityKeys
{
	int			nequal;
	ExprState  *exprs[INDEX_MAX_KEYS];
	Oid			types[INDEX_MAX_KEYS];
	int64		values[INDEX_MAX_KEYS];
	AttrNumber	attnos[INDEX_MAX_KEYS];
} EqualityKeys;

/*
 * Index candidate for either side of the intersection: equality clauses of
 * the columns before sortcol, the value expressions compared against, the
 * outer rels they refer to, and the position of sortcol among the key
 * columns.  Built once per index while the relation's paths are planned and
 * shared by every pair the index takes part in; heapkeyspace is looked up on
 * first use (-1 until then) because it opens the index.  So is the range of
 * sortcol values the stream holds (probe_range).
 */
typedef struct IndexCandidate
{
	IndexOptInfo *index;
	bool		usable;
	List	   *clauses;
	List	   *exprs;
	Relids		required_outer;
	int			sortpos;
	int			heapkeyspace;
	int			range_known;	/* -1 not probed yet, 0 cannot be probed */
	bool		range_empty;	/* the stream holds no entries */
	int64		range_lo;
	int64		range_hi;
} IndexCandidate;

/* leapfrog.c: settings */
extern bool intersect_enabled;
extern bool intersect_force;
extern int	intersect_skip_after;

/* planner.c */
extern void lf_planner_init(void);

/* costsize.c */
extern double lf_index_entries(PlannerInfo *root, Index rti,
							   IndexOptInfo *index,
							   IndexCandidate *candidate);
extern double lf_sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel,
								   Index rti, AttrNumber sort_attno);
extern double lf_outer_index_correlation(PlannerInfo *root, Index rti,
										 IndexOptInfo *outer);
extern void lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
								   RangeTblEntry *rte, AttrNumber sort_attno,
								   IndexCandidate *outer_candidate,
								   IndexCandidate *inner_candidate,
								   double outer_entries, double inner_entries,
								   double group_size, double correlation,
								   double *outer_read, double *inner_read);

/* indexstream.c */
extern int64 lf_datum_get_int64(Datum value, Oid type);
extern void lf_rescan_with_keys(IndexScanDesc scan, EqualityKeys *keys,
								bool descending, int64 bound);
extern int64 lf_no_bound(bool descending);
extern bool lf_read_index_entry(IndexScanDesc scan, ScanDirection dir,
								int attno, int64 *value, ItemPointer tid,
								int64 *entries_read);

/* executor.c */
extern const CustomScanMethods lf_scan_methods;

#endif							/* LEAPFROG_H */
