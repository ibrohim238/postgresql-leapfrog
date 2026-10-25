# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [SemVer](https://semver.org/).

## [Unreleased]

### Fixed

- The benchmark scripts ran in `PGDATABASE` and dropped tables with common
  names there (`orders` in `run.sh`, `write_bench.sh` and `schema.sql`), so
  a run against a database with real data could destroy it. They now run in
  a database of their own, `BENCH_DB` (default `leapfrog_bench`), created
  with a marking comment; a database without the mark is refused
  (`tests/performance/bench_db.sh`). Data left by earlier runs in
  `PGDATABASE` (`bench_types` and the like) is not moved. `make bench-smoke`
  dropped and recreated `leapfrog_bench_smoke` whatever it held; now only
  when it carries the mark, one `bench-smoke` at a time. It checks that
  `run.sh` leaves the `orders` table of `PGDATABASE` alone and refuses a
  `BENCH_DB` without the mark (with the old `run.sh` it fails: the refused
  run went ahead).
- Two benchmarks started at once in one database dropped and recreated
  each other's tables. A run now holds an advisory lock in `BENCH_DB`,
  through a `psql` session that ends with the script, also when it is
  killed, and a second run is refused. The session is recognised by a
  random token in its application name, not by the shell's PID, which
  repeats across containers (PID 1 in each). `make bench-smoke` checks that
  `run.sh` is refused while the lock is held (without the lock it fails:
  the run went ahead).

## [0.0.3] — 2026-10-25

Still experimental. The shared library changes; the SQL functions do not:
`ALTER EXTENSION leapfrog UPDATE` after installing the new files (the update
script `leapfrog--0.0.2--0.0.3.sql` is empty). Reload or restart the backends
so that they load the new library.

### Fixed

- `make bench-smoke` checked the last directory under
  `tests/performance/results` by name, so an earlier `write-…`, `skip-…` or
  `cost-…` run, which sorts after the timestamps, made it fail; and every
  benchmark script reused an existing output directory (`mkdir -p`), so
  two runs started in the same second wrote into one. The scripts now take
  `BENCH_OUT` and refuse an existing directory; `bench-smoke` runs in a
  temporary directory of its own and checks that a second run into it is
  refused and leaves the results unchanged (with `mkdir -p` restored it
  fails).
- A sort column relabeled in the `ORDER BY` equivalence class, as a domain
  column is to its base type, was never found: the search skipped every
  member that was not a bare `Var`, and `pathkey_is_column` cast the
  member itself to `Var` after looking through the relabeling, reading
  `varnullingrels` from a `RelabelType`. Both now look through to the
  `Var`, and the sort column may be a domain over `smallint`, `integer` or
  `bigint`. Test in `leapfrog_types`; with the old cast the node is not
  chosen.
- Redundant index sets. A stream was checked only for adding something to
  the inner streams, never to the outer one, and the existing streams were
  never checked against a new one. So `(membership_id, id)` paired with
  `(membership_id, id) WHERE deleted_at IS NULL`, where the partial index
  alone enforces both conditions, and `(id) WHERE deleted_at IS NULL` could
  join an outer index with the same predicate. Now every stream of a set,
  the outer one included, must add an equality column no other stream has
  or a predicate the other streams' equalities and predicates do not imply
  together (`predicate_implied_by`; `kind = 2` implies `WHERE kind = 2`).
  Plans change where a pair was redundant: `(owner_id, id)` ×
  `(owner_id, kind_id, id)` becomes `(owner_id, kind_id, id)` × the live
  index, which enforces `deleted_at` instead of filtering it. Tests in
  `leapfrog_nway`, `leapfrog_btree_pair`, `leapfrog_basic`,
  `leapfrog_parameters`; checking only the new stream fails all four.

### Added

- Extension update script from 0.0.2; `leapfrog_setup` checks the update path.
- `tests/performance/types_bench.sh` and `types_compare.sh`: equality types
  on 1M rows per build, compared against 0.0.2 in BENCHMARKS.md.
