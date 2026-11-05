# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Tests: `make test-one TEST=name [REPEATS=N] [KIND=isolation]`
  (`tests/scripts/run-one.sh`, after Citus's `run_test.py -r`) runs one regression test or
  isolation spec N times in a scratch database, after `leapfrog_setup`, and stops at the
  first failure with its diff; `make installcheck-rerun` (after TimescaleDB's
  `ci_rerun.sh`) reruns the tests the last `installcheck` failed. CONTRIBUTING.md has a
  "Flaky tests" section on reproducing and fixing them.
- Planner: a nullable sort column counts as `NOT NULL` when a strict condition of the
  relation rejects NULL in it (`val > 0`, `val > $1`, `val IS NOT NULL`, `val = ANY (…)`;
  `find_nonnullable_vars`, after TimescaleDB SkipScan's `check_notnull_skipkey`): no row
  with a NULL there is in the result, so an index serves the order with its NULLs at either
  end, and the streams start past their NULLs and stop at them instead of reading them
  (`IS NOT NULL` scan key). Join clauses do not count. Tests in `leapfrog_nulls`.
- `leapfrog.require_node` (`allow` | `require` | `forbid`, default `allow`), a developer
  setting after TimescaleDB's `timescaledb.debug_require_vector_agg`: a `planner_hook`
  fails a query at plan time when its final plan has no Index Merge Intersect node under
  `require`, or has one under `forbid`, so that a test meant for the node cannot pass
  through a stock plan unnoticed. Test `leapfrog_require`. The isolation sessions that
  run the node set it to `require`, their steps with the stock plan to `forbid`; and
  `lf_check` has a canary after TimescaleDB's `skip_scan` tests: the settings its two
  runs saw must differ.

- Planner: with an MCV list or dependencies covering two columns of the conditions, the
  first stream is priced in a pair with every other index, not only the next by size. The pass by size adds a large index
  to the smaller ones only, so `(customer_id, id)` with `(id) WHERE deleted_at IS NULL`
  was never priced where a `(product_id, id)` was smaller. No change without such
  statistics, where the correlation is unknown, so no more range probes either; test in
  `leapfrog_planner`.

- Heap prefetch: where the node's `Filter` drops more rows than it passes, matches are
  gathered ahead, doubling up to the tablespace's `effective_io_concurrency` and at most 32,
  their heap pages asked for and the rows fetched in the same order; heap tables only.
  Found rows wait for no long stretch: the queue is fetched after 4,096 entries without a
  match. A node without a `Filter`, or whose `Filter`
  passes most rows, still fetches one match at a time, so that a `LIMIT` reads no further
  in the indexes. MVCC snapshots only; under `leapfrog.prefetch`. `EXPLAIN ANALYZE` counts
  the pages as `Heap Prefetches`; test in `leapfrog_heap_prefetch`. At 100M rows, from disk, a query
  fetching 20,012 rows for 11 went from 2.4 s to 1.3 s, ahead of `BitmapAnd`'s 1.5 s; warm,
  no change (BENCHMARKS.md, "Heap prefetch").

- `make installcheck-upgrade`: creates every earlier release still on an update path
  (its install script taken from the release tag) and runs `ALTER EXTENSION leapfrog
  UPDATE`; the result must be the current version, with the objects of a fresh
  `CREATE EXTENSION`, and pass `leapfrog_setup`. Run in CI on PostgreSQL 18; see
  CONTRIBUTING.md.
- `make check-tests` (`tests/scripts/check-tests.sh`, after Citus's
  `check_all_tests_are_run.sh` and TimescaleDB's `check_orphaned_test_output_files.sh`):
  fails when a `.sql` or `.spec` is not in `REGRESS`/`ISOLATION`, a listed name has no
  file, an expected file belongs to no test, or an alternative output `<name>_N.out` is
  identical to `<name>.out` or not explained by a line `-- alternative output
  <name>_N.out: <why>; remove when <condition>` in the test's header comment (Citus's
  rule). The five alternatives have that line now; in `.sql` tests it is echoed into
  their expected files. No server needed.
- `make check-version` (`tests/scripts/check-version.sh`, after TimescaleDB's
  `release_sanity.yml` and Citus's `check_migration_files.sh`, with the control file as the
  source of truth as in pgaudit): `EXTVERSION` equals `default_version`, the install
  script and the update script from the newest release tag exist and are in `DATA`,
  `leapfrog_setup.out` shows the version, and `CHANGELOG.md` has `Unreleased`, the
  version's section once it is newer than the newest tag, and a link per release.
  `RELEASE=1` checks a release: `Unreleased` empty, `## [X] — date`, and the annotated tag
  `vX` on `HEAD` with the message `leapfrog X`. It found the links of 0.0.5 missing at the
  bottom of this file, now added.

### Fixed

- Cost model: the rows fetched from the heap and the entries of a partial index ignored
  extended statistics, as predicates reached `clauselist_selectivity` without a
  `RestrictInfo` and entries took the predicate as independent of the equalities. Tests in
  `leapfrog_planner`. A statistics object must cover plain columns:
  `(deleted_at IS NULL)` as an expression does not match a clause on `deleted_at`.

### Changed

- The regression tests live in `tests/regress/` (`sql/`, `expected/`, and `results/` when
  run), next to the isolation and performance tests, instead of the repository root.
- Planner: the plan's `custom_private` is written and read in one place each,
  `form_plan_info` and `lf_deform_plan_info`, from and into a typed
  `IntersectPlanInfo`; the path keeps the struct (`IntersectPath`) instead of
  the lists, and the positional `PRIVATE_*` / `STREAM_*` offsets are gone. No
  change in plans or results.

- Test servers: `tests/scripts/temp.conf` (`make check`, the cassert image), the Compose
  server and the CI cluster also set `extra_float_digits = 0`, `timezone = 'UTC'`,
  `datestyle = 'ISO, MDY'` and `lc_messages = 'C'`, so that output does not depend on the
  machine's locale or time zone. No expected output changed.
- README shows two measurements only: the list query with rare, scattered matches
  at 100M rows, with the plans, and the write comparison; the rest is in
  BENCHMARKS.md.
- `bitmap_bench.sh` is `uniform_bench.sh`, named after its data.
- `list_bench.sh` runs each scenario separately, with its own exact index and results
  directory; `SCENARIOS` picks them, in place of `QUERIES`, checked before the load, and
  the results are written as each scenario ends. The Compose `bench` profile and
  `make bench` run it at 20M rows (below that `LIMIT 100` cannot stop early, which a
  warning says), the manual CI job at 1M to check the harness, and `bench-smoke` checks
  it too.
- Source: every PostgreSQL version conditional is in `src/compat.h` (after PG-Strom's
  `pg_compat.h` and Citus's `pg_version_constants.h`): `lf_index_beginscan`, the
  node instrumentation accessors and `LF_DATUM_IS_64BIT`; a build against a server
  older than PostgreSQL 18 stops with an error. No change in behaviour.

### Removed

- `run.sh` with `bench.sql`, `schema.sql`, `summarize.sh` and `choices.sql`,
  `types_bench.sh`, `types_compare.sh`, `skip_bench.sh`; the regression test
  `leapfrog_skip` checks the skip-ahead counters.

## [0.0.5] — 2026-11-04

### Added

- `leapfrog.prefetch` (default on): every stream asks for its next leaf page as
  soon as it reaches one, so that the read overlaps the entries of the current
  page, not when nbtree already knows the scan ends there. Cold, the node took
  half the time on two dense streams at 20M rows, and at 100M rows in random
  order the list query for a customer with 5M rows went from 880 to 160 ms
  (BENCHMARKS.md, "Leaf page prefetch"); warm, no change. `EXPLAIN ANALYZE`
  counts them per stream as `Prefetches`; test in `leapfrog_explain`.

### Changed

- `EXPLAIN` shows every index of the node as a block of its own, like a child
  node: `Outer Stream on` / `Inner Stream on` with the index, the equalities as
  `Index Cond`, a partial index's predicate as `Index Pred`, and under `ANALYZE`
  the time of its descents and leaf page steps, the entries read as its rows,
  its skips and its buffers. The structured formats carry the array
  `Index Streams`. The flat `Outer Index` / `Inner Index` / `Outer Entries Read`
  properties are gone; `Skips`, `Short Skips` and `Group Overflows` on the node
  are now the totals of the streams' own. Test `leapfrog_explain`.
- README: `leapfrog.enabled = off` does not change plans already cached, and
  `DISCARD PLANS` does; every stream holds its own buffer pin.
- BENCHMARKS.md: the list query `customer_id = $1 AND deleted_at IS NULL` at 100M rows
  with the rows in random physical order (stock's Index Scan 92 s against the node's
  0.9 s, chosen by the planner) and in `id` order (where the planner keeps a 1.6 s
  Index Scan over the node's 59 ms: a cost-model miss to fix), two filters with 100 or
  5,000 matches at 100M, 500 matches in the middle of the table, writes with 15 against
  14 indexes at 20M, where the INSERT WAL comes from, reads at 10M to 100M. README:
  its numbers are now those at 20M and 100M rows instead of 500,000 to 50M.
- `write_bench.sh`: strategy M (the composite indexes of S plus single-column indexes
  for the other columns, 15); the read runs are labelled with their strategy.
- `list_bench.sh`: the list query with rare, scattered matches, rows in random or `id`
  order, six plan modes and text plans; checked by `bench-smoke`.
- `bitmap_bench.sh`: an `exact` mode, with indexes made for the queries, and index sizes in
  `sizes.csv`. `write_bench.sh`: `STRATEGIES` picks the index sets to run.
- Shorter script headers and fewer source comments; no change to the code.

### Fixed

- Cost model: no row comes before the inner streams have read the whole group of
  the first value, however few rows a `LIMIT` wants, but the node's startup cost
  took an even share of the merge. With one value holding most of the rows at the
  end the query starts from, the planner chose the node at 2.8 ms over an Index
  Scan at 0.1 ms. Startup now counts that group, the value being known from the
  range probe and its share from the most common values; the total cost does not
  change. Test in `leapfrog_planner`; numbers in BENCHMARKS.md.
- Cost model: the charge for the first group looked only at the value at the very
  end of the overlap, so one row or dead entry ahead of a common value hid it. It
  now takes the largest group within the share of the overlap before the rows
  wanted, by the `LIMIT` of a query on the relation alone.
- Cost model: generic plans and parameterized paths kept the old charge, with no
  probe to tell the value: the overlap is now taken for the whole column, as in
  the rest of their costing, and the NULLs that come first count without a probe.
- Cost model: the share of the group in a stream was that of the table; a stream
  with a narrow range holds more of it. A value or NULLs some stream does not hold
  are passed, as the merge passes them, and such a value is looked up in the index.
- Cost model: the groups of the NULLs and the most common values inside the overlap
  count at their own size, not the average, in sorting; one that overflows
  `work_mem` is not sorted, and fetching the outer entries of its value counts.
- Cost model: a partial index that rules out the NULLs of the sort column is not
  charged for their group, nor charged for their share of its entries.
- Cost model: a value out of the most common ones holds its share of what they and
  the NULLs leave, not 1/ndistinct. The charge has no floor of a page per stream,
  which a unique sort column paid for nothing.
- Planner: the set quickest to its first row is offered next to the cheapest: a
  stream that lowered the total but added a first group decided for a `LIMIT` too.
  Tests of all of these in `leapfrog_first_group`; numbers in BENCHMARKS.md.

## [0.0.4] — 2026-11-02

Still experimental. The shared library changes; the SQL functions do not:
`ALTER EXTENSION leapfrog UPDATE` after installing the new files (the update
script `leapfrog--0.0.3--0.0.4.sql` is empty). Reload or restart the backends
so that they load the new library. Plans change: which index is the outer one, and
sets that were not possible before.

### Added

- README: the node against a self join written by hand.
- Sort columns of any B-tree type (`timestamptz`, `date`, `numeric`, `text`,
  `varchar`, `uuid`, arrays, enums, domains …): the merge compares `Datum`s
  with the comparator of the query's sort key. Every stream's index column
  must be in that key's operator family, input type and collation. The
  by-reference value of a group and the bound of a skip are copied, as the
  stream they came from moves on. Types that compare as plain integers
  (`bigint`, `integer`, `timestamptz`, `date` …) do it inline. Tests in
  `leapfrog_sort_types`.
- Nullable sort columns, in all four `ASC/DESC × NULLS FIRST/LAST` orders. A
  NULL is a value of the merge and its group is intersected by TID. A stream
  that skipped on a value goes back for the NULLs when they come after the
  values; the NULL group can be a skip's target. The cost model counts the
  null fraction in the overlap of the streams. Tests in `leapfrog_nulls`.
- `DESC` and `NULLS FIRST` index columns: each stream scans in the direction
  that gives the query's order in its own index. Tests in
  `leapfrog_index_order`.
- Partitioned tables and inheritance: a node per child under a `Merge Append`
  or ordered `Append`. Tests in `leapfrog_partition`.
- PostgreSQL 19 (`REL_19_STABLE`): `index_beginscan` takes table AM flags;
  alternative expected output for the changes in the core `EXPLAIN` format;
  an assertion build in CI.
- `tests/performance/bitmap_bench.sh`: the node against `BitmapAnd`, stock
  PostgreSQL and PostgreSQL with leapfrog at 100k to 50M rows, with and
  without `LIMIT`, the modes in ABBA order; `WORK_MEM` for exact bitmaps;
  `DELETED=batches` for rows deleted customer by customer in random
  physical order, where the stock Index Scan reads the heap. Results in the
  README and BENCHMARKS.md; `make bench-smoke` runs it too.

### Changed

- Planning: the share of a sort range comes from the column's statistics, read
  once per relation, instead of a selectivity call each time, which read and
  detoasted them again; a stream that cannot pay for itself is not costed or
  probed; the correlation is read once per index. With 6 equalities and 10
  indexes the node adds 0.07 ms to planning instead of 0.59. Shares can differ
  from the selectivity functions', within a histogram bin. `leapfrog.trace_planner`
  reports the counts. Tests in `leapfrog_planner`; numbers in BENCHMARKS.md.
- The planner and the merge follow a MySQL index merge. One pass over the
  candidates, fewest entries first, keeps the cheapest set, instead of every
  pair and a greedy growth from the cheapest. The streams catch up with a
  candidate in turn, the sparsest first after each new candidate, so a dense
  stream reads around the values the others agree on. Any index that reads in
  the query's order can be the outer one; it is the densest without a predicate.
  Tests in `leapfrog_merge_order`.
- nbtree's private scan state (`BTScanOpaque`) is read in one function,
  `lf_scan_leaf_position`.
- `compose.yaml` publishes the server on 127.0.0.1 only, not on every
  interface: the password is the well-known default. `LEAPFROG_BIND=0.0.0.0`
  restores the old behaviour.

### Fixed

- `TABLESAMPLE` was ignored: the node was offered for a sampled relation and
  returned rows outside the sample. Such a relation is now left to its
  Sample Scan. Test in `leapfrog_basic`; without the check the node is used
  and the rows differ from the stock plan's.
- The equalities of a stream were taken without
  `restriction_is_securely_promotable`, as scan keys, under row-level
  security: a non-leakproof operator of the query ran on every index entry,
  also those of rows the policy hides. Such a clause now stays in `Filter`,
  after the policy's quals. Test in `leapfrog_security`.
- Cost model: the node was charged for the whole `baserestrictcost` per
  fetched row, including the equalities its scan keys enforce and the clauses
  an inner predicate lets it drop from `Filter`. It is now charged for what
  it evaluates, the same list the plan's `Filter` is made from
  (`lf_node_quals`), as `cost_index` does.
- Cost model: a predicate implied by the set's other conditions counted twice
  in the rows fetched (equality `kind = 2` and predicate `kind = 2`), which
  also lowered the node's row estimate. It is now left out, as
  `add_predicate_to_index_quals` does. Tests for both in `leapfrog_cost`.
- The planner kept the cheapest pair, and in the greedy expansion the
  cheapest set, as a pointer to the path it had passed to `add_path`, and
  read its cost from there afterwards. `add_path` frees a path it rejects or
  later replaces, so the cost could be read from freed memory; and under
  `leapfrog.force` it was the scaled-down cost, so no later pair and no
  third stream could beat the first pair offered: under `leapfrog.force`
  the set was the first pair found, not the cheapest, and never grew. The
  cost is now kept as a number taken before `add_path`. Test in
  `leapfrog_nway`: under `leapfrog.force` the query that gets three streams
  without it gets the same three; before, a pair and a filter.
- The `leapfrog_explain` regression test set `random_page_cost` on
  `pg_default`, a setting of the whole cluster: under `make installcheck`
  against a server with other databases it changed their plans while it
  ran, could stay set after an interrupted run, and its `RESET` dropped a
  value set before. It now creates a tablespace of its own (in place,
  `allow_in_place_tablespaces`), named after the database so that runs in
  other databases do not share it, with a marking comment; it puts a copy of
  the table there and drops both afterwards. One left by an interrupted run
  is dropped only when this user owns it and it has the mark; a tablespace
  of that name without both stops the test before anything is changed. The
  check still fails when the cost model ignores the tablespace (tried with
  `get_tablespace_page_costs(InvalidOid, …)`).
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
- `tests/run-in-docker.sh` ran `docker compose down -v` in the default
  project `leapfrog`, removing the `pgdata` volume of a server started with
  `docker compose up`. It now uses a project unique to the run,
  `leapfrog-test-<pid>-<random>` (`COMPOSE_TEST_PROJECT`), so that it also
  leaves a server kept by an earlier `--keep` run alone, with an overlay,
  `tests/compose.test.yaml`, that publishes the server on a free port of
  127.0.0.1 only; `--keep` prints the port and the command that stops it.
  A `COMPOSE_TEST_PROJECT` that already has containers or volumes is
  refused, and so is Docker Compose older than 2.24.4, which lacks
  `!override`.

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

[Unreleased]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.5...HEAD
[0.0.5]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/ibrohim238/postgresql-leapfrog/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/ibrohim238/postgresql-leapfrog/releases/tag/v0.0.1
