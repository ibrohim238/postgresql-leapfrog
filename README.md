# postgresql-leapfrog

**Fewer indexes, cheaper writes, ordered reads by composition.** A PostgreSQL 18
extension that lets the planner combine general B-tree indexes at query time
— `(customer_id, id)` with `(product_id, id)`, or with a shared
`(id) WHERE deleted_at IS NULL` — into one ordered stream, so that a table does
not need a dedicated composite or partial index for every filter combination.

Status: **experimental (0.0.3)**. The executor is covered by regression and
isolation tests that compare every result with the stock plans
(see [Tests](#tests)). The cost model is conservative: in the measured
benchmarks it picked the node where it was slower only in `LIMIT 1` queries,
by under 0.1 ms, and it misses a part of the cases where the node is faster
(see
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

leapfrog adds the missing plan node: an ordered intersection of two or more
B-tree indexes that stops early at `LIMIT` and visits the heap only for rows
that passed all of them.

## Why index composition matters

Measured with [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh):
500,000 rows, 12 filter columns of 100 values each, soft deletes, then writes
of 100,000 rows; PostgreSQL 18.6 in Docker on a laptop
(details and caveats in [BENCHMARKS.md](BENCHMARKS.md)).

- **S, specialised**: per filter column `(fK, id) WHERE deleted_at IS NULL` and
  `(fK, id) WHERE deleted_at IS NOT NULL`, plus composite indexes for frequent
  combinations — 6 pairs, 2 triples, 1 quadruple — **33 indexes**.
- **G, general**: per filter column `(fK, id)`, plus `(id) WHERE deleted_at IS
  NULL` and `(id) WHERE deleted_at IS NOT NULL` — **14 indexes**; read with
  stock PostgreSQL or with leapfrog (**G+L**), which combines 2–4 of them per
  query.

Storage and writes (index size and WAL are deterministic; rows per second vary
up to 2× between runs on this machine):

| | S (33 indexes) | G (14 indexes) | G vs S |
|---|---|---|---|
| Index size, excluding PK | 375 MB | **201 MB** | −46 % |
| `INSERT` 100,000 rows: WAL | 481 MB | **159 MB** | −67 % |
| `INSERT`: rows per second | 4,035 | **23,017** | 5.7× faster |
| `UPDATE` of a filter column: WAL | 291 MB | **73 MB** | −75 % |
| `UPDATE` of `deleted_at` (soft delete): WAL | **82 MB** | 91 MB | +11 % |
| `DELETE`: WAL | 18 MB | 18 MB | same |

Reads, `LIMIT 100`, median time, `random_page_cost = 1.1` (data in memory):

| Query | S | G stock | G+L (planner, indexes) |
|---|---|---|---|
| one filter, live rows | **0.06 ms** | 0.06 ms | 0.07 ms |
| one filter, deleted rows | **0.13 ms** | 1.35 ms | 0.57 ms (2) |
| 2 filters, composite index in S | **0.07 ms** | 1.48 ms | 0.68 ms (2) |
| 2 filters, no composite in S | 5.56 ms | 1.48 ms | **0.65 ms** (2) |
| 3 filters, composite index in S | **0.02 ms** | 1.49 ms | 0.62 ms (2) |
| 3 filters, no composite in S | 5.98 ms | 1.48 ms | **0.62 ms** (2) |
| 4 filters, composite index in S | **0.04 ms** | 1.43 ms | 0.80 ms (3) |
| 4 filters, no composite in S | 6.76 ms | 1.59 ms | **0.63 ms** (2) |

What this shows, plainly:

- The write side is the reason to compose: half the index storage, a third of
  the WAL on inserts, and inserts several times faster — and S grows with
  every combination of filters it serves, G does not.
- A dedicated index is still the fastest read for the exact query it was built
  for. Composition trades that for fewer indexes; the specialised scheme pays
  3–7 ms whenever a combination has no index of its own.
- With general indexes, leapfrog answers every combination of 2, 3 and 4
  filters in 0.6–1.0 ms, chosen by the planner, 2–3× faster than stock
  PostgreSQL on the same indexes. It picks a third index where the cost model
  sees it pay and stays with two where it does not (the default page cost
  and more results in BENCHMARKS.md).

## How Index Merge Intersect works

For every base relation of the query the planner looks for a set of two or
more indexes to intersect, called streams:

- the **outer** B-tree `(k1, …, kN, sortcol)`: every `kI` is compared for
  equality with a value known when the scan starts, as for an `Index Cond`:
  a constant, a parameter, a column of an outer relation, or a
  non-volatile expression of those (`$1 || $2`, `lower(o.email)`), and the
  last column is the first sort key of the query;
- one or more **inner** B-trees `(j1, …, jM, sortcol, …)` with an equality on
  every `jI`. With `M = 0` it must be a partial index whose predicate is
  implied by the query (`(id) WHERE deleted_at IS NULL`).

Every stream of a set, the outer one included, must add a restriction the
others do not enforce: an equality column no other stream has
(`(product_id, id)` next to `(customer_id, id)`), or a predicate that the other
streams' equalities and predicates together do not imply. So
`(membership_id, id)` and `(membership_id, id) WHERE deleted_at IS NULL` never
form a set — the partial index alone is the plan — and neither do `(kind, id)`
with `kind = 2` and `(id) WHERE kind = 2`. A plain `(id)` never joins a set.

The planner offers every pair of an outer and an inner candidate, then from
the cheapest pair adds one stream at a time — the one that lowers the
estimated cost the most — as long as one does and `leapfrog.max_indexes`
(default 4) allows. Each set is a separate path with its own cost, and
PostgreSQL picks among them and the stock plans as usual: a third index is
used where fetching the rows the pair leaves costs more than reading the
third stream, and left out — its condition becomes a `Filter` — where it
does not.

With every column before `sortcol` fixed, every scan returns its entries in
`sortcol` order. The executor reads them as sorted streams in the `ORDER BY`
direction and advances every stream that lags behind the frontmost value
until all of them meet. Once a stream has read 64 entries in a row without
catching up, it descends its B-tree again straight to the frontmost value
(**skip-ahead**, `index_rescan` with `sortcol >= value`) instead of reading
the gap. The threshold adapts per stream: a skip that lands on the leaf page
it left or on the next one did not pay for its descent and doubles it (up to
64×); a longer skip halves it back. Clustered gaps are skipped early, evenly
spread matches are read through.

When the values meet, the entries are matched **by heap TID**: each inner
stream's entries of the value are collected into a sorted group and the outer
entries are looked up in every group. This is MySQL's index merge
intersection (`RowIDIntersectionIterator`) adapted to nbtree; matching by TID
keeps the merge correct for a non-unique `sortcol` and for dead row versions
still in the indexes. A matched row is fetched with `index_fetch_heap`,
following the HOT chain as `index_getnext_slot` does.

The TID groups together are bounded by `work_mem`, each by its share. When a
value has more entries in an inner stream, that group is dropped, every outer
row of the value that the other groups accept is fetched and the stream's
conditions — its equalities and its predicate — are checked on the row.
Under EvalPlanQual the node rechecks every stream's conditions on the new
row version, as `Index Scan` rechecks `indexqualorig`.

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

Tests in one command (starts a server in a Compose project of its own,
`leapfrog-test-<pid>-<random>`, on a free port of 127.0.0.1, runs regression
and isolation suites in a separate container, and removes that project with
its volume; the default project, servers kept by earlier runs and their data
are not touched; `--keep` prints the port and the command that stops it):

```bash
bash tests/run-in-docker.sh          # or: make docker-test
bash tests/run-in-docker.sh --keep   # keep the server running
```

`run-in-docker.sh` needs Docker Compose 2.24.4 or later, for `!override` in
`tests/compose.test.yaml`. `COMPOSE_TEST_PROJECT` sets the project name; a
project that already has containers or volumes is refused.

Benchmarks (`bench` profile, 100k and 1M rows by default):

```bash
docker compose up -d --build --wait
docker compose --profile bench run --rm bench
# results: tests/performance/results/<timestamp>/
```

Every benchmark script writes into a new directory, `results/<timestamp>/`
or `results/<kind>-<timestamp>/`, or into `BENCH_OUT`, and refuses to run
when that directory already exists rather than mix two runs. `make
bench-smoke` writes into a temporary directory and removes it afterwards.

The scripts drop and recreate tables such as `orders`, so they never run in
`PGDATABASE`: they run in a database of their own, `BENCH_DB` (default
`leapfrog_bench`), which they create with the comment `leapfrog benchmark
scratch database` and keep for the next run (`dropdb leapfrog_bench` removes
it). An existing database without that comment is refused before anything
is dropped. One benchmark runs at a time per database: a run holds an
advisory lock in `BENCH_DB` until it ends, however it ends, and a second one
started meanwhile is refused (two would drop each other's tables, and
benchmarks on one server disturb each other's timings anyway); set
`BENCH_DB` to another name to run one elsewhere. `make bench-smoke` uses
`leapfrog_bench_smoke` and drops it afterwards, also one left by an earlier
run, but only with the mark.

Compose environment variables: `LEAPFROG_PORT` (5433), `LEAPFROG_BIND`
(127.0.0.1: the server is reachable from this machine only, since the
password is well known; `0.0.0.0` publishes it on every interface),
`POSTGRES_PASSWORD` (`leapfrog`), `LEAPFROG_SHARED_BUFFERS` (512MB),
`BENCH_SIZES`, `BENCH_REPEATS`.

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
| `leapfrog.force` | `off` | `USERSET` | The node is preferred over every other plan whenever a suitable set of indexes exists (the counterpart of MySQL's `INDEX_MERGE` hint); among several sets the cheapest still wins. The plan-time check of the group estimate against `work_mem` is skipped as well. **Diagnostic setting**: it can make a query many times slower. |
| `leapfrog.max_indexes` | `4` | `USERSET` | The most indexes one node combines (2–16). Streams are added one at a time while each lowers the estimated cost, so the limit only caps the search. |
| `leapfrog.min_indexes` | `2` | `USERSET` | Developer setting: smaller sets are not offered and the set that reaches the size is offered whatever its cost, so that a larger set can be run against the stock plans (the tests use it). Not in `postgresql.conf.sample`. |
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
| `Outer Index` / `Inner Index` | the chosen indexes; separate properties in `FORMAT JSON/YAML/XML`. With more than two, the further inner streams are `Inner Index 2`, `Inner Index 3`, …, and their counters below carry the same suffix (`Inner Entries Read 2`). |
| `Filter` | conditions the node checks on the row. The equalities of every stream and conditions implied by an inner predicate are not in `Filter` (like `Index Cond` of an Index Scan); the exception is the target relation of `UPDATE/DELETE/SELECT FOR UPDATE`, where predicate-implied conditions are kept for EvalPlanQual. |
| `Outer Entries Read` / `Inner Entries Read` | entries read from each index, including dead entries with a NULL sort value that are skipped. |
| `Outer Entries Estimated` / `Inner Entries Estimated` | with `VERBOSE` (and costs on): the entries the cost model expected each stream to read, to set against the counters above. `tests/performance/cost_bench.sh` records both and their ratio per query. |
| `Matched TIDs` | entries found by TID in every stream. |
| `Heap Fetches` | `index_fetch_heap` calls (including HOT chain continuations). |
| `Rows Removed by Filter` | the standard counter of rows dropped by `Filter`. |
| `Peak Group Memory` | largest total capacity of the TID group arrays, bytes. |
| `Skips` | re-descents of a lagging scan to the frontmost value. |
| `Short Skips` | skips that landed on the leaf page they left or the next one; each doubles that stream's threshold (see Skip-ahead). |
| `Group Overflows` | how many times a value's group exceeded its share of `work_mem` and the node fell back to checking that stream's conditions on the row. |
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
| `leapfrog_memory` | peak backend memory of the overflow fallback and of 40,000 rescans with 3 kB `text` values (Linux) |
| `leapfrog_explain` | every `EXPLAIN` format, `ANALYZE` counters, each cost model input moving the estimate in the right direction |
| `leapfrog_example` | the example above verbatim, with the planner's choice at both page costs |
| `leapfrog_btree_pair` | two ordinary indexes `(customer_id, id)` and `(product_id, id)`: both directions, parameters on either side, partial index with an equality prefix, pairs that must not be formed, the overflow fallback checking the inner equality |
| `leapfrog_skip` | skip-ahead on both sides, both directions, non-unique sort column, rescans, dead entries; `leapfrog.skip_after` 0 and 1; the adaptive threshold backing off on evenly spread matches and staying low on long gaps |
| `leapfrog_outer_partial` | partial index on the outer side: its predicate's conditions stay in the `Filter`, plain and `FOR UPDATE`, rows that left the index |
| `leapfrog_nway` | three, four and five streams against the stock plans, both directions, `LIMIT`; the planner adding a third stream only where it is estimated cheaper and never beyond `leapfrog.max_indexes`; generic plans and `LATERAL` rescans; a non-unique sort column across three groups; two groups overflowing `work_mem`; rows moving between the streams; `FOR UPDATE` |
| `leapfrog_types` | `uuid`, `text`, `varchar` (with a `text` constant), `smallint` (with a `bigint` constant) and `timestamptz` equality columns, three streams of three types; generic plans with `text` and `uuid` parameters and `NULL`; `LATERAL` rescans with changing `text` and `uuid` values; an inner `text` group overflowing `work_mem`; `smallint` and `integer` sort columns in both directions; values computed from parameters, from a join's other side and from `LATERAL` columns, a volatile value left to the stock plan; long `text` values compressed in the index, HOT updates of matched rows; sort columns of domains over `bigint` and `integer`; an index in another collation than the condition's |

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
| `leapfrog_nway` | EvalPlanQual with three streams: the second stream's column, the third stream's predicate and an unrelated column changing while `FOR UPDATE` waits |
| `leapfrog_types` | EvalPlanQual with `text` and `uuid` equalities: the status, the owner and an unrelated column changing while `FOR UPDATE` waits |

## Benchmarks

Run the benchmarks on a PostgreSQL instance of their own, never on a server
with real work on it: a database of their own isolates the data, not the
load. They write gigabytes of WAL at the default sizes, `write_bench.sh`
runs `CHECKPOINT` on the whole cluster, and `skip_bench.sh` with `COLD_CMD`
restarts the server and drops the OS page cache. The Docker server above,
or one started for the purpose, is the intended target.

```bash
bash tests/performance/write_bench.sh            # storage, writes and reads for 12 filter columns
bash tests/performance/run.sh                    # reads: 3 strategies, uniform and skewed, 1/10/50/90 % deleted
BENCH_RANDOM_PAGE_COST=1.1 bash tests/performance/run.sh
BENCH_SIZES="10000000" bash tests/performance/run.sh
bash tests/performance/cost_bench.sh             # cost model: estimate against time, skewed and correlated data
bash tests/performance/skip_bench.sh             # skip-ahead thresholds: buffers and entries read
bash tests/performance/planning_bench.sh         # planning time: 10/20/50 indexes on the table, 1/2/6 used by the query
BENCH_LABEL=old BENCH_OUT=results/types-old bash tests/performance/types_bench.sh   # equality types, one build
bash tests/performance/types_compare.sh tests/performance/results/types-old tests/performance/results/types-new
```

Both scripts record `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` after a warm-up,
with a fixed seed, into CSV files; `summarize.sh` prints a summary. Results:
[BENCHMARKS.md](BENCHMARKS.md).

## Cost model

The structure follows MySQL's `ROR_intersect_plan::add`; the components are
PostgreSQL cost functions:

```text
read    = entries of each stream inside the overlap of their sortcol ranges
matches = rows × outer share × inner share / table share of the overlap
run     = merge_read_cost(outer read, inner read)
        + group_cost(outer + inner read, log2(group size))
        + heap_fetch_cost(matches)
        + matches × (cpu_tuple_cost + qual cost + tlist cost)
        + one descent per stream that skips into the overlap
startup = descent into both B-trees (as in btcostestimate)
        + startup cost of qual and tlist
        + run / (matches + 1)       -- both streams advance to the first match
total   = startup + run
```

- **Index entries**: each side's entries are estimated from its equalities
  (`clauselist_selectivity`); a partial index without equalities is read in
  full. `merge_read_cost` charges the denser stream at most 64 entries per
  entry of the sparser one plus a re-descent when the gap is longer by more
  than two leaf pages (skip-ahead; shorter gaps are read through, as the
  executor backs off from short skips), with index pages as in
  `genericcostestimate` (`random_page_cost` of the index's tablespace,
  Mackert–Lohman for repeated scans in a Nested Loop).
- **Where the streams meet**: when every equality value is a constant, the
  planner reads the smallest and the largest sortcol value of each stream
  from its index (one descent from each end, like `get_actual_variable_range`
  for the selectivity functions; entries of any visibility, so a dead entry
  at an end only widens the range). Only the overlap of the two ranges is
  read — the rest is skipped — and matches can only lie there. The shares of
  each stream and of the table inside the overlap come from the sortcol
  histogram, with each stream assumed to follow the table's distribution
  within its own range; the planner's row estimate (conditions independent
  over the whole table) becomes one where they are independent inside the
  overlap. Disjoint ranges cost next to nothing. A parameterized path or a
  generic plan is costed without the probe. Like any plan built on actual
  values, a cached plan with constants keeps this estimate until it is
  replanned.
- **Group size**: inner entries / the number of distinct sortcol values in
  the table (`get_variable_numdistinct`). Each entry pays log2(group size)
  TID comparisons at 0.1 × `cpu_operator_cost`, the rate
  `cost_bitmap_tree_node` charges per TID of a bitmap: the comparisons are
  inline, not operator calls. Measured on two ordinary indexes (15,000
  entries, 118 buffers, the same as `BitmapAnd`): the node runs 3× faster
  than `BitmapAnd`, and a full `cpu_operator_cost` per comparison had made it
  the dearer plan by 4 %.
- **Heap pages**: as `cost_index` charges them, interpolated by the squared
  correlation that `btcostestimate` uses for an Index Scan on the outer index
  (its leading column, ×0.75 for a multicolumn index). The node visits the
  same heap rows in the same order as that Index Scan, so both are charged
  alike; the node wins only by fetching fewer rows.
- `LIMIT` is applied by the planner: `startup + (total − startup) × fraction`,
  where fraction is `LIMIT` over the planner's row estimate of the relation,
  not over `matches`.

**Documented assumptions**: inside the overlap, matches are spread evenly
along both indexes, and a TID group has the average size. Skew inside the
overlap, and the correlation of a filter with the sort column, are not seen —
by the node or by PostgreSQL's own estimate of the stock plans; see Known
limitations.

## Known limitations and planned improvements

### Current limitations

Verified against `src/` and the tests.

**Index sets**

- Up to `leapfrog.max_indexes` streams (default 4, at most 16), added
  greedily: from the cheapest pair, the stream that lowers the cost the most,
  while one does. A set the greedy order never reaches is not considered.
- The outer index ends with `sortcol` and has at least one equality column;
  every inner one starts with equality columns, then `sortcol`. Every stream
  must add an equality column or a predicate the other streams do not
  enforce; implication is proved with `predicate_implied_by`, so an
  equivalent condition the prover cannot see through keeps a redundant
  stream (it is then only costed, not wrong).
- The stream conditions are assumed independent of each other inside the
  overlap of their sort ranges, as PostgreSQL assumes for `BitmapAnd`.

**Data types and conditions**

- Equality columns: any type whose index column has a B-tree operator family
  (`uuid`, `text`, `varchar`, `smallint`, `integer`, `bigint`, `timestamptz`,
  …), as for an `Index Cond`. The operator is looked up in the index column's
  family, cross-type ones included (`varchar = text`, `smallint = bigint`); a
  `text` column indexed in another collation than the condition's is not
  used. Expression index columns are not supported.
- Sort column: `smallint`, `integer` or `bigint` (`integer_ops`). Other sort
  types (`timestamptz`, `numeric`, `uuid`) are not supported yet.
- Equality (`=`) only on the equality columns; `IN (…)`, ranges and `IS NULL`
  are not supported.
- The sort column must be `NOT NULL` according to the planner
  (`RelOptInfo.notnullattnums`); dead index entries with NULL are skipped.
- Both indexes: nbtree v4, `ASC` columns. `ORDER BY … DESC` is a backward scan.

**Planner and cost model**

- **Planning time depends on the candidates, not on how many indexes the
  table has.** The planner looks at every index of the table once, but only
  at its metadata (access method, key columns, operator family, predicate
  proven by the planner already): an index whose columns before the sort
  column are not all fixed by the query's equalities is dropped there, at
  the cost of a loop over a few arrays. On a table with 50 indexes and a
  query that uses 2 of them, 48 are dropped this way and never costed,
  probed or combined.

  The expensive work — reading each candidate's sort range from its B-tree,
  the histogram lookups, costing the sets — is done only for the remaining
  candidates. Every pair of candidates is costed; only the cheapest pair is
  then grown, one stream per round, so a set of k streams costs k − 2 more
  rounds over the candidates, not every combination.

  Measured with `tests/performance/planning_bench.sh` (median of 100 plans,
  20,000 rows, constants in the query, laptop). Every query also has
  `deleted_at IS NULL`, so the indexes it can use are one per equality plus
  `(id) WHERE deleted_at IS NULL`. That column is what the time follows; the
  number of indexes on the table barely changes it:

  | Indexes on the table | Equalities | Indexes the query can use | Stock, ms | With leapfrog, ms |
  |---:|---:|---:|---:|---:|
  | 10 | 1 | 2 | 0.05 | 0.27 |
  | 50 | 1 | 2 | 0.13 | 0.25 |
  | 10 | 2 | 3 | 0.10 | 0.35 |
  | 50 | 2 | 3 | 0.15 | 0.30 |
  | 10 | 6 | 7 | 0.11 | 0.86 |
  | 50 | 6 | 7 | 0.19 | 0.94 |

  Where the time goes, from a profile of one plan on another table: 4
  equalities and `deleted_at IS NULL`, 5 usable indexes (the primary key
  passes the metadata check too but forms no set), 16 pairs and 5 larger
  sets costed. Of the 0.66 ms leapfrog adds, 0.17 ms read the candidates'
  sort ranges from their B-trees, 0.40 ms turn those ranges into shares of
  the table through the histogram, 0.04 ms cost all 21 sets, and the
  metadata loop over all of the table's indexes takes 0.003 ms. A generic
  plan, whose parameters leave no range to read, adds 0.06 ms with the same
  candidates. Timings vary up to 2× between runs.

  The previous version recomputed the histogram shares for every pair:
  with 7 usable indexes it took 5.2 ms (10 on the table) and 2.7 ms (50).
- Only the first key of the query's `ORDER BY` is considered.
- The cost model is conservative. On the 1M-row benchmark (192 queries,
  `tests/performance/choices.sql`) the planner picks the node 2 times at
  `random_page_cost = 4` and 5 times at 1.1; it is clearly slower only in
  `LIMIT 1` queries (by 0.02–0.09 ms, 1 and 4 cases). It misses the node in
  27 and 21 queries where the node is more than 15 % faster than both the
  planner's choice and the stock plan on `(customer_id, id)`. Most of these
  are deleted rows (1 % uniform: 0.5 ms against 0.7–1.7 ms; skewed, `LIMIT
  1000`: 1.1 ms against 2–8 ms). `EXPLAIN (VERBOSE)` shows the entries the
  model expected against the entries read; in these misses they agree within
  a few percent, so the cause is in how PostgreSQL costs the competing
  plans: their estimates assume the filter is spread evenly along `id` (a
  partial index scan filtering the customer is estimated at 4 for 2 ms of
  work), and the heap correlation of a multicolumn index is taken as its
  leading column's × 0.75, as `btcostestimate` does.
- One relation per node; no partitioned tables, no parallel execution.

**Executor and memory**

- The inner entries of a value are materialised (`collect_group`): 6-byte TIDs,
  doubling up to `work_mem`, `qsort` and `bsearch`. A group larger than
  `work_mem` falls back to fetching every outer row of the value.
- Skip-ahead thresholds were measured warm and with shared buffers emptied
  before every run (`tests/performance/skip_bench.sh`); a run with the OS page
  cache dropped as well needs root on the database host (`COLD_CMD`) and has
  not been made. The landing check reads nbtree's scan position
  (`BTScanOpaque`), so it depends on that internal structure of
  PostgreSQL 18.

**Tests and benchmarks**

- `VACUUM` while the node's scan is positioned on a leaf page is not in the
  isolation tests: `isolationtester` does not see buffer pin waits. It was
  checked by hand (see Known issues).
- Benchmarks ran on one laptop with data in memory; timings vary up to 2×
  between runs. Runs with the OS page cache dropped and 10M+ row runs have
  not been made.

### Roadmap

The examples use a neutral schema: `orders` with `customer_id`, `product_id`
and `deleted_at`.

| Priority | Improvement | Status |
|---|---|---|
| P1 | Two ordinary B-tree indexes | **done** (0.0.2): `(customer_id, id)` ∩ `(product_id, id)` |
| P1 | Adaptive skip-ahead | **done**: per-side threshold from 64, doubled by short skips; measured warm and with shared buffers emptied; OS-cold run open |
| P1 | Cost model | **done** for the node's own estimate: correlation as for the outer Index Scan, skip-aware reads, group size from `ndistinct`, actual sort ranges of both streams, rows = expected matches; the remaining misses come from the estimates of the competing stock plans |
| P2 | N-way intersection | **done**: up to `leapfrog.max_indexes` streams, added while each lowers the estimated cost |
| P2 | Planner search | **done**: per-index checks and lookups cached per relation, measured with 10/20/50 indexes; pathkeys beyond `ORDER BY` open |
| P2 | Memory of non-unique keys | open |
| P2 | Concurrency tests | **done**: EPQ for both pair kinds, partial outer index, overflow fallback; `INSERT`, `VACUUM` |
| P2 | Write and storage benchmarks | **done**: `write_bench.sh` |
| P3 | More types and conditions | **partly**: equality columns of any B-tree type, integer sort columns of every width; other sort types and `IN (…)` open |

#### Cost model: distribution of matches along the sort column

Done: the planner probes the actual smallest and largest sort value of each
stream and costs only the overlap, with the matches estimated there and used
as the path's row estimate. On `cost_bench.sh` (24 queries on skewed and
correlated data) the misses went from 18 to 11 at `random_page_cost = 4` and
from 16 to 9 at 1.1; on the 1M-row matrix from 32 to 27 and from 21 to 21.
Then, with the estimated entries shown next to the entries read, the one
component of the node's own cost that disagreed with the measurement was
found and fixed: TID comparisons in a group were charged as operator calls,
ten times the rate PostgreSQL charges the same work in a bitmap, which made
the node dearer than `BitmapAnd` on identical page reads. On `cost_bench.sh`
(32 queries, now with pairs of ordinary indexes) the misses went from 14 to 10
at `random_page_cost = 4` and from 17 to 6 at 1.1.

Not done, on purpose: estimating the density of the streams inside the
overlap by more probes. In the remaining misses the entries estimate is within
a few percent of the entries read; the competing stock plans are estimated
too cheaply (see Current limitations), and lowering the node's cost further
would be fitting the benchmark.

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

With shared buffers emptied before every run (`COLD_CMD` running
`pg_buffercache_evict_all()`; the OS cache stays warm), blocks read into
shared buffers:

| Gaps between matches | No skipping | Fixed 1,024 | Adaptive from 64 |
|---|---:|---:|---:|
| even, ~50 entries | 5,555 | 5,555 | 5,555 |
| clusters every 1,000 entries | 2,511 | 2,511 | 1,246 |
| clusters every 10,000 entries | 1,968 | 311 | 122 |
| clusters every 100,000 entries | 1,917 | 33 | 13 |
| same, `LIMIT 100` | 433 | 69 | 29 |

Open: a run with the OS page cache dropped too (`COLD_CMD`, needs root on
the database host), where every block read is a device read.

#### N-way intersection

```sql
-- (customer_id, id), (product_id, id), (id) WHERE deleted_at IS NULL
SELECT * FROM orders
WHERE customer_id = 100 AND product_id = 200 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

Done: the merge advances every stream lagging behind the frontmost value and
matches an outer entry by TID against every inner group; the planner adds
streams greedily by estimated cost with `leapfrog.max_indexes` as the bound.
The third stream pays where the pair leaves many rows to fetch and the third
condition removes most of them; where it removes few (live rows at a 10 %
soft-delete rate) the planner keeps the pair and the `Filter`. Measured in
`write_bench.sh` (see BENCHMARKS) and tested in `leapfrog_nway`
(regression and isolation).

#### Planner search

Done: indexes are checked once per relation and only those the query can use
go on to costing; `ndistinct`, correlation, nbtree version, sort ranges and
their shares are cached per index. Planning time is measured on tables with
10, 20 and 50 indexes and follows the number the query can use, not the
table's total. Open: the histogram shares of the sort ranges (most of what
remains), and useful pathkeys beyond the query's `ORDER BY`.

#### Memory of non-unique keys

A streaming match without materialising the group when both streams return the
TIDs of a value in TID order (a forward scan with all other key columns fixed;
backward scans and posting lists to be verified against nbtree first).

#### More types and conditions

Done: equality columns of any type with a B-tree operator family, with the
operator looked up in the index column's family and the row rechecks
(EvalPlanQual, overflow fallback) done with that operator and collation;
sort columns `smallint`, `integer` and `bigint`. Tested in `leapfrog_types`
(regression and isolation).

Open: sort columns of other types (`timestamptz`, `numeric`), to be measured
first, since the merge then compares values through the type's comparison
function instead of as `int64`; `IN (…)` as several outer scans merged in
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
