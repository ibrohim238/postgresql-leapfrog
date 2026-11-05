# Design notes

Why the code does what it does, where the reason is not in the code. Read
the README first — [How Index Merge Intersect works](../README.md#how-index-merge-intersect-works),
[Cost model](../README.md#cost-model), [Settings](../README.md#settings),
[Loading the library](../README.md#loading-the-library) — and
[compat.md](compat.md) for version shims; this file does not repeat them.

## Planner

`planner.c`, entry `intersect_set_rel_pathlist`.

**Sort column**: the first query pathkey, when its equivalence class has a
plain column of this relation. The member iterator also shows a partition's
child members. A member nulled by an outer join does not count. `RelabelType`
is looked through everywhere: a `varchar` column compared with `texteq` is
`(col)::text`, a domain column is relabeled to its base type.

**Equalities** on the key columns before the sort column must be usable as an
Index Cond: an equality operator of the column's btree family, the index
collation equal to the clause's (unless the column has none), and
`restriction_is_securely_promotable`, since a scan key sees rows that row
security hides. Values come from restrictions (constants or Var-free
non-volatile expressions; a NULL constant matches nothing), join clauses, and
equivalence classes, where a mergejoinable join clause lives instead of
`joininfo`. A join value parameterizes the path.

**Usable index**: the sort column has the pathkey's opfamily, opclass input
type and collation, so all streams compare alike, and its NULL placement in
the scan direction matches the query's unless NULLs are left out. It must be
in the heapkeyspace format (duplicates ordered by TID; an old `pg_upgrade`d
index needs `REINDEX`). That check opens the index, so it runs last.

**NULLs of the sort column** are left out (`notnull`) when `notnullattnums`
has the column (not `attnotnull`: `NOT VALID` sets it with NULLs present) or a
strict restriction rejects NULL; join clauses do not count, as an
unparameterized path is offered too. Then every scan has an `IS NOT NULL` key
and NULL entries are dropped as well: under `NOT NULL` an index can still hold
dead NULL entries (a NULL updated away before `SET NOT NULL`), and a backward
scan reads them first, derailing the merge. Otherwise NULL is one more merge
value in the query's order. A skip bound on a value excludes NULLs, so when
they come after the values a stream that runs out under a bound rescans for
them (`bounded`, `nulls_ahead`).

**Search** (`search_intersection`, see README), additionally:

- Both the cheapest set and the one quickest to its first row are offered: a
  stream that lowers the total can add a first group that a `LIMIT` pays for.
- Below `leapfrog.min_indexes` nothing is offered, and the first set to reach
  it is kept whatever its cost, so tests can run a larger set.
- Pruning: a stream saves at most the set's heap fetches (`fetch_cost`) and
  adds at least a descent and a leaf page (`lf_stream_min_cost`); when that
  cannot beat the cheapest set it is neither costed nor probed. This ignores
  what a narrower range overlap could save on the other streams.
- Pairs with the first stream are tried only when an MCV or dependencies
  object covers two condition columns: only then can an estimate depart from
  the product of the conditions, so that a large index added last restricts
  most.
- The plain pass leaves out candidates needing a parameter, so the plain set
  has its own chance; a parameterized pass follows when such candidates exist.

**Outer stream**: the densest one without a predicate. Inner streams are held
in memory value by value, and an outer predicate would stay in the Filter.

**work_mem at plan time**: a set is dropped when the inner TID groups of an
average value (entries / ndistinct × 6 bytes) exceed `work_mem`. The executor
enforces the limit itself, so `leapfrog.force` skips the check.

**leapfrog.force** multiplies both costs by 1e-12 instead of zeroing them:
`add_path` compares by ratio, so the sets still compete among themselves. The
path can still lose on `disabled_nodes` or an impossible parameterization.

**Filter** (`lf_node_quals`, charged by the cost model too). Stream
equalities are dropped (scan keys, rechecked under EvalPlanQual). Clauses
implied by an inner predicate are dropped except for a target relation of
`UPDATE`/`DELETE`/`FOR UPDATE`, as in `check_index_predicates`. Clauses
implied by the outer predicate always stay: the node does not keep that
predicate, so only the Filter rechecks it (`leapfrog_outer_partial`).

**Plan.** The core does not copy a path before `PlanCustomPath`, so the
`IntersectPlanInfo` in `IntersectPath` survives; layout rules are in
CONTRIBUTING.md. Index OIDs need no `relationOids` entry: an index change
invalidates its table's relcache, as for an Index Scan. A partition is
planned on its own and its sorted path goes into the parent's MergeAppend.

## Cost model

`costsize.c`, entry `lf_cost_intersect_path`; formulas in the README.

**Heap correlation**: that of an Index Scan on the outer index, as
`btcostestimate` has it (leading column, × 0.75 if multicolumn). With the
leading columns fixed the rows may be more correlated, but that Index Scan
reads the same rows in the same order with this estimate; a better one would
let the node win on pages both plans read alike.

**Distinct values** come from column statistics, not `estimate_num_groups`,
whose clamp to the row estimate would make the groups of a unique column
hundreds of entries instead of one.

**Merge reads** (`merge_read_cost`). A stream has to reach only the values
every sparser stream agrees on. With independent streams these are the
sparsest stream's entries, thinned by each further stream's share of the
table's rows. With matches spread evenly, a stream has entries/values entries
between two such values: up to `leapfrog.skip_after` are read, and a gap
longer by more than two leaf pages costs a descent plus the leaf it lands on.
Shorter gaps are read through, as the executor backs off from short skips.

**Overlap** (`stream_overlap`). Each stream is assumed to follow the table's
distribution of the sort column within its own probed range, which turns the
planner's estimate (conditions independent over the table) into one with them
independent inside the overlap:

    rows' = rows × Π share_i / table_share^(nstreams − 1)

The ranges hold values only; NULLs are one more group, counted in the streams
that can hold them (a predicate may imply `IS NOT NULL`) and, when all can, in
the table's share.

**Statistics** (`SortStats`) are read once per relation and planning; every
`scalarineqsel` would read and detoast them again. They serve only a query
sorting in the column's default operator and collation; otherwise, and inside
a single bin of a non-integer type, the selectivity functions answer
(`range fallbacks` in `leapfrog.trace_planner`). `int4`/`int8` interpolate
within a bin, other types take its middle.

**Probes** (`probe_range`, `stream_holds_group`) need constant equality
values, read under `SnapshotAny` because the merge reads dead entries too (a
dead end entry only widens the range), and are cached per candidate.

**Startup**: `max(run / (matches + 1), min(first_group, run))`: no row comes
before the inner streams have read the first value's whole group.

**Path rows** are the matches: a `Limit` above takes limit/rows of the run,
right only when rows counts what the node returns.

## Executor

`executor.c`, `indexstream.c`.

**Common value** (`find_common_value`). One stream holds the candidate and
the others catch up in turn, sparsest first. Reaching it confirms it; passing
it makes a new candidate and restarts the turns from the sparsest stream. A
dense stream thus reaches only values all sparser ones agree on and skips the
rest in one descent; round-robin turns would read nearly all its entries. The
candidate's stream does not move meanwhile, so its value (pointing into that
scan's index tuple) stays valid.

**Skip-ahead.** After its threshold of entries without catching up, a stream
rescans with `sortcol >= candidate` (`<=` descending); the entries skipped
cannot match, as the candidate's stream has passed every smaller value. The
bound is copied into `bound_cxt`: nbtree uses it until the next rescan, while
the candidate's stream moves on. `check_landing` adapts the threshold: a skip
landing on the leaf it left or the next one saved less than its descent and
doubles it (up to 64 × `leapfrog.skip_after`); a longer one halves it back.
The start, `INTERSECT_SKIP_AFTER = 64`: a re-descent costs `tree_height`
buffer accesses plus a scan restart and a leaf holds about 400 `int8`
entries, so a skip pays only past the next leaf; 16 and 32 measured within
5 % of 64.

**TID groups.** Matching by heap TID keeps the merge right for a non-unique
sort column and for dead versions in the index. The TIDs of a value are not
in a usable order on both sides (a backward scan returns posting-list TIDs
ascending), so each inner stream's entries of the value are collected into a
sorted array and the outer entries looked up by binary search. Each array is
capped at `work_mem / 6 / (nstreams − 1)` entries, grown by doubling from 16.

**Overflow.** A group past its cap is dropped for that value: the rest of its
entries are skipped, every outer entry of the value counts as a match, and
the row is checked against that stream's equalities and predicate before the
Filter, so the fallback does not depend on the Filter. The check needs the
group's state, so the heap queue is drained first.

**Heap fetch**: `index_fetch_heap` repeated while `xs_heap_continue`, as
`index_getnext_slot` does, since a HOT chain may hold several visible members
under a non-MVCC snapshot. `kill_prior_tuple` applies to the scan's current
entry, so it is cleared when a queued TID is fetched after the scan moved on.

**Heap prefetch queue**: only with a Filter, an MVCC snapshot (a queued TID
is safe only then), the heap AM (a TID's block is a main-fork page) and
`leapfrog.prefetch`. Matches are queued with their heap pages prefetched,
then fetched in order. The target length starts at 1 and is revised every 16
fetches: it doubles while most fetches return no row and halves otherwise, up
to the tablespace's `effective_io_concurrency`, at most 32. Prefetching pays
for wasted pages; reading ahead past a `LIMIT` does not, so without a Filter
it stays 1. The queue is drained after 4096 entries without a match (a skip
counts 256), as a `LIMIT` may not need the stretch ahead. Index leaves: on
reaching a leaf a stream prefetches the next one unless nbtree knows the scan
ends there.

**Equality values** are evaluated once per rescan and copied into
`values_cxt`: they come from per-tuple memory the next outer row resets, and a
`text` or `uuid` scan key must outlive it. A NULL value means no rows.

**End of the merge.** When a stream runs out the others still pin a leaf
(`xs_want_itup`, as in an Index Only Scan); VACUUM would wait on it while an
exhausted cursor stays open, so the scans are reset.

**EvalPlanQual**: `intersect_recheck` re-evaluates what the streams guaranteed
by construction, as an Index Scan rechecks `indexqualorig`: every stream's
equalities and inner predicates on the new version; `ExecScan` then applies
the Filter. It runs on a planstate copy whose scan never started, so it
evaluates the equality values itself.

**EXPLAIN**: stream time and buffers are clocked on descents and leaf steps
only. Timer flags are read at scan start: instrumentation is allocated after
`BeginCustomScan`. Counters are summed over rescans; text shows them per loop.

## Settings and constants

User settings are in the README. Compile-time constants:

| Constant | Value | File | Meaning |
|---|---|---|---|
| `INTERSECT_MAX_STREAMS` | 16 | `leapfrog.h` | upper bound of `leapfrog.max_indexes` |
| `INTERSECT_SKIP_AFTER` | 64 | `leapfrog.c` | default `leapfrog.skip_after` |
| `INTERSECT_FORCE_SCALE` | 1e-12 | `planner.c` | cost factor under `leapfrog.force` |
| `HEAP_QUEUE_MAX` | 32 | `executor.c` | most matches queued ahead |
| `HEAP_QUEUE_MAX_WALK` | 4096 | `executor.c` | entries without a match before draining |
| `HEAP_QUEUE_SKIP_WALK` | 256 | `executor.c` | what a skip counts toward that |
| `HEAP_QUEUE_WINDOW` | 16 | `executor.c` | fetches between target revisions |

`leapfrog.require_node` is checked in a `planner_hook` on the final plan;
subplans and CTEs live in `PlannedStmt.subplans`, outside the tree.
