# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [SemVer](https://semver.org/).

## [Unreleased]

### Added

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

### Changed

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

[Unreleased]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/ibrohim238/postgresql-leapfrog/releases/tag/v0.0.1
