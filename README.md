# postgresql-leapfrog

A PostgreSQL 18 extension that adds an **Index Merge Intersect** plan node:
an ordered intersection of two B-tree indexes, without materialising a bitmap
and without sorting the result.

```text
Limit
  └── Custom Scan (Index Merge Intersect) on orders
        Outer Index: idx_orders_customer_id   -- (customer_id, id)
        Inner Index: idx_orders_active_id     -- (id) WHERE deleted_at IS NULL
```

Status: **experimental**. The algorithm and the executor are covered by
regression and isolation tests (see [Tests](#tests)); the cost model is
explainable but has been calibrated on synthetic data only. Read
[Limitations](#limitations) before using it in production.

## Contents

1. [Purpose](#purpose)
2. [How Index Merge Intersect works](#how-index-merge-intersect-works)
3. [Example](#example)
4. [Compared with Index Scan and BitmapAnd](#compared-with-index-scan-and-bitmapand)
5. [Requirements](#requirements)
6. [Installation](#installation)
7. [Docker quick start](#docker-quick-start)
8. [Loading the library](#loading-the-library)
9. [Settings](#settings)
10. [Reading EXPLAIN](#reading-explain)
11. [Tests](#tests)
12. [Benchmarks](#benchmarks)
13. [Cost model](#cost-model)
14. [Limitations](#limitations)
15. [Known issues](#known-issues)
16. [Operational safety](#operational-safety)
17. [Roadmap](#roadmap)
18. [License](#license)

## Purpose

A typical query: one page of a customer's rows ordered by `id`, live rows
only (or deleted rows only):

```sql
SELECT *
FROM orders
WHERE customer_id = 100
  AND deleted_at IS NULL
ORDER BY id DESC
LIMIT 100;
```

Stock PostgreSQL runs it in one of two ways:

- an `Index Scan` on `(customer_id, id)` with `deleted_at IS NULL` as a filter
  on every heap row: when matching rows are rare and far away, it reads
  hundreds of thousands of rows to return a hundred;
- an `Index Scan` on the partial `(id) WHERE deleted_at IS NULL` with
  `customer_id = 100` as a filter: the same picture when the customer is rare.

`BitmapAnd` of the two indexes reads the partial index completely, loses the
`id` order and needs a sort.

The schema-side alternative is a dedicated partial index
`(customer_id, id) WHERE deleted_at IS NULL` for every filter column. On wide
tables that doubles the number of indexes and the writes into them.

Leapfrog offers a third way: one full index per filter column plus two
partial indexes on `id` shared by the whole table, and a plan node that
merges the two ordered index streams and visits the heap only for rows that
survived the intersection.

## How Index Merge Intersect works

For every base relation of the query the planner looks for an index pair:

- an **outer** B-tree `(k1, …, kN, sortcol)`: every `kI` is compared for
  equality with a constant, a parameter or a column of an outer relation, and
  the last column is the first sort key of the query;
- an **inner** partial B-tree `(sortcol, …) WHERE predicate` whose predicate
  is implied by the query's conditions.

The executor reads both indexes as sorted streams in the `ORDER BY` direction
(`ForwardScanDirection` or `BackwardScanDirection`), advances the side that
lags behind until the `sortcol` values meet, and then matches the entries
**by TID**: the inner entries of one value are collected into a sorted group
and the outer entries are looked up in it by binary search. This is MySQL's
index merge intersection (`RowIDIntersectionIterator`) adapted to nbtree:
matching by TID keeps the merge correct for a non-unique `sortcol` and for
dead row versions still present in the indexes.

A matched entry is fetched from the heap with `index_fetch_heap`, following
the HOT chain the way `index_getnext_slot` does. The TID group is bounded by
`work_mem`: when a value has more entries than fit, the group is dropped,
every outer entry of that value is fetched from the heap and the partial
index predicate is checked on the row explicitly. The result is the same; for
that value the cost is that of a plain index scan with a filter.

Under EvalPlanQual (a concurrent `UPDATE` during `SELECT … FOR UPDATE`) the
node rechecks on the new row version what it guaranteed by construction —
the equalities on the outer index columns and the inner index predicate —
the way `Index Scan` rechecks `indexqualorig`.

## Example

One million orders of 200 customers. Recent orders are live; deleted orders
are old ones, every fifth among the first 400,000 ids. The data is
deterministic, so the counters below are exactly what you get; this example is
also the regression test `leapfrog_example`.

```sql
CREATE EXTENSION leapfrog;   -- SQL wrapper
LOAD 'leapfrog';             -- or shared_preload_libraries

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    deleted_at  timestamptz,
    payload     text
);
INSERT INTO orders
SELECT g, g % 200,
       CASE WHEN g <= 400000 AND g % 5 = 0 THEN '2026-01-01'::timestamptz END,
       repeat('x', 100)
FROM generate_series(1, 1000000) g;

CREATE INDEX idx_orders_customer_id ON orders (customer_id, id);
CREATE INDEX idx_orders_active_id   ON orders (id) WHERE deleted_at IS NULL;
CREATE INDEX idx_orders_deleted_id  ON orders (id) WHERE deleted_at IS NOT NULL;
VACUUM ANALYZE orders;
```

The latest 100 deleted orders of one customer. The planner picks the node by
cost, without `leapfrog.force`:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM orders
WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;
```

```text
 Limit (actual time=0.235..0.559 rows=100.00 loops=1)
   Buffers: shared hit=128
   ->  Custom Scan (Index Merge Intersect) on orders (actual time=0.234..0.546 rows=100.00 loops=1)
         Outer Index: idx_orders_customer_id
         Inner Index: idx_orders_deleted_id
         Outer Entries Read: 3100
         Inner Entries Read: 3982
         Matched TIDs: 100
         Heap Fetches: 100
         Peak Group Memory: 96 B
         Buffers: shared hit=128
 Planning Time: 0.084 ms
 Execution Time: 0.591 ms
```

The node walks both indexes from the newest `id` down. The outer side skips
the customer's 3,000 recent live orders by reading index entries only; then
the two streams meet, and exactly the 100 rows returned are fetched from the
heap.

The same query with `BitmapAnd` (`SET leapfrog.enabled = off; SET
enable_indexscan = off;`):

```text
 Limit (actual time=8.407..8.427 rows=100.00 loops=1)
   Buffers: shared hit=2242
   ->  Sort (actual time=8.406..8.414 rows=100.00 loops=1)
         Sort Key: id DESC
         Sort Method: top-N heapsort  Memory: 76kB
         Buffers: shared hit=2242
         ->  Bitmap Heap Scan on orders (actual time=6.312..7.942 rows=2000.00 loops=1)
               Recheck Cond: ((customer_id = 100) AND (deleted_at IS NOT NULL))
               Heap Blocks: exact=2000
               Buffers: shared hit=2242
               ->  BitmapAnd (actual time=5.954..5.955 rows=0.00 loops=1)
                     Buffers: shared hit=242
                     ->  Bitmap Index Scan on idx_orders_customer_id (actual time=0.993..0.993 rows=5000.00 loops=1)
                           Index Cond: (customer_id = 100)
                           Index Searches: 1
                           Buffers: shared hit=22
                     ->  Bitmap Index Scan on idx_orders_deleted_id (actual time=4.688..4.688 rows=80000.00 loops=1)
                           Index Searches: 1
                           Buffers: shared hit=220
 Planning Time: 0.102 ms
 Execution Time: 8.642 ms
```

`BitmapAnd` cannot stop at 100 rows: it reads all 80,000 entries of the
partial index, fetches all 2,000 matching rows and sorts them.

All four plans for this query (warm cache, median of three runs on a laptop;
the counters are exact, the timings are indicative):

| Plan | Time | Buffers | Index entries read | Heap rows fetched | Sort |
|---|---|---|---|---|---|
| **Index Merge Intersect** (planner's choice) | **0.58 ms** | **128** | 3,100 + 3,982 | **100** | no |
| Index Scan on `(id) WHERE deleted_at IS NOT NULL` + filter (stock planner's choice) | 0.68 ms | 383 | 3,981 | 3,981 | no |
| Index Scan on `(customer_id, id)` + filter | 1.58 ms | 3,115 | 3,100 | 3,100 | no |
| BitmapAnd + Bitmap Heap Scan | 9.6 ms | 2,242 | 5,000 + 80,000 | 2,000 | top-N |

Where the node does **not** win, said plainly:

- Without `LIMIT` the whole result is needed, and both plans fetch all 2,000
  rows with the same 2,242 buffers: `BitmapAnd` + Sort 8.8 ms, the node
  7.2 ms. Their estimates are within about 10 % of each other, so the planner
  picks one or the other depending on the `ANALYZE` sample.
- With 1,000 customers instead of 200 (1,000 orders each) the planner chooses
  `BitmapAnd` (3.0 ms, 626 buffers) even for `LIMIT 100`, although the node
  under `force` takes 1.55 ms and 162 buffers: the cost model misses this one
  (see Known issues).
- The stock planner is already decent in this example (0.68 ms). The gap grows
  when the matches are farther away; see [BENCHMARKS.md](BENCHMARKS.md) for
  35–166× cases.

To see the node where it loses on cost:

```sql
SET leapfrog.force = on;   -- diagnostics only, not for production
```

## Compared with Index Scan and BitmapAnd

| | Index Scan + Filter | BitmapAnd | Index Merge Intersect |
|---|---|---|---|
| `ORDER BY` order | kept | lost, needs a Sort | kept |
| Early exit on `LIMIT` | yes | no: both indexes are read completely | yes |
| Heap visits | every row of one index | intersection only | intersection only |
| Memory | O(1) | bitmaps of both indexes | TID group of one value, ≤ `work_mem` |
| Wins when | matches are frequent | the whole result is needed, indexes are small | matches are rare and far away, there is a `LIMIT` |

## Requirements

- PostgreSQL **18** (the planner and executor APIs change between major
  versions; other versions are not supported).
- Server headers (`postgresql-server-dev-18` on Debian/Ubuntu,
  `postgresql18-devel` on the RHEL family), `gcc` or `clang`, `make`.
- For `make installcheck`: `pg_regress` and `pg_isolation_regress` from the
  same headers package.

Both indexes must be in nbtree **version 4** format (every index created on
PostgreSQL 12+). Indexes carried over by `pg_upgrade` from older versions
without a `REINDEX` are rejected at plan time.

## Installation

```bash
git clone https://github.com/ibrohim238/postgresql-leapfrog.git
cd postgresql-leapfrog
make            # PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config if needed
sudo make install
```

In `postgresql.conf`:

```ini
shared_preload_libraries = 'leapfrog'
```

Restart the server, then in the target database:

```sql
CREATE EXTENSION leapfrog;
SELECT leapfrog_version(), leapfrog_is_loaded();
```

Check:

```bash
make installcheck     # regression + isolation against the running server
```

`PGHOST`, `PGPORT` and `PGUSER` are honoured. `make check` (temporary
installation) works only when building inside a PostgreSQL source tree, as
for every contrib module.

## Docker quick start

```bash
docker compose up -d --build --wait     # PostgreSQL 18 with leapfrog in shared_preload_libraries
psql -h localhost -p 5433 -U postgres -d leapfrog   # password: leapfrog
```

Tests in one command (starts the server, runs regression and isolation suites
in a separate container, tears everything down):

```bash
bash tests/run-in-docker.sh          # or: make docker-test
bash tests/run-in-docker.sh --keep   # keep the server running
```

Benchmarks (`bench` profile, 100k and 1M rows by default):

```bash
docker compose up -d --build --wait
docker compose --profile bench run --rm bench
# results: tests/performance/results/<timestamp>/
```

Compose environment variables: `LEAPFROG_PORT` (5433), `POSTGRES_PASSWORD`
(`leapfrog`), `LEAPFROG_SHARED_BUFFERS` (512MB), `BENCH_SIZES`,
`BENCH_REPEATS`.

## Loading the library

The extension works through `set_rel_pathlist_hook`, which is installed in
`_PG_init` when the **library is loaded**, not by `CREATE EXTENSION`.
Options:

| Method | When to use |
|---|---|
| `shared_preload_libraries = 'leapfrog'` | production: hook in every backend, needs a restart |
| `session_preload_libraries = 'leapfrog'` | no restart, new sessions |
| `LOAD 'leapfrog';` | current session, experiments |
| calling `leapfrog_version()` | side effect: loads the library into the session |

`CREATE EXTENSION leapfrog` creates two SQL functions (`leapfrog_version()`,
`leapfrog_is_loaded()`) and registers the extension in `pg_extension`;
without loading the library the planner does not offer the node.

PostgreSQL **never unloads** shared libraries: after `LOAD` the hook stays
until the session ends, and `DROP EXTENSION` does not remove it. To switch it
off use `SET leapfrog.enabled = off` (or `postgresql.conf`, or
`ALTER DATABASE … SET`).

## Settings

| Setting | Default | Context | Meaning |
|---|---|---|---|
| `leapfrog.enabled` | `on` | `USERSET` | The planner offers the Index Merge Intersect node and picks it by cost. `off` disables the hook completely. |
| `leapfrog.force` | `off` | `USERSET` | The node's paths get zero cost; whenever a suitable index pair exists the node is chosen (the counterpart of MySQL's `INDEX_MERGE` hint). The plan-time check of the group estimate against `work_mem` is skipped as well. **Diagnostic setting**: it can make a query many times slower. |

Also relevant: `work_mem` (TID group limit; when the estimate exceeds it at
plan time the path is not offered), `random_page_cost`, `seq_page_cost`,
`cpu_*_cost`, `effective_cache_size` (through `index_pages_fetched`), and the
`enable_*` settings of the other nodes.

## Reading EXPLAIN

```text
Custom Scan (Index Merge Intersect) on orders
  Filter: (payload <> 'x'::text)
  Outer Index: idx_orders_customer_id
  Inner Index: idx_orders_active_id
  Outer Entries Read: 1610423
  Inner Entries Read: 251007
  Matched TIDs: 1000
  Heap Fetches: 1000
  Peak Group Memory: 96 B
  Group Overflows: 0        -- shown only when non-zero
  Rows Checked by Predicate: 0
```

| Field | Meaning |
|---|---|
| `Outer Index` / `Inner Index` | the chosen pair; separate properties in `FORMAT JSON/YAML/XML`. |
| `Filter` | conditions the node checks on the row. Equalities of the outer index and conditions implied by the inner predicate are not in `Filter` (like `Index Cond` of an Index Scan); the exception is the target relation of `UPDATE/DELETE/SELECT FOR UPDATE`, where they are kept for EvalPlanQual. |
| `Outer Entries Read` | entries read from the outer index. |
| `Inner Entries Read` | entries read from the inner index. |
| `Matched TIDs` | entries found by TID in both indexes. |
| `Heap Fetches` | `index_fetch_heap` calls (including HOT chain continuations). |
| `Rows Removed by Filter` | the standard counter of rows dropped by `Filter`. |
| `Peak Group Memory` | largest capacity of the TID group array, bytes. |
| `Group Overflows` | how many times a value's group exceeded `work_mem` and the node fell back to the predicate check. |
| `Rows Checked by Predicate` | outer entries of overflowed groups fetched from the heap and checked against the inner index predicate. |

Counters are summed over all rescans of the node (inside a Nested Loop they
are the total over iterations; `loops` shows their number). Without
`ANALYZE` the node does not open its scans (`EXEC_FLAG_EXPLAIN_ONLY`) and
prints no counters.

The ratio of `Outer Entries Read + Inner Entries Read` to `Heap Fetches`
shows where the node wins: index entries are cheap, heap visits are
expensive.

## Tests

Standard PostgreSQL infrastructure: `pg_regress` for SQL tests and
`pg_isolation_regress` for concurrent scenarios.

```bash
make installcheck          # everything
make test-regress          # sql/*.sql against expected/*.out only
make test-isolation        # tests/isolation/specs/*.spec only
make pgindent              # core code style
make bench-smoke           # tiny run of the benchmark harness
```

The regression tests need a superuser (as `pg_regress` normally runs):
`leapfrog_memory` reads `/proc/self/status` and `leapfrog_explain` changes
the page cost of `pg_default` for one check and resets it.

Regression tests (`sql/`):

| File | What it checks |
|---|---|
| `leapfrog_setup` | `CREATE EXTENSION`, GUCs, the helper functions `lf_check`, `lf_plan`, `lf_counters` |
| `leapfrog_basic` | ASC/DESC, `LIMIT 1/100`, no `LIMIT`, empty and full intersection, several equality columns, a predicate with several conditions, cases where the node **must not** be offered (DESC index, nullable and `int4` columns, `IN`, range, no pair, partitioned table, `NOT NULL … NOT VALID`) |
| `leapfrog_duplicates` | non-unique sort column, matching by TID, key monotonicity, dead entries after `UPDATE/DELETE` without `VACUUM` |
| `leapfrog_overflow` | `work_mem = 64kB`: the path is not offered by estimate; under `force` — `Group Overflows`, predicate fallback without losing or duplicating rows |
| `leapfrog_parameters` | generic prepared statement (`$1`), `LATERAL` with one and two nestloop parameters, join through an equivalence class, `NULL` parameter, repeated ReScan, InitPlan, plan cache invalidation on `DROP INDEX`, no node on the nullable side of an outer join |
| `leapfrog_mvcc` | HOT chains, rows moving between partial indexes, changes of the merge column and of an equality column, `REPEATABLE READ`, `FOR UPDATE/SHARE`, `UPDATE/DELETE` driven by the node, scrollable cursor, dead index entries with a NULL merge column |
| `leapfrog_memory` | peak backend memory of the predicate fallback (Linux, reads `/proc/self/status`) |
| `leapfrog_example` | the README example verbatim: the planner's choice, the stock Index Scan and `BitmapAnd` plans with their counters |
| `leapfrog_explain` | every `EXPLAIN` format, `ANALYZE` counters, the node chosen **by cost** without `force`, back to the stock plan with `enabled = off`, each cost model input (heap correlation, filter cost, tablespace page cost, loop count) moving the estimate in the right direction |

Every `lf_check(query)` runs the query with the stock plan and with
`leapfrog.force`, compares the multisets with `EXCEPT ALL` in both directions
(and row positions when the sort key is unique) and reports whether the plan
contained the `Custom Scan` — a test cannot pass by accident through a plain
Index Scan.

Isolation tests (`tests/isolation/specs/`):

| File | Scenarios |
|---|---|
| `leapfrog_concurrent_update` | EvalPlanQual under `READ COMMITTED`: `customer_id` change, `deleted_at` in both directions, HOT update, `DELETE`, `id` change, rollback. Every permutation runs both with the node and with the stock plan under the same interleaving. |
| `leapfrog_predicate_flip` | a row moves between the partial indexes under `REPEATABLE READ` and `READ COMMITTED` |
| `leapfrog_hot_update` | three HOT updates in a row, a reader with an old snapshot, `pg_stat_xact_user_tables.n_tup_hot_upd` |
| `leapfrog_delete` | `DELETE` and owner change, old/new snapshot, `VACUUM` |
| `leapfrog_repeatable_read` | stable repeated reads, `SERIALIZABLE`, `FOR UPDATE` on a changed row → `could not serialize access` |

## Benchmarks

```bash
bash tests/performance/run.sh                    # 100k and 1M rows, uniform and skewed, 1/10/50/90 % deleted
BENCH_SIZES="10000000" bash tests/performance/run.sh
BENCH_SIZES="100000000" BENCH_DELETED="10" bash tests/performance/run.sh   # heavy profile, manual
```

Three strategies on the same table (indexes are rebuilt between strategies):

- **A** stock PostgreSQL: `(customer_id, id)`;
- **B** PostgreSQL + leapfrog: `(customer_id, id)` + `(id) WHERE deleted_at IS NULL` + `(id) WHERE deleted_at IS NOT NULL`; `B` is the planner's choice, `B*` is `leapfrog.force = on`;
- **C** dedicated partial indexes `(customer_id, id) WHERE deleted_at IS [NOT] NULL`.

For each: `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` after a warm-up,
`BENCH_REPEATS` repetitions (5 by default), fixed `setseed`. Measured:
execution and planning time, shared hit/read, index entries read and
`Heap Fetches` of the node, rows returned, index size. Queries: three
customers (largest, median, smallest) × live/deleted × `LIMIT 1/100/1000/none`.
Results go to `results.csv` and `plans.jsonl`; `summarize.sh` prints a summary.

Measured results: [BENCHMARKS.md](BENCHMARKS.md).

## Cost model

The structure follows MySQL's `ROR_intersect_plan::add`; the components are
PostgreSQL cost functions:

```text
run     = index_read_cost(outer, entries matching the equalities)
        + index_read_cost(inner, all entries of the partial index)
        + group_cost(outer + inner, log2(group size))
        + heap_fetch_cost(rows)
        + rows × (cpu_tuple_cost + qual cost + tlist cost)
startup = descent into both B-trees (as in btcostestimate)
        + startup cost of qual and tlist
        + run / (rows + 1)          -- both streams advance to the first match
total   = startup + run
```

- Index pages: `random_page_cost` of the index's tablespace per page; for a
  parameterized path inside a Nested Loop, the Mackert–Lohman estimate
  (`index_pages_fetched`) divided by the number of repetitions, as in
  `genericcostestimate`.
- Heap pages: interpolation between the perfectly correlated and the
  uncorrelated case by the squared correlation of the sort column
  (`pg_statistic`, `STATISTIC_KIND_CORRELATION`), as in `cost_index`. Rows are
  fetched in `sortcol` order, so the correlation of that column decides how
  scattered the heap visits are.
- `LIMIT` is handled by the planner the usual way:
  `startup + (total − startup) × fraction`; the model is linear.

**Documented assumptions** (not derived from statistics): matches are spread
evenly along both indexes; a TID group has the average size
(`inner.tuples / ndistinct(sortcol)`). With strong skew (a customer's deleted
rows only among old `id`s) one side reads far more than predicted; the stock
model makes the same assumption for `Index Scan + Filter`, so neither side
has a systematic advantage. Refining the estimate with MCV statistics is
postponed (see [Roadmap](#roadmap)).

## Limitations

- `bigint` columns only (the sort column and every equality column of the
  outer index), `integer_ops` operator family only; `int2`/`int4` constants
  and parameters are accepted, `int4` columns are not.
- The sort column must be `NOT NULL` according to the planner
  (`RelOptInfo.notnullattnums`): a constraint added `NOT VALID` does not count
  until `VALIDATE CONSTRAINT`.
- Equality (`=`) only; `IN (…)`, ranges, `IS NULL` on equality columns are not
  supported.
- Both indexes: nbtree v4, `ASC`, no `DESC` columns, the same operator family
  as the query's sort key. `ORDER BY … DESC` is served by a backward scan.
- The outer index has at least two key columns; the inner one is partial,
  starts with the sort column, and its predicate follows from `WHERE`.
- One relation per node; partitioned tables, inheritance children and
  materialized views as a source are rejected (`relkind = 'r'`,
  `RELOPT_BASEREL`). No parallel execution (`parallel_safe = false`).
- Only the first `ORDER BY` key is used for the merge; with a composite
  `ORDER BY` the planner puts a `Sort` (incremental or full) above the node.
- The TID group is limited by `work_mem`. Average group estimate above
  `work_mem` — the path is not offered. Actual group above `work_mem` —
  predicate fallback (`Group Overflows`): correct, but more expensive.
- No `pg_stat_statements`-specific instrumentation; counters are shown only by
  `EXPLAIN ANALYZE`.
- The library is never unloaded; switch it off with `leapfrog.enabled = off`.

## Known issues

- **Row position under EvalPlanQual.** When a concurrent transaction changes
  the sort column of a row that `SELECT … FOR UPDATE` has already matched,
  PostgreSQL rechecks the search condition on the new version but not the
  order: the row is returned at its old position with the new `id`. Every
  PostgreSQL plan behaves this way (`Index Scan` included); the isolation test
  `leapfrog_concurrent_update` records identical output for the node and the
  stock plan.
- **Estimates under skew.** When a customer's deleted rows are concentrated
  at one end of the `id` index, the model underestimates the entries read on
  one side. `EXPLAIN ANALYZE` shows a large `Outer Entries Read` with a small
  `Heap Fetches`; the node is correct but may be no faster than the stock plan.
- **Missed opportunities.** In the 1M-row benchmark the model did not pick the
  node in 14 of 192 queries where the forced node was clearly faster; see
  [BENCHMARKS.md](BENCHMARKS.md).
- `leapfrog.force` does not guarantee the node is chosen: the path may be
  dropped for reasons other than cost (for example a parameterization the
  join order cannot provide).

## Operational safety

- Planner: the hook only adds paths through `add_path`; stock paths are never
  removed or changed. With `leapfrog.enabled = off` the hook returns
  immediately.
- Executor: index scans are opened with the standard `index_beginscan` /
  `index_rescan` / `index_getnext_tid` / `index_fetch_heap` and the query's
  `es_snapshot`; visibility, HOT chains and `kill_prior_tuple` work as for
  `Index Scan`.
- Memory: the TID group array grows by doubling up to the `work_mem` limit and
  never beyond; it is reused on `ReScan` and freed on `EndCustomScan`. Long
  merges without matches call `CHECK_FOR_INTERRUPTS()` every 1024
  iterations — `statement_timeout` and query cancellation work.
- Plan cache: as for an `Index Scan`, creating or dropping either index
  invalidates cached plans through its table (test `leapfrog_parameters`).
- The extension creates no tables, writes nothing to the catalog and needs no
  superuser rights to be used (`CREATE EXTENSION` needs the right to create C
  functions, as for any C extension).
- `leapfrog.force` is `USERSET`: any user can slow down their own query; other
  sessions are not affected.

## Roadmap

- Skip ahead instead of reading the lagging side sequentially: re-descend the
  B-tree to the other side's value (true leapfrog), which removes the
  long sequential reads seen under skew.
- Refine the entries-read estimate with MCV statistics and histograms (skewed
  distribution of deleted rows).
- `int4` columns and other btree operator families through dynamic operator
  lookup (`get_opfamily_member`).
- `IN (…)` / `ScalarArrayOpExpr` on equality columns as several consecutive
  scans of the outer index.
- Intersection of more than two indexes and use of the second `ORDER BY` key.
- Partitioned tables (`RELOPT_OTHER_MEMBER_REL`).
- Parallel execution (`parallel_aware` with range partitioning of `sortcol`).
- Publication on PGXN; discussion on pgsql-hackers as an Index Merge
  Intersect node for core.

## License

[PostgreSQL License](LICENSE). The merge algorithm is modelled on the
description of MySQL's index merge intersection; the code was written
independently and contains no MySQL code.
