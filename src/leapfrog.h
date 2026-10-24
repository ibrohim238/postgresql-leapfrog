/*-------------------------------------------------------------------------
 *
 * leapfrog.h
 *	  Declarations shared by the parts of the Index Merge Intersect custom
 *	  scan:
 *
 *	  leapfrog.c	module entry point, settings, SQL-callable functions
 *	  planner.c		planner hook: index streams, paths, plans
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

/* The most indexes one node may combine (leapfrog.max_indexes). */
#define INTERSECT_MAX_STREAMS 16

/*
 * Layout of CustomPath.custom_private: the scan direction and the number of
 * streams, then STREAM_PRIVATE_COUNT Consts per stream, then two expression
 * lists per stream (the value expressions of its equalities and, for a
 * partial index, its predicate).  The plan keeps the Consts in
 * custom_private and moves the expression lists to custom_exprs.  Stream 0
 * is the outer index, whose entries are fetched from the heap.
 */
#define PRIVATE_DESCENDING		0
#define PRIVATE_NSTREAMS		1
#define PRIVATE_COUNT			2
#define STREAM_PRIVATE_INDEX	0	/* index OID */
#define STREAM_PRIVATE_SORTPOS	1	/* position of sortcol among the key
									 * columns */
#define STREAM_PRIVATE_ESTIMATE 2	/* entries the cost model expects to read;
									 * EXPLAIN VERBOSE */
#define STREAM_PRIVATE_COUNT	3
#define STREAM_EXPRS_KEYS		0
#define STREAM_EXPRS_PRED		1
#define STREAM_EXPRS_COUNT		2

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
 * Index candidate for a stream of the intersection: equality clauses of the
 * columns before sortcol, the value expressions compared against, the outer
 * rels they refer to, and the position of sortcol among the key columns.
 * Built once per index while the relation's paths are planned and shared by
 * every stream set the index takes part in; heapkeyspace is looked up on
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
	double		entries;		/* entries matching the equalities */
	int			heapkeyspace;
	int			range_known;	/* -1 not probed yet, 0 cannot be probed */
	bool		range_empty;	/* the stream holds no entries */
	int64		range_lo;
	int64		range_hi;
	Selectivity range_sel;		/* table share inside the range, -1 until
								 * computed */
} IndexCandidate;

/* leapfrog.c: settings */
extern bool intersect_enabled;
extern bool intersect_force;
extern int	intersect_skip_after;
extern int	intersect_max_streams;
extern int	intersect_min_streams;

/* planner.c */
extern void lf_planner_init(void);

/* costsize.c */
extern double lf_index_entries(PlannerInfo *root, Index rti,
							   IndexCandidate *candidate);
extern double lf_sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel,
								   Index rti, AttrNumber sort_attno);
extern double lf_outer_index_correlation(PlannerInfo *root, Index rti,
										 IndexOptInfo *outer);
extern void lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
								   RangeTblEntry *rte, AttrNumber sort_attno,
								   IndexCandidate **streams, int nstreams,
								   double ndistinct, double correlation,
								   double *reads);

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