- Equality values computed from parameters, from the other side of a join
  or from `LATERAL` columns (`status = $1 || $2`,
  `t.status = lower(p.status)`): any non-volatile expression without the
  scanned relation's columns, as `match_clause_to_indexcol` accepts for an
  `Index Cond`, where only a bare constant, parameter or column was taken.
  It is evaluated once per rescan. Tests in `leapfrog_types`; with the old
  check those queries get no node. Validation tests for the equality types:
  long `text` values compressed in the index, HOT updates, and in
  `leapfrog_memory` 40,000 rescans with 3 kB values, whose copies are freed
  per rescan (without that the peak grows past 32 MB).
- Equality columns of any type with a B-tree operator family: `uuid`,
  `text`, `varchar`, `smallint`, `integer`, `timestamptz` and so on, where
  only `bigint` was accepted. The equality operator is looked up in the
  index column's family as for an `Index Cond` (cross-type `varchar = text`,
  `smallint = bigint` included) and the index column's collation must match
  the condition's. Values of by-reference types are copied out of the
  per-tuple memory; EvalPlanQual and the overflow fallback recheck the row
  with the same operator and collation. Sort columns may be `smallint` or
  `integer` as well as `bigint`. Tests in `leapfrog_types` (regression and
  isolation); `leapfrog_basic` now expects `integer` columns to be used and
  a `numeric` sort column to be rejected.
- N-way intersection: a node combines up to `leapfrog.max_indexes` (default
  4, at most 16) indexes instead of two. Every stream after the outer index
  is an inner one with its own TID group; the merge advances every stream
  lagging behind the frontmost value, with skip-ahead per stream, and matches
  an outer entry only when every group holds its TID. The overflow fallback,
  the EvalPlanQual recheck and the `Filter` cover every stream. The planner
  offers every pair as before and then, from the cheapest pair, adds one
  stream at a time while it lowers the estimated cost, so a third index is
  used only where fetching the rows the pair leaves costs more than reading
  it. `EXPLAIN` names the further streams `Inner Index 2`, `Inner Index 3`
  … with their counters suffixed alike; a two-index node prints what it did.
  `leapfrog.min_indexes` (developer setting) requires a set size for tests.
  Tests `leapfrog_nway` (regression: 3–5 streams, planner choice, generic
  plans, `LATERAL`, non-unique sort column, two overflowing groups, rows
  moving between streams, `FOR UPDATE`; isolation: EvalPlanQual on the
  second and third stream).
- Cost model: the heap fetches are the rows the streams agree on, estimated
  from the stream conditions alone, and the node's qual is charged per
  fetched row; the result rows stay the planner's estimate. Before, a
  two-index node with a third condition in its `Filter` was costed as if it
  fetched only the result rows.
- Cost model: the share of the merge spent before the first match is part of
  the startup cost and no longer also of the run, where it was counted
  twice (total costs of two-index plans fall by up to 8 %).
- Planner: the range share of each candidate's probed sort range is computed
  once; with 6 matching equalities planning took 5.2 ms (10 indexes) and
  2.7 ms (50) after the range probe, now 0.9 and 1.5 ms with up to four
  streams.
- `EXPLAIN (VERBOSE)` shows `Outer Entries Estimated` and `Inner Entries
  Estimated`: the entries the cost model expected each side to read, next to
  the `ANALYZE` counters of what it read. `cost_bench.sh` records both, the
  ratio, the skips and the buffers of every query, so that a miss can be
  traced to the entries estimate or to the cost per entry.
- `cost_bench.sh`: a second ordinary index `(product_id, id)` and two pair
  queries, with and without a third condition.

### Changed

- Cost model: a TID comparison in the group costs 0.1 × `cpu_operator_cost`,
  as `cost_bitmap_tree_node` charges the per-TID work of a bitmap, instead of
  a full `cpu_operator_cost` (the rate of an operator call through the
  function manager). Calibrated with `cost_bench.sh`: on two ordinary indexes
  the node and `BitmapAnd` touch the same 118 buffers and the entries
  estimate is within 6 % of the entries read, yet the node was costed 4 %
  above `BitmapAnd` while running 3× faster. Now the node is chosen for the
  pair queries at both page costs; `cost_bench.sh` misses go from 14 to 10 of
  32 queries at `random_page_cost = 4` and from 17 to 6 at 1.1, with no new
  wrong choice. The 1M-row matrix (no pairs of ordinary indexes) is
  unchanged within noise. In the read mix of `write_bench.sh` the planner
  now picks the node for both pair queries at both page costs (1.2 ms
  against 2.1–3.6 ms stock). Test in `leapfrog_explain`; it fails at the
  old rate.

