# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Intersection of two ordinary B-tree indexes. The inner side is now any
  `(j1, …, jM, sortcol, …)` index with an equality on every `jI`, partial or
  not; an ordinary index needs at least one equality column the outer index
  does not have. `(customer_id, id)` and `(product_id, id)` serve
  `customer_id = $1 AND product_id = $2 ORDER BY id LIMIT n`. The inner
  equalities are scan keys, are rechecked under EvalPlanQual, and are checked
  on the row in the overflow fallback. Tests `leapfrog_btree_pair` (regression
  and isolation); both fail without the inner checks.
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
