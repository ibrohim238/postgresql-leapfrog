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
#include "access/tableam.h"
#include "nodes/execnodes.h"
#include "nodes/extensible.h"
#include "nodes/pathnodes.h"
#include "utils/sortsupport.h"

#define INTERSECT_NAME "Index Merge Intersect"

/* PostgreSQL 19 passes table AM scan options to index_beginscan. */
#if PG_VERSION_NUM >= 190000
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0, SO_NONE)
#else
#define lf_index_beginscan(heap, index, snapshot, nkeys) \
	index_beginscan(heap, index, snapshot, NULL, nkeys, 0)
#endif

/* The most indexes one node may combine (leapfrog.max_indexes). */
#define INTERSECT_MAX_STREAMS 16

/*
 * Layout of CustomPath.custom_private: the scan direction, the number of
 * streams, the sort column's type, operator family and collation, and whether
 * its NULLs sort first and whether it can hold any, then
 * STREAM_PRIVATE_COUNT Consts per stream, then two expression
 * lists per stream (the value expressions of its equalities and, for a
 * partial index, its predicate).  The plan keeps the Consts in
 * custom_private and moves the expression lists to custom_exprs.  Stream 0
 * is the outer index, whose entries are fetched from the heap.
 */
#define PRIVATE_DESCENDING		0
#define PRIVATE_NSTREAMS		1
#define PRIVATE_SORT_TYPE		2	/* input type of the index opclass */
#define PRIVATE_SORT_OPFAMILY	3
#define PRIVATE_SORT_COLLATION	4
#define PRIVATE_SORT_NULLS_FIRST 5
#define PRIVATE_SORT_NOTNULL	6
#define PRIVATE_COUNT			7
#define STREAM_PRIVATE_INDEX	0	/* index OID */
#define STREAM_PRIVATE_SORTPOS	1	/* position of sortcol among the key
									 * columns */
#define STREAM_PRIVATE_ESTIMATE 2	/* entries the cost model expects to read;
									 * EXPLAIN VERBOSE */
#define STREAM_PRIVATE_OPERATORS 3	/* OID list: equality operator per key */
#define STREAM_PRIVATE_COLLATIONS 4 /* OID list: its collation per key */
#define STREAM_PRIVATE_BACKWARD 5	/* the index reads the query's order
									 * backward */
#define STREAM_PRIVATE_RANK		6	/* its turn in the merge, sparsest first */
#define STREAM_PRIVATE_COUNT	7
#define STREAM_EXPRS_KEYS		0
#define STREAM_EXPRS_PRED		1
#define STREAM_EXPRS_COUNT		2

/*
 * The equality conditions on the leading columns of one index: the value
 * expressions, their values for the current (re)scan, the heap columns they
 * apply to (for the EvalPlanQual recheck and the overflow fallback), and
 * for each the equality operator of the column's btree family with the
 * column on the left, the collation and what a scan key needs.  The values
 * may be of any type.  The bound on the sort column compares in the type and
 * collation the query sorts in, with the operator of the pathkey's direction:
 * nbtree applies it to a DESC index column itself.
 */
typedef struct EqualityKeys
{
	int			nequal;
	ExprState  *exprs[INDEX_MAX_KEYS];
	Oid			types[INDEX_MAX_KEYS];
	Datum		values[INDEX_MAX_KEYS];
	AttrNumber	attnos[INDEX_MAX_KEYS];
	Oid			operators[INDEX_MAX_KEYS];
	Oid			collations[INDEX_MAX_KEYS];
	Oid			subtypes[INDEX_MAX_KEYS];	/* right input of the operator */
	RegProcedure procs[INDEX_MAX_KEYS];
	FmgrInfo	eqfns[INDEX_MAX_KEYS];	/* for checks on the row */
	Oid			sort_type;
	Oid			sort_collation;
	StrategyNumber bound_strategy;	/* >= ascending, <= descending */
	RegProcedure bound_proc;
} EqualityKeys;

/* What lf_rescan_with_keys asks of the sort column besides the equalities. */
typedef enum SortBound
{
	SORT_BOUND_NONE,
	SORT_BOUND_VALUE,			/* the value or further in query order */
	SORT_BOUND_NOT_NULL,		/* any value but NULL */
	SORT_BOUND_NULL,			/* NULLs only */
} SortBound;