## [0.0.2] — 2026-10-24

Still experimental. The shared library changes; the SQL functions do not:
`ALTER EXTENSION leapfrog UPDATE` after installing the new files (the update
script `leapfrog--0.0.1--0.0.2.sql` is empty). Reload or restart the backends
so that they load the new library.

### Added

- Extension update script from 0.0.1; `leapfrog_setup` checks the update path.
- `tests/performance/write_bench.sh`: storage, WAL, write throughput and a read
  mix for 12 filter columns, specialised indexes (30) against general ones
  (14), read with and without leapfrog at both page costs.
- README opens with the problem (one index per query shape) and a "Why index
  composition matters" section with the measured storage, write and read
  numbers, including where the specialised indexes read faster; BENCHMARKS is
  rewritten from the final runs. README documents that the installed library
  must not be overwritten in place (verified: it crashes loaded backends, as
  for any C extension).

- Intersection of two ordinary B-tree indexes. The inner side is now any
  `(j1, …, jM, sortcol, …)` index with an equality on every `jI`, partial or
  not; an ordinary index needs at least one equality column the outer index
  does not have. `(customer_id, id)` and `(product_id, id)` serve
  `customer_id = $1 AND product_id = $2 ORDER BY id LIMIT n`. The inner
  equalities are scan keys, are rechecked under EvalPlanQual, and are checked
  on the row in the overflow fallback. Tests `leapfrog_btree_pair` (regression
  and isolation); both fail without the inner checks.
- Adaptive skip-ahead: a scan that has read 1,024 entries in a row without
  catching up with the other side descends its B-tree again straight to the
  other side's value (`index_rescan` with `sortcol >= value`, `<=` backward).
  Shown as `Skips` in `EXPLAIN ANALYZE`; costed per gap in the cost model.
  Test `leapfrog_skip`; a strict bound (`>` instead of `>=`) fails six tests.
- The sort column no longer has to lead some index of the table.
- Under `leapfrog.force` the index pairs compete among themselves by their
  real cost instead of all costing zero.

- `leapfrog_memory` regression test: peak backend memory of the predicate
  fallback; fails by about 200 MB of growth without the per-row context reset.
- Cost model checks in `leapfrog_explain`: heap correlation (set through
  `pg_restore_attribute_stats`), filter cost, tablespace page cost and the
  per-loop cost of a parameterized path; each fails on the cost model of the
  original code.
- Outer join tests in `leapfrog_parameters`: no node on the nullable side of
  a `LEFT`/`FULL JOIN` when ordering by its column.
- `make bench-smoke` (and a CI step): a tiny benchmark run in a database that
  holds a stale `bench_owners()`.
- README example with real data and measured output, compared with the stock
  Index Scan and `BitmapAnd` plans, including the cases where the node does
  not win. The previous example output had been written by hand and could not
  be reproduced (the table had no data). The example runs as the regression
  test `leapfrog_example`.
- README section "Known limitations and planned improvements": the current
  limitations verified against the code and the tests (index pairs, types,
  planner search, executor memory, cost model, test and benchmark coverage)
  and a prioritised roadmap (two ordinary B-tree indexes, cost model,
  adaptive skip-ahead, N-way intersection, planner search, memory,
  concurrency tests, write and storage benchmarks, more types). It replaces
  the separate "Limitations" and "Roadmap" sections.

- Concurrency tests: `leapfrog_outer_partial` (regression and isolation; a
  partial index on the outer side keeps its predicate's conditions in the
  `Filter`, rechecked under EvalPlanQual — a variant dropping them returns a
  concurrently soft-deleted row), `leapfrog_insert_vacuum` (concurrent
  `INSERT`, `VACUUM` with an open cursor) and `leapfrog_overflow_epq`
  (EvalPlanQual through the overflow fallback).

- `docker/cassert.Dockerfile` and a CI job: PostgreSQL 18 built from source
  with `--enable-cassert`, both suites run against it; the job fails on an
  assertion failure or a crashed backend in the server log.
