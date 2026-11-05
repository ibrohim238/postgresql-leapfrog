/*-------------------------------------------------------------------------
 *
 * leapfrog.h
 *	  Declarations shared by the parts of the Index Merge Intersect custom
 *	  scan:
 *
 *	  compat.h		shims for the PostgreSQL major versions
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
#include "executor/instrument.h"
#include "nodes/execnodes.h"
#include "nodes/extensible.h"
#include "nodes/pathnodes.h"
#include "utils/sortsupport.h"

#include "compat.h"

#define INTERSECT_NAME "Index Merge Intersect"

/* The most indexes one node may combine (leapfrog.max_indexes). */
#define INTERSECT_MAX_STREAMS 16

/*
 * What the plan of one set of streams carries from the planner to the
 * executor.  The path keeps it as a struct (IntersectPath in planner.c),
 * except keys and pred, which it keeps in custom_private for
 * reparameterize_path_by_child until intersect_plan_path.  form_plan_info
 * turns it into the plan's custom_private and custom_exprs and
 * lf_deform_plan_info back, and no other code knows the list layout.
 * The expression lists go into custom_exprs, where createplan.c turns
 * outer-relation Vars into nestloop params and setrefs.c fixes up the rest.
 * Stream 0 is the outer index, whose entries are fetched from the heap.
 */
typedef struct IntersectStreamInfo
{
	Oid			indexoid;
	int			sortpos;		/* position of sortcol among the key columns */
	double		reads;			/* entries the cost model expects to read;
								 * EXPLAIN VERBOSE */
	List	   *operators;		/* OIDs: equality operator per key */
	List	   *collations;		/* OIDs: its collation per key */
	bool		backward;		/* the index reads the query's order backward */
	int			rank;			/* its turn in the merge, sparsest first */
	List	   *keys;			/* value expressions of the equalities */
	List	   *pred;			/* predicate of a partial inner index */
} IntersectStreamInfo;

typedef struct IntersectPlanInfo
{
	bool		descending;
	Oid			sort_type;		/* input type of the index opclass */
	Oid			sort_opfamily;
	Oid			sort_collation;
	bool		nulls_first;
	bool		notnull;
	int			nstreams;
	IntersectStreamInfo streams[FLEXIBLE_ARRAY_MEMBER];
} IntersectPlanInfo;

#define IntersectPlanInfoSize(nstreams) \
	(offsetof(IntersectPlanInfo, streams) + \
	 (nstreams) * sizeof(IntersectStreamInfo))

/*
 * The equality conditions on the leading columns of one index.  attnos are
 * the heap columns, for the EvalPlanQual recheck and the overflow fallback;
 * operators are of the column's btree family, with the column on the left.
 * The values may be of any type.  The bound on the sort column compares in
 * the type and collation the query sorts in, with the operator of the
 * pathkey's direction: nbtree applies it to a DESC index column itself.
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
 * Instrumentation of one index stream under EXPLAIN ANALYZE: the time and
 * buffers of its descents and of the reads that step to another leaf page,
 * where the page reads happen.  Clocked only there, not on every entry.
 */
typedef struct StreamInstr
{
	bool		timer;
	bool		bufusage;
	instr_time	time;
	BufferUsage buffers;
	int64		prefetches;		/* leaf pages asked for ahead */
} StreamInstr;

typedef struct StreamClock
{
	instr_time	start;
	BufferUsage buffers;
} StreamClock;

static inline void
lf_instr_start(const StreamInstr *instr, StreamClock *clock)
{
	if (instr->timer)
		INSTR_TIME_SET_CURRENT(clock->start);
	if (instr->bufusage)
		clock->buffers = pgBufferUsage;
}

static inline void
lf_instr_stop(StreamInstr *instr, const StreamClock *clock)
{
	if (instr->timer)
	{
		instr_time	now;

		INSTR_TIME_SET_CURRENT(now);

		/*
		 * lf_instr_start set clock->start under the same instr->timer, which
		 * nothing changes after the scan begins; clang-tidy's analyzer
		 * assumes the calls between the two may.
		 */
		/* NOLINTNEXTLINE(clang-analyzer-core.UndefinedBinaryOperatorResult) */
		INSTR_TIME_ACCUM_DIFF(instr->time, now, clock->start);
	}
	if (instr->bufusage)
		BufferUsageAccumDiff(&instr->buffers, &pgBufferUsage, &clock->buffers);
}

/*
 * The statistics of the sort column, read once per relation and planning:
 * each scalarineqsel would read and detoast them anew.  usable is false when
 * they cannot answer in the query's order; the selectivity functions do then.
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
	int		   *mcv_order;		/* positions in mcv, by ascending value */
	double		mcv_total;		/* share of the rows the mcv stand for */
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
	bool		notnull;		/* NULLs left out: none live, or a strict
								 * restriction drops them */
	double		null_frac;		/* share of NULLs, -1 until looked up */
	bool		range_ssup_ready;
	SortSupportData range_ssup;
	SortStats  *stats;			/* NULL until looked up */
} SortColumn;

/*
 * Index candidate for a stream of the intersection, built once per index and
 * shared by every stream set it takes part in: equality clauses of the columns
 * before sortcol, the value expressions compared against, the outer rels they
 * refer to, and sortcol's position among the key columns.  heapkeyspace is
 * looked up on first use (-1 until then) because it opens the index; so is
 * the range of sortcol values (probe_range).
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
	int			holds_nulls;	/* NULLs of sortcol can be in the index, -1
								 * until looked up */
	List	   *group_probes;	/* GroupProbe: values looked up in the index */
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
extern bool intersect_prefetch;
extern PlannerTrace lf_trace;

/* planner.c */
extern void lf_planner_init(void);
extern List *lf_node_quals(PlannerInfo *root, RelOptInfo *rel,
						   IndexOptInfo **indexes, List **exprs, int nstreams,
						   List *clauses);
extern IntersectPlanInfo *lf_deform_plan_info(CustomScan *cscan);

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
								int64 *entries_read, StreamInstr *instr);

/* executor.c */
extern const CustomScanMethods lf_scan_methods;

#endif							/* LEAPFROG_H */
