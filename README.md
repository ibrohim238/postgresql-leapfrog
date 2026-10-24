# postgresql-leapfrog

**Fewer indexes, cheaper writes, ordered reads by composition.** A PostgreSQL 18
extension that lets the planner combine two general B-tree indexes at query time
— `(customer_id, id)` with `(product_id, id)`, or with a shared
`(id) WHERE deleted_at IS NULL` — into one ordered stream, so that a table does
not need a dedicated composite or partial index for every filter combination.

Status: **experimental (0.0.1)**. The executor is covered by regression and
isolation tests that compare every result with the stock plans
(see [Tests](#tests)). The cost model is conservative: in the measured
benchmarks it never picked the node where it was slower, and it misses a part
of the cases where the node is faster (see
[Known limitations](#known-limitations-and-planned-improvements)).

## Contents

1. [The problem: one index per query shape](#the-problem-one-index-per-query-shape)
2. [Why index composition matters](#why-index-composition-matters)
3. [How Index Merge Intersect works](#how-index-merge-intersect-works)
4. [Example](#example)
5. [Compared with Index Scan and BitmapAnd](#compared-with-index-scan-and-bitmapand)
6. [Requirements](#requirements)
7. [Installation](#installation)
8. [Docker quick start](#docker-quick-start)
9. [Loading the library](#loading-the-library)
10. [Settings](#settings)
11. [Reading EXPLAIN](#reading-explain)
12. [Tests](#tests)
13. [Benchmarks](#benchmarks)
14. [Cost model](#cost-model)
15. [Known limitations and planned improvements](#known-limitations-and-planned-improvements)
16. [Known issues](#known-issues)
17. [Operational safety](#operational-safety)
18. [License](#license)

## The problem: one index per query shape

A typical application table has a few filter columns, soft deletes, and pages
ordered by id:

```sql
SELECT * FROM orders
WHERE customer_id = $1 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

For every such query to be fast with stock PostgreSQL, the schema grows one
index per query shape: `(customer_id, id) WHERE deleted_at IS NULL`, the same
`WHERE deleted_at IS NOT NULL` for the trash view, then the same pair for
`product_id`, for `warehouse_id`, and composite indexes for the filter pairs
that are queried together. Each index takes disk space and buffer cache, and
every `INSERT` and every non-HOT `UPDATE` writes into each of them and into the
WAL.

General indexes — one `(filter_column, id)` per filter plus two partial
`(id)` indexes shared by the whole table — are fewer and smaller, but stock
PostgreSQL cannot combine two of them and keep the `id` order: an `Index Scan`
uses one index and filters the rest on the heap, and `BitmapAnd` reads both
indexes completely, loses the order and sorts.

leapfrog adds the missing plan node: an ordered intersection of two B-tree
indexes that stops early at `LIMIT` and visits the heap only for rows that
passed both.

## Why index composition matters

Measured with [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh):
500,000 rows, 12 filter columns of 100 values each, soft deletes, then writes
of 100,000 rows; PostgreSQL 18.6 in Docker on a laptop
(details and caveats in [BENCHMARKS.md](BENCHMARKS.md)).

- **S, specialised**: per filter column `(fK, id) WHERE deleted_at IS NULL` and
  `(fK, id) WHERE deleted_at IS NOT NULL`, plus 6 composite indexes for frequent
  pairs — **30 indexes**.
- **G, general**: per filter column `(fK, id)`, plus `(id) WHERE deleted_at IS
  NULL` and `(id) WHERE deleted_at IS NOT NULL` — **14 indexes**; read with
  stock PostgreSQL or with leapfrog (**G+L**).

Storage and writes (index size and WAL are deterministic; rows per second vary
between runs on this machine, so the range of four runs is given):

| | S (30 indexes) | G (14 indexes) | G vs S |
|---|---|---|---|
| Index size, excluding PK | 302 MB | **201 MB** | −33 % |
| `INSERT` 100,000 rows: WAL | 354 MB | **159 MB** | −55 % |
| `INSERT`: rows per second | 8,000–10,300 | **14,600–33,300** | 1.7–3.8× faster |
| `UPDATE` of a filter column: WAL | 205 MB | **73 MB** | −64 % |
| `UPDATE` of `deleted_at` (soft delete): WAL | **82 MB** | 91 MB | +11 % |
| `DELETE`: WAL | 18 MB | 18 MB | same |

Reads, `LIMIT 100`, median time, `random_page_cost = 1.1` (data in memory):

| Query | S | G stock | G+L (planner) | G+L forced |
|---|---|---|---|---|
| one filter, live rows | 0.07 ms | **0.06 ms** | 0.09 ms | 0.41 ms |
| one filter, deleted rows | **0.06 ms** | 1.59 ms | **0.48 ms** (node) | 0.77 ms |
| two filters with a composite index in S | **0.03 ms** | 1.49 ms | 1.76 ms | 0.50 ms |
| two filters without one | 3.01 ms | 1.50 ms | 1.57 ms | **0.50 ms** |

What this shows, plainly:

- The write side is the reason to compose: a third less index storage, half the
  WAL on inserts, and faster inserts in every run.
- A dedicated index is still the fastest read for the exact query it was built
  for. Composition trades that for fewer indexes; the specialised scheme pays
  instead whenever a combination has no index of its own (3 ms above).
- With general indexes, leapfrog makes the trash query 3× faster than stock
  PostgreSQL, chosen by the planner. For two filters the forced node is 3×
  faster than the stock `BitmapAnd`, but the cost model does not pick it yet.

## How Index Merge Intersect works

For every base relation of the query the planner looks for an index pair:

- an **outer** B-tree `(k1, …, kN, sortcol)`: every `kI` is compared for
  equality with a constant, a parameter or a column of an outer relation, and
  the last column is the first sort key of the query;
- an **inner** B-tree `(j1, …, jM, sortcol, …)` with an equality on every `jI`.
  With `M = 0` it must be a partial index whose predicate is implied by the
  query (`(id) WHERE deleted_at IS NULL`); an ordinary index must add an
  equality column the outer index does not have (`(product_id, id)`).

With every column before `sortcol` fixed, both scans return their entries in
`sortcol` order. The executor reads both as sorted streams in the `ORDER BY`
direction and advances the side that lags behind until the values meet. Once
the lagging side has read 64 entries in a row without catching up, it
descends its B-tree again straight to the other side's value (**skip-ahead**,
`index_rescan` with `sortcol >= value`) instead of reading the gap. The
threshold adapts per side: a skip that lands on the leaf page it left or on
the next one did not pay for its descent and doubles it (up to 64×); a longer
skip halves it back. Clustered gaps are skipped early, evenly spread matches
are read through.

When the values meet, the entries are matched **by heap TID**: the inner
entries of the value are collected into a sorted group and the outer entries
are looked up in it. This is MySQL's index merge intersection
(`RowIDIntersectionIterator`) adapted to nbtree; matching by TID keeps the
merge correct for a non-unique `sortcol` and for dead row versions still in
the indexes. A matched row is fetched with `index_fetch_heap`, following the
HOT chain as `index_getnext_slot` does.

The TID group is bounded by `work_mem`. When a value has more inner entries,
the group is dropped, every outer row of that value is fetched and the inner
index's conditions — its equalities and its predicate — are checked on the
row. Under EvalPlanQual the node rechecks the same conditions on the new row
version, as `Index Scan` rechecks `indexqualorig`.

## Example

One million orders of 200 customers; recent orders are live, one in five of the
oldest 400,000 is deleted. The data is deterministic, so the counters below are
exactly what you get; this example runs as the regression test
`leapfrog_example`.

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
SELECT g, abs(hashint8(g)) % 200,
       CASE WHEN g <= 400000 AND abs(hashint8(g * 7 + 3)) % 5 = 0
            THEN '2026-01-01'::timestamptz END,
       repeat('x', 100)
FROM generate_series(1, 1000000::bigint) g;

CREATE INDEX idx_orders_customer_id ON orders (customer_id, id);
CREATE INDEX idx_orders_active_id   ON orders (id) WHERE deleted_at IS NULL;
CREATE INDEX idx_orders_deleted_id  ON orders (id) WHERE deleted_at IS NOT NULL;
VACUUM ANALYZE orders;

SET random_page_cost = 1.1;   -- the usual value for SSDs and data in memory
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT * FROM orders
WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;
```

```text
 Limit (actual time=0.092..1.882 rows=100.00 loops=1)
   Buffers: shared hit=166
   ->  Custom Scan (Index Merge Intersect) on orders (actual time=0.091..1.866 rows=100.00 loops=1)
         Outer Index: idx_orders_customer_id
         Inner Index: idx_orders_deleted_id
         Outer Entries Read: 585
         Inner Entries Read: 20131
         Matched TIDs: 100
         Heap Fetches: 100
         Peak Group Memory: 96 B
         Skips: 4
         Short Skips: 3
         Buffers: shared hit=166
 Planning Time: 0.106 ms
 Execution Time: 1.907 ms
```

The customer's ~1,500 recent orders are live; the outer side skips past them
straight to the deleted range. There about 40 deleted orders of other
customers lie between two of this customer's, too few to skip: the short
skips raised the inner side's threshold and it reads them through. Exactly
the 100 returned rows are fetched from the heap.

The planner picks the node at the default `random_page_cost = 4` as well
(estimated 798 against 933). Without the extension it runs an `Index Scan` on
the partial index that filters the customer on every deleted row. The same
query with `BitmapAnd` (`SET leapfrog.enabled = off; SET
enable_indexscan = off;`):

```text
 Limit (actual time=10.434..10.462 rows=100.00 loops=1)
   Buffers: shared hit=621
   ->  Sort (actual time=10.432..10.444 rows=100.00 loops=1)
         Sort Key: id DESC
         Sort Method: top-N heapsort  Memory: 76kB
         ->  Bitmap Heap Scan on orders (actual time=9.812..10.271 rows=393.00 loops=1)
               Recheck Cond: ((customer_id = 100) AND (deleted_at IS NOT NULL))
               Heap Blocks: exact=379
               ->  BitmapAnd (actual time=9.666..9.668 rows=0.00 loops=1)
                     ->  Bitmap Index Scan on idx_orders_customer_id (actual time=1.583..1.583 rows=5054.00 loops=1)
                           Index Cond: (customer_id = 100)
                     ->  Bitmap Index Scan on idx_orders_deleted_id (actual time=7.681..7.681 rows=80120.00 loops=1)
 Execution Time: 10.815 ms
```

`BitmapAnd` cannot stop at 100 rows: it reads all 80,120 entries of the partial
index, fetches all 393 matching rows and sorts them.

All four plans for this query (warm cache; the counters are exact, the timings
are from a laptop and vary up to 2× between runs):

| Plan | Time | Buffers | Heap rows fetched | Sort |
|---|---|---|---|---|
| **Index Merge Intersect** (planner's choice at both page costs) | **1.9 ms** | **166** | **100** | no |
| Index Scan on `(id) WHERE deleted_at IS NOT NULL` + filter (the stock choice) | 4.3–8.1 ms | 1,957 | 20,304 | no |
| Index Scan on `(customer_id, id)` + filter | 2.5 ms | 3,133 | 3,554 | no |
| BitmapAnd + Bitmap Heap Scan | 10.8 ms | 621 | 393 | top-N |

To see the node where the planner does not pick it:

```sql
SET leapfrog.force = on;   -- diagnostics, not for production
```

## Compared with Index Scan and BitmapAnd

| | Index Scan + Filter | BitmapAnd | Index Merge Intersect |
|---|---|---|---|
| `ORDER BY` order | kept | lost, needs a Sort | kept |
| Early exit on `LIMIT` | yes | no: both indexes are read completely | yes |
| Heap visits | every row of one index | intersection only | intersection only |
| Index entries read | the rows of one index | all entries of both | both streams up to the limit, gaps skipped |
| Memory | O(1) | bitmaps of both indexes | TID group of one value, ≤ `work_mem` |
| Wins when | matches are frequent | the whole result is needed | matches are sparse and there is a `LIMIT` |

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

Upgrade the library with `make install` (or a package manager), never by
copying over the installed `leapfrog.so`: overwriting a shared library in place
crashes every backend that has it loaded, as for any C extension. `install`
replaces the file instead of rewriting it.

## Settings

| Setting | Default | Context | Meaning |
|---|---|---|---|
| `leapfrog.enabled` | `on` | `USERSET` | The planner offers the Index Merge Intersect node and picks it by cost. `off` disables the hook completely. |
| `leapfrog.force` | `off` | `USERSET` | The node is preferred over every other plan whenever a suitable index pair exists (the counterpart of MySQL's `INDEX_MERGE` hint); among several index pairs the cheapest still wins. The plan-time check of the group estimate against `work_mem` is skipped as well. **Diagnostic setting**: it can make a query many times slower. |
| `leapfrog.skip_after` | `64` | `USERSET` | Developer setting: the starting skip-ahead threshold, in entries; `0` turns skipping off. Used by `tests/performance/skip_bench.sh`; not in `postgresql.conf.sample`. |

The node is costed with PostgreSQL's own page and CPU costs, so the usual
tuning applies. In particular, with the default `random_page_cost = 4` (spinning
disks) the planner prefers reading many heap rows sequentially to reading a few
at random, and rarely picks the node; with `random_page_cost = 1.1`, the usual
value for SSDs and data in memory, it picks the node where it reads far fewer
rows. Also relevant: `work_mem` (TID group limit), `seq_page_cost`,
`cpu_*_cost`, `effective_cache_size` and the `enable_*` settings of other
nodes.

## Reading EXPLAIN

```text
Custom Scan (Index Merge Intersect) on orders
  Filter: (payload <> 'x'::text)
  Outer Index: idx_orders_customer_id
  Inner Index: idx_orders_deleted_id
  Outer Entries Read: 585
  Inner Entries Read: 20131
  Matched TIDs: 100
  Heap Fetches: 100
  Peak Group Memory: 96 B
  Skips: 4                  -- shown only when non-zero
  Short Skips: 3
  Group Overflows: 0        -- shown only when non-zero
  Rows Checked by Predicate: 0
```

| Field | Meaning |
|---|---|
| `Outer Index` / `Inner Index` | the chosen pair; separate properties in `FORMAT JSON/YAML/XML`. |
| `Filter` | conditions the node checks on the row. The equalities of both indexes and conditions implied by the inner predicate are not in `Filter` (like `Index Cond` of an Index Scan); the exception is the target relation of `UPDATE/DELETE/SELECT FOR UPDATE`, where predicate-implied conditions are kept for EvalPlanQual. |
| `Outer Entries Read` / `Inner Entries Read` | entries read from each index, including dead entries with a NULL sort value that are skipped. |
| `Matched TIDs` | entries found by TID in both indexes. |
| `Heap Fetches` | `index_fetch_heap` calls (including HOT chain continuations). |
| `Rows Removed by Filter` | the standard counter of rows dropped by `Filter`. |
| `Peak Group Memory` | largest capacity of the TID group array, bytes. |
| `Skips` | re-descents of a lagging scan to the other side's value. |
| `Short Skips` | skips that landed on the leaf page they left or the next one; each doubles that side's threshold (see Skip-ahead). |
| `Group Overflows` | how many times a value's group exceeded `work_mem` and the node fell back to checking the inner conditions on the row. |
| `Rows Checked by Predicate` | outer rows of overflowed groups fetched and checked that way. |

Counters are summed over all rescans of the node (inside a Nested Loop they
are the total over iterations; `loops` shows their number). Without
`ANALYZE` the node does not open its scans and prints no counters.

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

Against an assert-enabled server (PostgreSQL 18 built from source with
`--enable-cassert`; also a CI job), failing on any `TRAP:` or crashed backend
in the server log:

```bash
docker build -f docker/cassert.Dockerfile -t leapfrog-cassert .
docker run --rm leapfrog-cassert
```

The regression tests need a superuser (as `pg_regress` normally runs):
`leapfrog_memory` reads `/proc/self/status` and `leapfrog_explain` changes the
page cost of `pg_default` for one check and resets it.

Regression tests (`sql/`):

| File | What it checks |
|---|---|
| `leapfrog_setup` | `CREATE EXTENSION`, GUCs, the helpers `lf_check`, `lf_plan`, `lf_counters` |
| `leapfrog_basic` | ASC/DESC, `LIMIT`, empty and full intersection, several equality columns, a predicate with several conditions, cases where the node must not be offered (DESC index, nullable and `int4` columns, `IN`, range, no pair, partitioned table, `NOT NULL … NOT VALID`) |
| `leapfrog_duplicates` | non-unique sort column, matching by TID, key monotonicity, dead entries |
| `leapfrog_overflow` | `work_mem = 64kB`: no path by estimate; under `force`, the fallback without losing or duplicating rows |
| `leapfrog_parameters` | prepared statements, `LATERAL` with one and two nestloop parameters, joins through an equivalence class, `NULL` parameter, ReScan, InitPlan, plan cache invalidation, no node on the nullable side of an outer join |
| `leapfrog_mvcc` | HOT chains, rows moving between partial indexes, changes of the merge and equality columns, `REPEATABLE READ`, `FOR UPDATE/SHARE`, cursors, dead index entries with a NULL merge column |
| `leapfrog_memory` | peak backend memory of the overflow fallback (Linux) |
| `leapfrog_explain` | every `EXPLAIN` format, `ANALYZE` counters, each cost model input moving the estimate in the right direction |
| `leapfrog_example` | the example above verbatim, with the planner's choice at both page costs |
| `leapfrog_btree_pair` | two ordinary indexes `(customer_id, id)` and `(product_id, id)`: both directions, parameters on either side, partial index with an equality prefix, pairs that must not be formed, the overflow fallback checking the inner equality |
| `leapfrog_skip` | skip-ahead on both sides, both directions, non-unique sort column, rescans, dead entries; `leapfrog.skip_after` 0 and 1; the adaptive threshold backing off on evenly spread matches and staying low on long gaps |
| `leapfrog_outer_partial` | partial index on the outer side: its predicate's conditions stay in the `Filter`, plain and `FOR UPDATE`, rows that left the index |

Every `lf_check(query)` runs the query with the stock plan and with
`leapfrog.force`, compares the multisets with `EXCEPT ALL` in both directions
(and row positions when the sort key is unique) and reports whether the plan
contained the `Custom Scan`, so a test cannot pass by accident through a plain
Index Scan. Every fix and feature has a test that fails without it; the
reverted variants were built and run.

Isolation tests (`tests/isolation/specs/`):

| File | Scenarios |
|---|---|
| `leapfrog_concurrent_update` | EvalPlanQual under `READ COMMITTED`: changes of the equality column, `deleted_at` in both directions, HOT update, `DELETE`, the sort column, rollback; each with the node and with the stock plan |
| `leapfrog_btree_pair` | EvalPlanQual for two ordinary indexes: the inner equality and the outer equality failing on the new version |
| `leapfrog_predicate_flip` | a row moving between the partial indexes under `REPEATABLE READ` and `READ COMMITTED` |
| `leapfrog_hot_update` | three HOT updates in a row, a reader with an old snapshot |
| `leapfrog_delete` | `DELETE` and owner change, old and new snapshots, `VACUUM` |
| `leapfrog_repeatable_read` | stable repeated reads, `SERIALIZABLE`, `FOR UPDATE` on a changed row |
| `leapfrog_outer_partial` | EvalPlanQual with a partial outer index: a row soft-deleted while `FOR UPDATE` waits is dropped, a row whose other columns changed is returned |
| `leapfrog_insert_vacuum` | concurrent `INSERT` under `READ COMMITTED`, `FOR UPDATE` waiting on a transaction that also inserts, `VACUUM` with an open cursor whose scan has run out |
| `leapfrog_overflow_epq` | EvalPlanQual through the overflow fallback (`work_mem = 64kB`): rows leaving and joining the inner side |

## Benchmarks

```bash
bash tests/performance/write_bench.sh            # storage, writes and reads for 12 filter columns
bash tests/performance/run.sh                    # reads: 3 strategies, uniform and skewed, 1/10/50/90 % deleted
BENCH_RANDOM_PAGE_COST=1.1 bash tests/performance/run.sh
BENCH_SIZES="10000000" bash tests/performance/run.sh
```

Both scripts record `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` after a warm-up,
with a fixed seed, into CSV files; `summarize.sh` prints a summary. Results:
[BENCHMARKS.md](BENCHMARKS.md).

## Cost model

The structure follows MySQL's `ROR_intersect_plan::add`; the components are
PostgreSQL cost functions:

```text
run     = merge_read_cost(outer entries, inner entries)
        + group_cost(outer + inner, log2(group size))
        + heap_fetch_cost(rows)
        + rows × (cpu_tuple_cost + qual cost + tlist cost)
startup = descent into both B-trees (as in btcostestimate)
        + startup cost of qual and tlist
        + run / (rows + 1)          -- both streams advance to the first match
total   = startup + run
```

- **Index entries**: each side's entries are estimated from its equalities
  (`clauselist_selectivity`); a partial index without equalities is read in
  full. `merge_read_cost` charges the denser stream at most 64 entries per
  entry of the sparser one plus a re-descent when the gap is longer by more
  than two leaf pages (skip-ahead; shorter gaps are read through, as the
  executor backs off from short skips), with index pages as in `genericcostestimate`
  (`random_page_cost` of the index's tablespace, Mackert–Lohman for repeated
  scans in a Nested Loop).
- **Heap pages**: as `cost_index` charges them, interpolated by the squared
  correlation that `btcostestimate` uses for an Index Scan on the outer index
  (its leading column, ×0.75 for a multicolumn index). The node visits the
  same heap rows in the same order as that Index Scan, so both are charged
  alike; the node wins only by fetching fewer rows.
- `LIMIT` is applied by the planner: `startup + (total − startup) × fraction`.

**Documented assumptions**: matches are spread evenly along both indexes, and
a TID group has the average size (`inner entries / ndistinct(sortcol)`). Real
data is often skewed — deleted rows only among old ids — and then the model
underestimates how much skip-ahead saves; see Known limitations.

## Known limitations and planned improvements

### Current limitations

Verified against `src/leapfrog.c` and the tests.

**Index pairs**

- Exactly two streams; a third condition is checked as a `Filter` on the heap
  row.
- The outer index ends with `sortcol` and has at least one equality column; the
  inner one starts with equality columns, then `sortcol`, and must narrow the
  outer stream down (be partial, or add an equality column).

**Data types and conditions**

- `bigint` columns only, `integer_ops` operator family only
  (`is_usable_btree`). `int2`/`int4` constants and parameters are accepted, but
  `int4`, `uuid` and other column types are not.
- Equality (`=`) only on the equality columns; `IN (…)`, ranges and `IS NULL`
  are not supported.
- The sort column must be `NOT NULL` according to the planner
  (`RelOptInfo.notnullattnums`); dead index entries with NULL are skipped.
- Both indexes: nbtree v4, `ASC` columns. `ORDER BY … DESC` is a backward scan.

**Planner and cost model**

- Each index is checked once per planned relation; pairs are formed only from
  the indexes that can return the sort column in order with their equalities
  fixed, and the `ndistinct` of the sort column, the outer correlation and the
  nbtree version are looked up once. Measured with
  `tests/performance/planning_bench.sh` (median of 200 plans, 20,000 rows,
  laptop):

  | Indexes | Equalities | Without, ms | With, ms | Before the cache, with, ms |
  |---:|---:|---:|---:|---:|
  | 10 | 1 | 0.067 | 0.074 | 0.093 |
  | 10 | 6 | 0.096 | 0.160 | 0.227 |
  | 20 | 6 | 0.104 | 0.138 | 0.193 |
  | 50 | 2 | 0.184 | 0.181 | 0.151 |
  | 50 | 6 | 0.226 | 0.248 | 0.298 |

  The cost still grows with the square of the number of indexes that match
  the query's equalities (6 in the last rows), not of all indexes; differences
  under 0.03 ms are within the noise of these runs.
- Only the first key of the query's `ORDER BY` is considered.
- The cost model is conservative. On the 1M-row benchmark (192 queries) it
  never picked the node where it was slower, at either page cost — and it did
  not pick it at all: in 38–48 queries the forced node was more than 15 %
  faster than the planner's choice. In the largest of these misses the stock
  planner itself chose a poor `BitmapAnd` (12 ms where another stock plan on the
  same indexes takes 1.6 ms); the node's own clear misses are 1.5–3× on
  deleted rows of skewed data and on two ordinary indexes.
- One relation per node; no partitioned tables, no parallel execution.

**Executor and memory**

- The inner entries of a value are materialised (`collect_group`): 6-byte TIDs,
  doubling up to `work_mem`, `qsort` and `bsearch`. A group larger than
  `work_mem` falls back to fetching every outer row of the value.
- Skip-ahead thresholds were measured with data in memory
  (`tests/performance/skip_bench.sh`, buffer counts); a cold-cache run needs
  the OS page cache dropped between runs and has not been made. The landing
  check reads nbtree's scan position (`BTScanOpaque`), so it depends on that
  internal structure of PostgreSQL 18.

**Tests and benchmarks**

- `VACUUM` while the node's scan is positioned on a leaf page is not in the
  isolation tests: `isolationtester` does not see buffer pin waits. It was
  checked by hand (see Known issues).
- Benchmarks ran on one laptop with data in memory; timings vary up to 2×
  between runs. Cold-cache and 10M+ row runs have not been made.

### Roadmap

The examples use a neutral schema: `orders` with `customer_id`, `product_id`
and `deleted_at`.

| Priority | Improvement | Status |
|---|---|---|
| P1 | Two ordinary B-tree indexes | **done** (unreleased): `(customer_id, id)` ∩ `(product_id, id)` |
| P1 | Adaptive skip-ahead | **done**: per-side threshold from 64, doubled by short skips; cold-cache measurement open |
| P1 | Cost model | partly: correlation as for the outer Index Scan, skip-aware reads; distribution of matches along `sortcol` open |
| P2 | N-way intersection | open |
| P2 | Planner search | **done**: per-index checks and lookups cached per relation, measured with 10/20/50 indexes; pathkeys beyond `ORDER BY` open |
| P2 | Memory of non-unique keys | open |
| P2 | Concurrency tests | **done**: EPQ for both pair kinds, partial outer index, overflow fallback; `INSERT`, `VACUUM` |
| P2 | Write and storage benchmarks | **done**: `write_bench.sh` |
| P3 | More types and conditions | open |

#### Cost model: distribution of matches along the sort column

The main reason for the misses above. Estimate how many entries each stream
reads before `LIMIT N` matches from where the conditions' rows lie along
`sortcol` — histograms of `sortcol` per condition, MCV lists, extended
statistics (`CREATE STATISTICS … (dependencies, mcv)`) — instead of an even
spread, and cost skip-ahead on the real gaps. Acceptance: on the benchmark
matrix, at both page costs, no case where the node is chosen and is clearly
slower, and fewer missed cases than the 38–48 of 192 today.

#### Adaptive skip-ahead

Done: each side starts at 64 entries; a skip that lands on the leaf page it
left or the next one doubles the side's threshold, a longer one halves it.
Measured on 1M rows with thresholds 16–2048 (`skip_bench.sh`, buffers):

| Gaps between matches | No skipping | Fixed 1,024 (0.0.1) | Fixed 128 | Adaptive from 64 |
|---|---:|---:|---:|---:|
| even, ~50 entries | 5,562 | 5,562 | 7,702 | 5,571 |
| clusters every 1,000 entries | 2,518 | 2,592 | 2,361 | 2,245 |
| clusters every 10,000 entries | 1,975 | 410 | 236 | 221 |
| clusters every 100,000 entries | 1,922 | 44 | 26 | 24 |
| same, `LIMIT 100` | 438 | 94 | 57 | 54 |

Open: a cold-cache run, where a descent costs reads rather than buffer hits.

#### N-way intersection

```sql
-- (customer_id, id), (product_id, id), (id) WHERE deleted_at IS NULL
SELECT * FROM orders
WHERE customer_id = 100 AND product_id = 200 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

Generalise the merge to k streams (advance the minimum, match by TID across
all of them), with the planner adding streams greedily by selectivity and a
bound on their number.

#### Planner search

Done: indexes are checked once per relation, `ndistinct`, correlation and
nbtree version are cached, planning time is measured with 10, 20 and 50
indexes. Open: consider useful pathkeys beyond the query's `ORDER BY`.

#### Memory of non-unique keys

A streaming match without materialising the group when both streams return the
TIDs of a value in TID order (a forward scan with all other key columns fixed;
backward scans and posting lists to be verified against nbtree first).

#### More types and conditions

`int4`, `uuid` and other B-tree operator families through operators looked up
from the index's operator family; `IN (…)` as several outer scans merged in
`sortcol` order; composite sort keys. A range on a leading column breaks the
`sortcol` order and can only be supported as several per-value scans.

## Known issues

- **Row position under EvalPlanQual.** When a concurrent transaction changes
  the sort column of a row that `SELECT … FOR UPDATE` has already matched,
  PostgreSQL rechecks the search condition on the new version but not the
  order: the row is returned at its old position with the new `id`. Every
  PostgreSQL plan behaves this way; `leapfrog_concurrent_update` records
  identical output for the node and the stock plan.
- **VACUUM waits for a scan in progress.** The node reads the sort value from
  the index tuple, so nbtree keeps the scan's current leaf page pinned, as for
  an Index Only Scan. `VACUUM` of that index waits until the scan moves to the
  next page or ends — for example behind a cursor left open in the middle of
  its result. When the merge ends both scans release their pages, so an
  exhausted cursor does not hold `VACUUM` (`leapfrog_insert_vacuum`).
- **Misses of the cost model**, see above. `leapfrog.force` shows what the node
  would do; it does not guarantee the node is chosen (a parameterization the
  join order cannot provide, for example).

## Operational safety

- Planner: the hook only adds paths through `add_path`; stock paths are never
  removed or changed. With `leapfrog.enabled = off` the hook returns
  immediately.
- Executor: index scans use the standard `index_beginscan` / `index_rescan` /
  `index_getnext_tid` / `index_fetch_heap` with the query's snapshot;
  visibility, HOT chains and `kill_prior_tuple` work as for `Index Scan`.
- Memory: the TID group array grows by doubling up to `work_mem` and never
  beyond; the per-row context is reset after every check in the fallback
  (`leapfrog_memory`). Long merges call `CHECK_FOR_INTERRUPTS()` every 1,024
  iterations, so `statement_timeout` and cancellation work.
- Plan cache: creating or dropping either index invalidates cached plans
  through its table, as for an `Index Scan` (`leapfrog_parameters`).
- The extension creates no tables, writes nothing to the catalog and needs no
  superuser rights to be used.
- Never overwrite the installed `leapfrog.so` in place; see
  [Loading the library](#loading-the-library).

## License

[PostgreSQL License](LICENSE). The merge algorithm is modelled on the
description of MySQL's index merge intersection; the code was written
independently and contains no MySQL code.