- `tests/performance/planning_bench.sh`: planning time with 10, 20 and 50
  indexes, with and without the extension.

- `leapfrog.skip_after`: developer setting for the starting skip-ahead
  threshold (0 turns skipping off), and `tests/performance/skip_bench.sh`,
  buffers and entries read for thresholds 0–2048 on even and clustered gaps.
- `Short Skips` in `EXPLAIN ANALYZE`.
- Cost model: where the streams meet. With constant equality values the
  planner reads the smallest and the largest sort value of each stream from
  its index (one descent from each end, as `get_actual_variable_range` does),
  charges only the entries inside the overlap of the two ranges and
  estimates the matches there from the sort column's histogram. Disjoint
  ranges cost next to nothing. On `cost_bench.sh` the queries where the node
  was more than 15 % faster but not chosen went from 18 to 11 of 24 at
  `random_page_cost = 4` and from 16 to 10 at 1.1. Tests in
  `leapfrog_explain`; they fail without the probe.
- The node's row estimate is the matches inside the overlap of the two
  streams rather than the relation's estimate, so that a `Limit` above takes
  the right share of the run (test in `leapfrog_explain`: 1,334 actual rows,
  estimated in range instead of the relation's ~667).
- `tests/performance/choices.sql`: planner choices, wrong choices and misses
  of a `run.sh` run; a miss is now counted only where the node beats both the
  planner's choice and the stock plan on `(customer_id, id)`.
- `skip_bench.sh`: `COLD_CMD`, a command run before every measurement (one
  run, no warm-up) to empty the caches, and the blocks read per query.
- `tests/performance/cost_bench.sh`: estimated cost against measured time for
  the node and the stock plan on skewed and correlated data, with misses,
  wrong choices and the cost-to-time bias per query.

### Changed

- `src/leapfrog.c` is split by subsystem: `planner.c`, `costsize.c`,
  `indexstream.c`, `executor.c` and `leapfrog.c` (module entry), with shared
  declarations in `leapfrog.h`. No behaviour change: the regression and
  isolation outputs and the estimated costs of the plans are identical.
- Skip-ahead is adaptive per side: it starts at 64 entries (was a fixed
  1,024); a skip that lands on the leaf page it left or the next one doubles
  the threshold (up to 64×), a longer one halves it back. On 1M rows with
  clustered gaps it reads up to 1.9× fewer buffers than 0.0.1; with evenly
  spread matches 0.2 % more than not skipping, where a fixed 128 read 38 %
  more. The cost model charges a re-descent only for gaps longer than the
  threshold by two leaf pages. Tested in `leapfrog_skip`: without the
  back-off the counters show 74 and 396 skips instead of 2 and 4.
- Planner search: each index is checked once per relation instead of once
  per pair, and the `ndistinct` of the sort column, the outer index
  correlation and the nbtree version (`_bt_metaversion`, which opens the
  index) are looked up once. With 50 indexes and 6 matching equalities the
  planning overhead went from 0.13 ms to 0.02 ms.

### Fixed

- Cost model: the size of a TID group was estimated from
  `estimate_num_groups`, which clamps the number of distinct sort values to
  the query's row estimate. With a unique sort column and a query returning
  81 rows, groups came out 200 entries instead of one: the group cost was
  7.6× too high, and the plan-time `work_mem` check could drop the path
  altogether. The number of distinct values now comes from the column
  statistics (`get_variable_numdistinct`). Test in `leapfrog_overflow`; the
  README example now picks the node at the default `random_page_cost = 4`
  too (798 against 933 for the stock plan; 1.9 ms against 4.3–8.1 ms).
- `leapfrog_overflow` printed counters that depended on autovacuum; its table
  no longer has autovacuum.
- `VACUUM` waited for an open cursor whose node had finished its merge: the
  stream that had not run out kept its leaf page pinned until the scan was
  closed. Both scans now release their pages when the merge ends.
- Cost model: heap fetches were charged with the correlation of the sort
  column, while a stock Index Scan on the outer index, which reads the same
  rows in the same order, is charged with the correlation of its leading
  column. The node got a discount on the same heap pages and was chosen for
  `f = $1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100` at 0.9 ms where
  the stock plan takes 0.13 ms. Now both use btcostestimate's estimate.

### Removed

- The index OIDs are no longer added to the plan's `relationOids`. That was
  listed as a fix in 0.0.1, but there was no bug: creating or dropping an
  index already invalidates cached plans through its table, as for an
  `Index Scan`. Verified by running the plan cache test without it.

## [0.0.1] — 2026-10-24

First public pre-release: the `Index Merge Intersect` node for PostgreSQL 18
as a standalone PGXS extension. Experimental; the API, GUCs and `EXPLAIN`
output may still change.

### Added

- Control file and extension SQL script: `CREATE EXTENSION leapfrog`,
  functions `leapfrog_version()` and `leapfrog_is_loaded()`.
- `PG_MODULE_MAGIC_EXT` with the module name and version.
- Equality conditions are also found through equivalence classes
  (`generate_implied_equalities_for_column`): a join condition
  `a.customer_id = b.customer_id` yields a parameterized path without
  `LATERAL`.
- `int2` constants and parameters (`int82eq`/`int28eq`).
- Regression tests (`sql/`, 7 files) and isolation tests
  (`tests/isolation/`, 5 specs) that compare results with the stock plans
  through `EXCEPT ALL`.
- Benchmark of three indexing strategies (`tests/performance/`), CSV + JSON.
- Dockerfile (multi-stage: build / test / runtime), `compose.yaml` with a
  healthcheck and `test`/`bench` profiles, `tests/run-in-docker.sh`.
- GitHub Actions: build with `-Werror` on gcc and clang, `pgindent` check,
  `make installcheck`, `CREATE EXTENSION` and key-query check, Docker run,
  manual benchmark profile.
- `make pgindent` / `make pgindent-fix`: the core formatter, fetched from
  `REL_18_STABLE`, with the extension's typedefs in `src/typedefs.list`.
- README, CONTRIBUTING, BENCHMARKS, PostgreSQL License.

### Changed

- **Cost model.** Index and heap pages are costed with core functions:
  `get_tablespace_page_costs`, `index_pages_fetched` for parameterized paths
  (`loop_count`), interpolation by the correlation of the sort column as in
  `cost_index`; per-row cost of the qual and the target list. Previously:
  `random_page_cost + pages × seq_page_cost` for indexes and
  `min(rows, pages) × random_page_cost` for the heap, ignoring correlation and
  tablespaces.
- **Plan qual.** Equalities on the outer index columns and conditions implied
  by the inner predicate no longer end up in `Filter` (like `Index Cond` of
  an Index Scan); for the target relation of `UPDATE/DELETE/FOR UPDATE` they
  are kept for EvalPlanQual. Previously the whole `WHERE` was evaluated again
  on every row.
- **EXPLAIN.** `Using intersect: outer,inner` is replaced by two properties,
  `Outer Index` and `Inner Index`, which map cleanly to JSON/YAML/XML.
- `is_heapkeyspace` (which opens the index) is called only for pairs that
  pass every other check, not for every index in `is_usable_btree`.
- `pathkey_is_column` ignores equivalence class members with
  `varnullingrels` (as `get_eclass_for_sort_expr` does when building index
  pathkeys).
- The hook rejects `relkind <> 'r'`, dummy rels and tables without indexes
  before any analysis.

### Fixed

- Dead index entries with a NULL merge column broke the merge: the planner
  accepts the column once it is `NOT NULL`, but entries of rows whose NULL was
  updated away stay in the indexes until VACUUM. In release builds the
  `Assert` was compiled out, the NULL was read as `0`, and a backward scan
  (`ORDER BY … DESC`) read it first and ran the inner side to its end,
  returning no rows. Such entries are now skipped; they are still counted in
  `Outer/Inner Entries Read`.
- A cached plan with the node was not invalidated by `DROP INDEX` of one of
  its indexes: the index OIDs did not reach `PlannerGlobal.relationOids`. They
  are now added in `PlanCustomPath`.
- The predicate check for overflowed groups used `ExecQual` without resetting
  the per-tuple context; with many rejected rows memory accumulated until the
  end of the `ExecScan` call. Replaced with `ExecQualAndReset`.
- A shadowed variable declaration (`-Wshadow=compatible-local`).

[Unreleased]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/ibrohim238/postgresql-leapfrog/releases/tag/v0.0.1