/*
 * The statistics of the sort column, read once per relation and planning: the
 * share of a range is asked for many times, and each scalarineqsel reads and
 * detoasts them anew.  usable is false when they cannot answer in the query's
 * order; the selectivity functions do then.
 */
typedef struct SortStats
{
	bool		usable;
	bool		interpolate;	/* values are integers: within a bin, by value */
	bool		signed64;		/* else int32 */
	Datum	   *hist;
	int			nhist;
	Datum	   *mcv;
	float4	   *mcv_freq;
	int			nmcv;
	double		hist_frac;		/* share of the rows the histogram stands for */
} SortStats;

/*
 * The column the query sorts by, as the planner found it.  type is the input
 * type of the operator class (text for a varchar column, anyarray for an
 * array).  range_ssup compares in ascending order for the cost model's range
 * probes, prepared on first use.
 */
typedef struct SortColumn
{
	AttrNumber	attno;
	Oid			type;
	Oid			opfamily;
	Oid			collation;
	bool		descending;
	bool		nulls_first;
	bool		notnull;		/* no NULLs in the live rows */
	double		null_frac;		/* share of NULLs, -1 until looked up */
	bool		range_ssup_ready;
	SortSupportData range_ssup;
	SortStats  *stats;			/* NULL until looked up */
} SortColumn;

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
	List	   *operators;		/* OIDs: equality operator per column */
	List	   *collations;		/* OIDs: its collation per column */
	Relids		required_outer;
	int			sortpos;
	bool		backward;		/* scan direction giving the query's order */
	double		entries;		/* entries matching the equalities */
	int			heapkeyspace;
	int			range_known;	/* -1 not probed yet, 0 cannot be probed */
	bool		range_empty;	/* the stream holds no entries */
	Datum		range_lo;		/* in planner memory */
	Datum		range_hi;
	Selectivity range_sel;		/* table share inside the range, -1 until
								 * computed */
	double		correlation;	/* of the leading column, -2 until looked up */
} IndexCandidate;

/* What one planning did, for leapfrog.trace_planner. */
typedef struct PlannerTrace
{
	int			candidates;
	int			sets;			/* sets of streams costed */
	int			range_scans;	/* index scans of probe_range */
	int			stat_loads;		/* reads of the sort column's statistics */
	int			range_fallbacks;	/* shares left to the selectivity
									 * functions */
	int			correlations;	/* correlations looked up */
	int			pruned;			/* candidates that could not pay for
								 * themselves */
} PlannerTrace;

/* leapfrog.c: settings */
extern bool intersect_enabled;
extern bool intersect_force;
extern int	intersect_skip_after;
extern int	intersect_max_streams;
extern int	intersect_min_streams;
extern bool intersect_trace_planner;
extern PlannerTrace lf_trace;

/* planner.c */
extern void lf_planner_init(void);
extern List *lf_node_quals(PlannerInfo *root, RelOptInfo *rel,
						   IndexOptInfo **indexes, List **exprs, int nstreams,
						   List *clauses);

/* costsize.c */
extern double lf_index_entries(PlannerInfo *root, Index rti,
							   IndexCandidate *candidate);
extern double lf_sortcol_ndistinct(PlannerInfo *root, RelOptInfo *rel,
								   Index rti, AttrNumber sort_attno);
extern double lf_outer_index_correlation(PlannerInfo *root, Index rti,
										 IndexOptInfo *outer);
extern void lf_cost_intersect_path(CustomPath *cpath, PlannerInfo *root,
								   RangeTblEntry *rte, SortColumn *sort,
								   IndexCandidate **streams, int nstreams,
								   double ndistinct, double correlation,
								   double *reads, int *ranks, Cost *fetch_cost);
extern Cost lf_stream_min_cost(IndexOptInfo *index);

/* indexstream.c */
extern void lf_init_key_procs(EqualityKeys *keys, Oid sort_type, Oid opfamily,
							  Oid collation, bool descending);
extern void lf_rescan_with_keys(IndexScanDesc scan, EqualityKeys *keys,
								SortBound kind, Datum bound);
extern bool lf_scan_leaf_position(IndexScanDesc scan, bool backward,
								  BlockNumber *page, BlockNumber *next_page);
extern bool lf_read_index_entry(IndexScanDesc scan, ScanDirection dir,
								int attno, bool skip_nulls, Datum *value,
								bool *isnull, ItemPointer tid,
								int64 *entries_read);

/* executor.c */
extern const CustomScanMethods lf_scan_methods;

#endif							/* LEAPFROG_H */
