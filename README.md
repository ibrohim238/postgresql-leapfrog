# postgresql-leapfrog

**Fewer indexes, cheaper writes, ordered reads by composition.** A PostgreSQL 18
and 19 extension that lets the planner combine general B-tree indexes at query time
— `(customer_id, id)` with `(product_id, id)`, or with a shared
`(id) WHERE deleted_at IS NULL` — into one ordered stream, so that a table does
not need a dedicated composite or partial index for every filter combination.
It is built for one narrow case: a list query with several equality filters
that each match many rows, a combination that matches few, and `ORDER BY id
LIMIT n`; everything else gets the stock plan.
No query changes: the planner picks the node where it is cheaper, per query and
with the current statistics, and `leapfrog.enabled = off` stops new plans from
using it (see [Operational safety](#operational-safety) for plans already cached).

Status: **experimental (0.0.5)**. The executor is covered by regression and
isolation tests that compare every result with the stock plans
(see [Tests](#tests)). The cost model counts pages first: with data in memory it
can pick the node over an Index Scan that touches more buffers but takes less time
(with `LIMIT 100` and both conditions dense), and it misses a
part of the cases where the node is faster (see
[Known limitations](#known-limitations-and-planned-improvements)).

## Contents

1. [The problem: one index per query shape](#the-problem-one-index-per-query-shape)
2. [What it looks like at 100M rows](#what-it-looks-like-at-100m-rows)
3. [Why index composition matters](#why-index-composition-matters)
4. [How Index Merge Intersect works](#how-index-merge-intersect-works)
5. [Example](#example)
6. [Compared with Index Scan and BitmapAnd](#compared-with-index-scan-and-bitmapand)
7. [Requirements](#requirements)
8. [Installation](#installation)
9. [Docker quick start](#docker-quick-start)
10. [Loading the library](#loading-the-library)
11. [Settings](#settings)
12. [Reading EXPLAIN](#reading-explain)
13. [Tests](#tests)
14. [Benchmarks](#benchmarks)
15. [Cost model](#cost-model)
16. [Known limitations and planned improvements](#known-limitations-and-planned-improvements)
17. [Known issues](#known-issues)
18. [Operational safety](#operational-safety)
19. [License](#license)

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

## What it looks like at 100M rows

The case this extension is for: a list query with several filters, each matching
many rows and the combination few, scattered over the table. Three cases of it
below, on one table: 100M rows, 12 GB, in random physical order, one row in 20
live. Indexes `(customer_id, id)`, `(product_id, id)`,
`(id) WHERE deleted_at IS NULL`. PostgreSQL 18.6 on a laptop, 0.0.5,
[`list_bench.sh`](tests/performance/list_bench.sh), which runs each scenario separately. Each table: median of 3 runs,
the slowest in brackets. Each plan: one run, so not the median; `read=` means pages
from disk. Exact index: built for the query. Stock: the planner's choice without
the extension. leapfrog: the planner's choice with it. Other runs:
[BENCHMARKS.md](BENCHMARKS.md#100m-rows-the-list-query-needles-and-the-middle-fed2cfb).

### Case 1: a large customer with few live rows

Scenario `large_customer`. The customer has
5M rows, 500 of them live: one in 10,000.

```sql
SELECT * FROM orders WHERE customer_id = $1 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

| Exact index | leapfrog | Stock | `BitmapAnd` |
|---:|---:|---:|---:|
| **0.20 ms** | **105 ms** (268 ms) | Index Scan 95.4 s (95.7 s) | 2.7 s (2.8 s) |

Stock walks the live rows expecting one in 20 to be this customer's, and fetches
934,625 of them for 100 results. The node reads the two indexes, 1.9M entries and
6,476 pages, and fetches the 100 rows it returns.

leapfrog, pages from disk:

```text
 Limit (actual time=4.534..877.096 rows=100.00 loops=1)
   Buffers: shared hit=9 read=6467
   ->  Custom Scan (Index Merge Intersect) on lf_list (actual time=4.530..876.883 rows=100.00 loops=1)
         Matched TIDs: 100
         Heap Fetches: 100
         Peak Group Memory: 96 B
         ->  Outer Stream on lf_list_customer_id_id_idx (actual time=0.017..660.711 rows=995834.00 loops=1)
               Index Cond: (customer_id = 5)
               Prefetches: 3816
               Buffers: shared hit=4 read=3815
         ->  Inner Stream on lf_list_id_idx (actual time=0.010..57.260 rows=934626.00 loops=1)
               Index Pred: (deleted_at IS NULL)
               Prefetches: 2555
               Buffers: shared hit=3 read=2554
         Buffers: shared hit=9 read=6467
 Planning:
   Buffers: shared hit=127 read=35
 Planning Time: 2.867 ms
 Execution Time: 877.432 ms
```

Stock:

```text
 Limit (actual time=543.008..96493.312 rows=100.00 loops=1)
   Buffers: shared hit=39340 read=897842
   ->  Index Scan Backward using lf_list_id_idx on lf_list (actual time=543.005..96493.092 rows=100.00 loops=1)
         Filter: (customer_id = 5)
         Rows Removed by Filter: 934525
         Index Searches: 1
         Buffers: shared hit=39340 read=897842
 Planning:
   Buffers: shared hit=125
 Planning Time: 1.077 ms
 Execution Time: 96493.583 ms
```

### Case 2: a smaller customer with few live rows

Scenario `small_customer`. The customer has
1M rows, 500 of them live: one in 2,000.

```sql
SELECT * FROM orders WHERE customer_id = $1 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

| Exact index | leapfrog | Stock | `BitmapAnd` |
|---:|---:|---:|---:|
| **0.19 ms** | **56 ms** (79 ms) | Index Scan 776 ms (1.1 s) | 772 ms (919 ms) |

Stock walks the customer's rows and fetches 198,190 of them. The node reads 1.1M
index entries and 3,409 pages, and fetches 100 rows.

leapfrog, pages from disk:

```text
 Limit (actual time=0.112..83.825 rows=100.00 loops=1)
   Buffers: shared hit=775 read=2634
   ->  Custom Scan (Index Merge Intersect) on lf_list (actual time=0.107..83.745 rows=100.00 loops=1)
         Matched TIDs: 100
         Heap Fetches: 100
         Peak Group Memory: 96 B
         Skips: 1
         Short Skips: 1
         ->  Outer Stream on lf_list_customer_id_id_idx (actual time=0.055..7.364 rows=198190.00 loops=1)
               Index Cond: (customer_id = 4)
               Prefetches: 760
               Buffers: shared hit=763
         ->  Inner Stream on lf_list_id_idx (actual time=0.012..45.285 rows=929756.00 loops=1)
               Index Pred: (deleted_at IS NULL)
               Skips: 1
               Short Skips: 1
               Prefetches: 2542
               Buffers: shared hit=5 read=2541
         Buffers: shared hit=775 read=2634
 Planning:
   Buffers: shared hit=138 read=24
 Planning Time: 5.736 ms
 Execution Time: 83.955 ms
```

Stock, pages from disk:

```text
 Limit (actual time=0.057..1554.814 rows=100.00 loops=1)
   Buffers: shared hit=9908 read=189048
   ->  Index Scan Backward using lf_list_customer_id_id_idx on lf_list (actual time=0.056..1554.596 rows=100.00 loops=1)
         Index Cond: (customer_id = 4)
         Filter: (deleted_at IS NULL)
         Rows Removed by Filter: 198090
         Index Searches: 1
         Buffers: shared hit=9908 read=189048
 Planning:
   Buffers: shared hit=125
 Planning Time: 0.606 ms
 Execution Time: 1554.999 ms
```

### Case 3: two filters and few live rows in common

Scenario `two_filters`. The customer has 1M rows and the product 2M; they share 20,012 rows, 11 of them live.

```sql
SELECT * FROM orders WHERE customer_id = $1 AND product_id = $2 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 100;
```

| Exact index | leapfrog | Stock | `BitmapAnd` |
|---:|---:|---:|---:|
| **0.03 ms** | **252 ms** (1.3 s) | `BitmapAnd` 746 ms (1.5 s) | 1.1 s (1.5 s) |

No `LIMIT` to stop at: 11 rows exist and the query asks for 100, so every plan reads
to the end. Stock picks `BitmapAnd`, which reads all 3M entries of both filters and
sorts. The node merges the same entries, fetches the 20,012 rows in common and keeps
the 11 live ones. The brackets are from disk, cache evicted before each run. Since the
`Filter` drops nearly every row, the node gathers matches ahead and asks for their heap
pages (`Heap Prefetches`): 1.3 s against 2.4 s without it. This is the edge of what the
node is for: a frequent query of this shape wants its exact index.

Both plans from disk. leapfrog:

```text
 Limit (actual time=33.289..1287.042 rows=11.00 loops=1)
   Buffers: shared hit=773 read=30743
   ->  Custom Scan (Index Merge Intersect) on lf_list (actual time=33.287..1287.024 rows=11.00 loops=1)
         Filter: (deleted_at IS NULL)
         Rows Removed by Filter: 20001
         Matched TIDs: 20012
         Heap Fetches: 20012
         Heap Prefetches: 20011
         Peak Group Memory: 96 B
         ->  Outer Stream on lf_list_product_id_id_idx (actual time=0.010..525.528 rows=2001433.00 loops=1)
               Index Cond: (product_id = 120)
               Prefetches: 7669
               Buffers: shared hit=5 read=7668
         ->  Inner Stream on lf_list_customer_id_id_idx (actual time=0.025..77.833 rows=999058.00 loops=1)
               Index Cond: (customer_id = 4)
               Prefetches: 3828
               Buffers: shared hit=5 read=3826
         Buffers: shared hit=773 read=30743
 Planning:
   Buffers: shared hit=128 read=44 dirtied=1
 Planning Time: 9.544 ms
 Execution Time: 1287.112 ms
```

Stock:

```text
 Limit (actual time=1543.183..1543.189 rows=11.00 loops=1)
   Buffers: shared hit=573 read=30828
   ->  Sort (actual time=1543.181..1543.184 rows=11.00 loops=1)
         Sort Key: id DESC
         Sort Method: quicksort  Memory: 26kB
         Buffers: shared hit=573 read=30828
         ->  Bitmap Heap Scan on lf_list (actual time=1035.666..1543.120 rows=11.00 loops=1)
               Recheck Cond: ((customer_id = 4) AND (product_id = 120))
               Filter: (deleted_at IS NULL)
               Rows Removed by Filter: 20001
               Heap Blocks: exact=19891
               Buffers: shared hit=570 read=30828
               ->  BitmapAnd (actual time=991.926..991.927 rows=0.00 loops=1)
                     Buffers: shared hit=3 read=11504
                     ->  Bitmap Index Scan on lf_list_customer_id_id_idx (actual time=306.524..306.525 rows=999058.00 loops=1)
                           Index Cond: (customer_id = 4)
                           Index Searches: 1
                           Buffers: shared hit=3 read=3831
                     ->  Bitmap Index Scan on lf_list_product_id_id_idx (actual time=630.194..630.194 rows=2001436.00 loops=1)
                           Index Cond: (product_id = 120)
                           Index Searches: 1
                           Buffers: shared read=7673
 Planning:
   Buffers: shared hit=101 read=26
 Planning Time: 3.560 ms
 Execution Time: 1549.398 ms
```

Extended statistics do not change the picture here. An MCV list on
`(customer_id, deleted_at)` tells the planner how rare a customer's live rows are
only where the customer's pairs are frequent enough to be listed. With one
deletion date for the whole table, as in this data set, and a statistics target
of 1,000 or more, stock PostgreSQL leaves the Index Scan of cases 1 and 2 for
`BitmapAnd`: 1.7–2.0 s and 1.0–1.1 s from disk, 3× and 8× the node instead of
hundreds. With the deletion dates spread over two years, as in a real table, the
customer's rows split over 730 pairs, none frequent enough, and every plan above
stays as it is at every target (BENCHMARKS.md, "The index pairs of the third
query, and extended statistics").

## Why index composition matters

Measured with [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh):
20M rows, 12 filter columns of 100 values each, soft deletes, then writes of
100,000 rows; PostgreSQL 18.6 in Docker on a laptop, one load, `shared_buffers`
512MB, `max_wal_size` 2GB, `checkpoint_timeout` 5 min, `full_page_writes` on, the
writes start right after a `CHECKPOINT`.

- **M, specialised**: composite indexes for the 9 frequent filter combinations
  (6 pairs, 2 triples, 1 quadruple, all `WHERE deleted_at IS NULL`) plus
  `(fK, id)` for the 6 columns no composite starts with — **15 indexes**.
- **G, general**: `(fK, id)` per filter column, plus `(id) WHERE deleted_at IS
  NULL` and `(id) WHERE deleted_at IS NOT NULL` — **14 indexes**; read with
  stock PostgreSQL or with leapfrog (**G+L**), which combines 2–4 of them per
  query.

Storage and writes. The extension plays no part in these numbers: they compare
the two index sets, and stock PostgreSQL with G writes the same. Rows per
second are one run.

| | M (15 indexes) | G (14 indexes) | G vs M |
|---|---:|---:|---:|
| Index size, excluding PK | 11.2 GB | **8.0 GB** | −28 % |
| `INSERT` 100,000 rows: WAL | 3,600 MB | **166 MB** | −95 % |
| `INSERT`: rows per second | 935 | **11,526** | 12× faster |
| `UPDATE` of a filter column, 25,000 rows: WAL | 1,004 MB | **70 MB** | −93 % |
| `UPDATE` of `deleted_at` (soft delete), 25,000 rows: WAL | **46 MB** | 77 MB | +68 % |
| `DELETE`, 25,000 rows: WAL | 18 MB | 18 MB | same |

One index more, 22× the WAL: nearly all of it is the 9 composite indexes.
Adding the index groups one at a time, M's 6 single-column indexes write
89 MB, the 6 pairs add 461 MB, the 2 triples 2.2 GB and the quadruple 0.9 GB.
In an index with many distinct prefixes every new row lands on a page of its
own, and the first write to a page after a checkpoint logs it in full; a
single-column `(fK, id)` index appends at the end of 100 runs and keeps
hitting the same pages (BENCHMARKS.md, "Where the INSERT WAL comes from").

M is also the cheapest form a specialised set can take: its composites serve
live rows only (`WHERE deleted_at IS NULL`). A real schema needs two more
variants of each, for the trash view (`WHERE deleted_at IS NOT NULL`) and for
lists without a condition on `deleted_at`: 27 composite indexes instead of 9.
Writes then get worse both ways. An `INSERT` lands in the 9 `IS NULL`
composites and the 9 without a predicate, about twice the WAL above; a soft
delete writes the new row version into the 9 `IS NOT NULL` composites and the
9 without a predicate, where the M above touches only its 6 single-column
indexes, so M's edge on soft deletes (46 MB against G's 77 MB) holds only
while it covers live rows alone. G stays at 14 indexes: the node merges
`(fK, id)` with either partial `(id)` index, or does without, and nothing
changes for it. This is a count of indexes, not a measurement.

What this shows, plainly: the write side is the reason to drop the composite
indexes, with 95 % less WAL on inserts and 12× the insert rate, from the index
set alone. M grows with every combination of filters it serves, G does not. A
dedicated index stays the fastest read for the exact query it was built for;
what the node does for the rest is in the table above.

## How Index Merge Intersect works

For every base relation of the query the planner looks for a set of two or
more indexes to intersect, called streams:

- two or more B-trees `(k1, …, kN, sortcol, …)` that read in the same order
  once their leading columns are fixed. Every `kI` is compared for equality
  with a value known when the scan starts, as for an `Index Cond`: a constant,
  a parameter, a column of an outer relation, or a non-volatile expression of
  those (`$1 || $2`, `lower(o.email)`). `sortcol` is the first sort key of the
  query. With `N = 0` the index must be partial with a predicate implied by the
  query (`(id) WHERE deleted_at IS NULL`). This is the rule of a MySQL index
  merge, where a secondary index with its columns fixed reads in primary key
  order. Indexes without `sortcol`, like `(q_id)` and `(w_id)`, are left to
  `BitmapAnd`.

Every stream of a set, the outer one included, must add a restriction the
others do not enforce: an equality column no other stream has
(`(product_id, id)` next to `(customer_id, id)`), or a predicate that the other
streams' equalities and predicates together do not imply. So
`(membership_id, id)` and `(membership_id, id) WHERE deleted_at IS NULL` never
form a set — the partial index alone is the plan — and neither do `(kind, id)`
with `kind = 2` and `(id) WHERE kind = 2`. A plain `(id)` never joins a set.

The planner works as `get_best_ror_intersect` does in MySQL: one pass over the
candidates, fewest entries first. A stream joins the set when it adds a
restriction, up to `leapfrog.max_indexes` (default 4). With an MCV list or
dependencies that cover two columns of the conditions, the first stream is also
priced in a pair with each other index. The cheapest set seen becomes the path, along with the set quickest to its first row when
that is another one; PostgreSQL picks between them and the stock plans as usual. A condition left out of the set becomes a `Filter`. The outer stream,
whose entries are fetched from the heap, is the densest one without a
predicate: the others are held in memory value by value.

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
 Limit (actual time=0.101..2.506 rows=100.00 loops=1)
   Buffers: shared hit=166
   ->  Custom Scan (Index Merge Intersect) on orders (actual time=0.100..2.485 rows=100.00 loops=1)
         Matched TIDs: 100
         Heap Fetches: 100
         Peak Group Memory: 96 B
         Skips: 4
         Short Skips: 3
         ->  Outer Stream on idx_orders_customer_id (actual time=0.021..0.060 rows=585.00 loops=1)
               Index Cond: (customer_id = 100)
               Skips: 1
               Short Skips: 0
               Buffers: shared hit=8
         ->  Inner Stream on idx_orders_deleted_id (actual time=0.018..1.166 rows=20131.00 loops=1)
               Index Pred: (deleted_at IS NOT NULL)
               Skips: 3
               Short Skips: 3
               Buffers: shared hit=62
         Buffers: shared hit=166
 Planning Time: 0.297 ms
 Execution Time: 2.540 ms
```

The customer's ~1,500 recent orders are live; the outer side skips past them
straight to the deleted range. There about 40 deleted orders of other
customers lie between two of this customer's, too few to skip: the short
skips raised the inner side's threshold and it reads them through. Exactly
the 100 returned rows are fetched from the heap.

The planner picks the node at the default `random_page_cost = 4` as well.
Without the extension it runs an `Index Scan` on the partial index that filters
the customer on every deleted row. `BitmapAnd` cannot stop at 100 rows: it reads
all 80,120 entries of the partial index, fetches all 393 matching rows and sorts
them.

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

Measurements: [What it looks like at 100M rows](#what-it-looks-like-at-100m-rows); every other run is in [BENCHMARKS.md](BENCHMARKS.md).

### Compared with a self join

The node gives the same result as a self join written by hand, without changing
the query:

```sql
-- with the extension, the query as it is
SELECT * FROM orders
WHERE customer_id = 5 AND product_id = 7
ORDER BY id LIMIT 100;

-- by hand
SELECT t1.* FROM orders t1 JOIN orders t2 ON t1.id = t2.id
WHERE t1.customer_id = 5 AND t2.product_id = 7
ORDER BY t1.id LIMIT 100;
```

## Requirements

- PostgreSQL **18** or **19** (the planner and executor APIs change between
  major versions; other versions are not supported). PostgreSQL 19 is built
  and tested only against `REL_19_STABLE` with assertions, in CI; the Docker
  images and the benchmarks use 18.
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
project that already has containers or volumes is refused. The test container
mounts the repository, builds the extension from it and runs as a user with
your UID and GID, so its output (`tests/regress/results`, the objects) is
yours.

Benchmarks (`bench` profile: `list_bench.sh`, 20M rows by default; below that the customers have too few live rows for `LIMIT 100` to stop early):

```bash
docker compose up -d --build --wait
docker compose --profile bench run --rm bench
# results: tests/performance/results/list-<timestamp>/<scenario>/
```

Every benchmark script writes into a new directory,
`results/<kind>-<timestamp>/`, or into `BENCH_OUT`, and refuses to run
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
password is well known; `0.0.0.0` publishes it on every interface, for a
client on another machine or a remote `DOCKER_HOST`; connect to `127.0.0.1`
rather than `localhost`, which may resolve to `::1` first),
`POSTGRES_PASSWORD` (`leapfrog`), `LEAPFROG_SHARED_BUFFERS` (512MB),
`SIZE`, `REPEATS`, `PG_MAJOR` (18), `LEAPFROG_TAG` (the image tag, `PG_MAJOR`),
`LEAPFROG_UID`/`LEAPFROG_GID` (the ids of the test and bench containers' user,
1000; `run-in-docker.sh` and `make docker-build` set yours).

The image's `initdb` writes the settings of the test servers,
`tests/scripts/temp.conf` (no parallel gather, `jit = off`, `timezone = 'UTC'`,
…), into a new data directory; a `pgdata` volume created by an earlier image
lacks them until it is recreated (`docker compose down -v`).

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
`ALTER DATABASE … SET`), which applies to new plans; see
[Operational safety](#operational-safety) for cached ones.

Upgrade the library with `make install` (or a package manager), never by
copying over the installed `leapfrog.so`: overwriting a shared library in place
crashes every backend that has it loaded, as for any C extension. `install`
replaces the file instead of rewriting it.

## Settings

| Setting | Default | Context | Meaning |
|---|---|---|---|
| `leapfrog.enabled` | `on` | `USERSET` | The planner offers the Index Merge Intersect node and picks it by cost. `off` disables the hook completely. |
| `leapfrog.force` | `off` | `USERSET` | The node is preferred over every other plan whenever a suitable set of indexes exists (the counterpart of MySQL's `INDEX_MERGE` hint); among several sets the cheapest still wins. The plan-time check of the group estimate against `work_mem` is skipped as well. **Diagnostic setting**: it can make a query many times slower. |
| `leapfrog.max_indexes` | `4` | `USERSET` | The most indexes one node combines (2–16). Streams are added one at a time while each lowers the estimated cost, so the limit only caps the search; with extended statistics on the conditions, the first stream is also priced in a pair with each other index. |
| `leapfrog.min_indexes` | `2` | `USERSET` | Developer setting: smaller sets are not offered and the set that reaches the size is offered whatever its cost, so that a larger set can be run against the stock plans (the tests use it). Not in `postgresql.conf.sample`. |
| `leapfrog.prefetch` | `on` | `USERSET` | Every stream asks for its next leaf page as soon as it reaches one, so that the read overlaps the entries of the current page; where the node's `Filter` drops more rows than it passes, matches are gathered ahead and their heap pages asked for, up to the table's tablespace `effective_io_concurrency` and at most 32; not on a table access method other than the heap. On a cold cache it halved the node's time in BENCHMARKS.md, "Leaf page prefetch"; with the pages cached it changes nothing. |
| `leapfrog.require_node` | `allow` | `USERSET` | Developer setting for the tests, after TimescaleDB's `timescaledb.debug_require_vector_agg`: under `require` a query whose final plan (including subplans) has no Index Merge Intersect node fails at plan time, under `forbid` one whose plan has it; `allow` checks nothing. `EXPLAIN` fails the same way. A plan is checked when it is made, so a cached generic plan of a prepared statement is not checked again. Not in `postgresql.conf.sample`. |
| `leapfrog.skip_after` | `64` | `USERSET` | Developer setting: the starting skip-ahead threshold, in entries; `0` turns skipping off. Used by the tests; not in `postgresql.conf.sample`. |
| `leapfrog.trace_planner` | `off` | `USERSET` | Developer setting: a `NOTICE` with what planning did (candidates, sets costed, range scans, statistics reads, fallbacks, correlations, candidates pruned); the tests check the planner by these counts. |

The node is costed with PostgreSQL's own page and CPU costs, so the usual
tuning applies. In particular, with the default `random_page_cost = 4` (spinning
disks) the planner prefers reading many heap rows sequentially to reading a few
at random, and rarely picks the node; with `random_page_cost = 1.1`, the usual
value for SSDs and data in memory, it picks the node where it reads far fewer
rows. Also relevant: `work_mem` (TID group limit), `seq_page_cost`,
`cpu_*_cost`, `effective_cache_size` and the `enable_*` settings of other
nodes.

## Reading EXPLAIN

Every index of the node is a block of its own, in the manner of a child
node: its role, index, conditions, and under `ANALYZE` its time, entries and
buffers.

```text
Custom Scan (Index Merge Intersect) on orders (actual time=0.100..2.485 rows=100.00 loops=1)
  Filter: (payload <> 'x'::text)
  Matched TIDs: 100
  Heap Fetches: 100
  Peak Group Memory: 96 B
  Skips: 4                  -- shown only when non-zero
  Short Skips: 3
  Group Overflows: 0        -- shown only when non-zero
  Rows Checked by Predicate: 0
  ->  Outer Stream on idx_orders_customer_id (actual time=0.021..0.060 rows=585.00 loops=1)
        Index Cond: (customer_id = 100)
        Skips: 1
        Short Skips: 0
        Buffers: shared hit=8
  ->  Inner Stream on idx_orders_deleted_id (actual time=0.018..1.166 rows=20131.00 loops=1)
        Index Pred: (deleted_at IS NOT NULL)
        Skips: 3
        Short Skips: 3
        Buffers: shared hit=62
  Buffers: shared hit=166
```

| Field | Meaning |
|---|---|
| `Outer Stream` / `Inner Stream` | one block per index. The outer stream's matched entries are fetched from the heap; the inner ones are looked up. In `FORMAT JSON/YAML/XML` the blocks are the array `Index Streams`, each with `Role` and `Index Name`. |
| `Index Cond` | the equalities the stream scans with, as an Index Scan shows them. |
| `Index Pred` | the predicate of a partial index. |
| `Filter` | conditions the node checks on the row. The equalities of every stream and conditions implied by an inner predicate are not in `Filter` (like `Index Cond` of an Index Scan); the exception is the target relation of `UPDATE/DELETE/SELECT FOR UPDATE`, where predicate-implied conditions are kept for EvalPlanQual. |
| `actual time`, `rows` of a stream | time of the stream's descents and of the reads that step to another leaf page, where the page reads happen (the entries within a page are not clocked, which keeps `TIMING` cheap), until the first entry and in total; and the entries read, per loop as a node's rows; `Entries Read` in the structured formats, total over all loops. Dead entries with a NULL sort value that are skipped count. The heap fetches are in the node's time, not in a stream's. |
| `Buffers` of a stream | pages touched by the stream's index calls, shared and local; the node's own `Buffers` line, printed after the blocks, has everything including the heap. |
| `Prefetches` of a stream | leaf pages asked for ahead of time (`leapfrog.prefetch`), when any. |
| `Entries Estimated` | with `VERBOSE` (and costs on): the entries the cost model expected the stream to read, to set against its rows. `tests/performance/cost_bench.sh` records both and their ratio per query. |
| `Skips` / `Short Skips` of a stream | re-descents of this scan to the frontmost value, and those that landed on the leaf page they left or the next one, which doubles the stream's threshold (see Skip-ahead). The node's lines are the totals. |
| `Group Overflows` of a stream | how many times a value's group in this inner stream exceeded its share of `work_mem`. |
| `Matched TIDs` | entries found by TID in every stream. |
| `Heap Fetches` | `index_fetch_heap` calls (including HOT chain continuations). |
| `Heap Prefetches` | heap pages asked for ahead of time (`leapfrog.prefetch`), when any: only where the `Filter` drops more rows than it passes. |
| `Rows Removed by Filter` | the standard counter of rows dropped by `Filter`. |
| `Peak Group Memory` | largest total capacity of the TID group arrays, bytes. |
| `Rows Checked by Predicate` | outer rows of overflowed groups fetched and checked that way, when a group overflowed. |

Counters are summed over all rescans of the node (inside a Nested Loop they
are the total over iterations; `loops` shows their number). Without
`ANALYZE` the node does not open its scans and prints no counters.

## Tests

Standard PostgreSQL infrastructure: `pg_regress` for SQL tests and
`pg_isolation_regress` for concurrent scenarios.

```bash
make installcheck          # everything
make test-regress          # tests/regress/sql/*.sql against tests/regress/expected/*.out only
make test-isolation        # tests/isolation/specs/*.spec only
make pgindent              # core code style
make check-tests           # test lists, expected files, alternative outputs (no server)
make check-version         # EXTVERSION, control file, scripts, CHANGELOG.md agree
make lint                  # static checks of the tree (CONTRIBUTING.md, "Lint")
make bench-smoke           # tiny run of the benchmark harness
```

Against an assert-enabled server (PostgreSQL 18 built from source with
`--enable-cassert`; also a CI job), failing on any `TRAP:` or crashed backend
in the server log:

```bash
docker build -f docker/cassert.Dockerfile -t leapfrog-cassert .
docker run --rm leapfrog-cassert
```

`--build-arg SANITIZE=address,undefined` builds the server and the extension
with clang and AddressSanitizer and UndefinedBehaviorSanitizer; any report
fails the run (see CONTRIBUTING.md).

The regression tests need a superuser (as `pg_regress` normally runs):
`leapfrog_memory` reads `/proc/self/status` and `leapfrog_explain` creates an
in-place tablespace (`allow_in_place_tablespaces`) named after the database,
`lf_space_<database>`, sets a page cost on it for one check and drops it. It
never changes `pg_default`; an existing tablespace of that name that is not
the test's own (owner and comment) stops the test before anything is changed.

Regression tests (`tests/regress/sql/`):

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
| `leapfrog_security` | row-level security: leakproof equalities become streams, others stay in `Filter`; the same query without the policy uses them |
| `leapfrog_cost` | the node is charged for the clauses in its `Filter` and only those; a predicate implied by an equality does not lower the row estimate |
| `leapfrog_partition` | hash and range partitions, a partition with other attribute numbers, `Merge Append` and ordered `Append`, run-time pruning, `LATERAL`, a partitionwise join with the node inside its nested loops, `FOR UPDATE`, row-level security, `TABLESAMPLE`, a partition without the indexes, inheritance |
| `leapfrog_sort_types` | `timestamptz`, `date`, `numeric`, `text` in two collations, `varchar`, `char`, `uuid`, arrays, enums, domains and `real` as sort columns, in both directions; skip-ahead with long text, overflow, generic plans, `LATERAL`; other collations, operator families and input types are no streams |
| `leapfrog_sort_icu` | a sort column in an ICU collation, deterministic or not; skipped where the database's encoding has none |
| `leapfrog_nulls` | a nullable sort column in all four orders, by value and by reference; skip-ahead across the NULL boundary and to the NULL group, NULLs in one stream only, the estimate of the NULL group, row versions; a strict condition on the column leaving the NULLs out (indexes with NULLs at either end, a `LATERAL` parameter, the NULLs not read), non-strict ones falling back |
| `leapfrog_index_order` | `ASC`, `DESC` and `NULLS FIRST` index columns mixed in one node, skip-ahead in opposite directions, partial indexes, nullable columns: which index pairs serve which order |
| `leapfrog_merge_order` | a dense stream reads around what the sparser ones agree on; columns after the sort column, two partial indexes; indexes without the sort column stay with `BitmapAnd` |
| `leapfrog_planner` | by the counts of `leapfrog.trace_planner`: statistics, ranges and correlations read once, a stream that cannot pay for itself pruned; the estimate from the statistics read once, also inside one histogram bin |
| `leapfrog_heap_prefetch` | matches gathered ahead where the `Filter` drops most rows: results and order against the stock plans, `LIMIT`, non-unique sort column, rescans, a cursor, `FOR UPDATE`, dead rows and HOT chains; none without a `Filter` or where it passes most rows, or with the setting off; a group overflowing `work_mem` after a queue, with two and three streams |
| `leapfrog_require` | `leapfrog.require_node`: `require` and `forbid` with and without `leapfrog.force`, under `EXPLAIN`, the node in a subquery and an InitPlan, a prepared statement, a plpgsql function and a `DO` block; `allow` changes nothing |
| `leapfrog_first_group` | startup cost against the group read first: a common value at the end of the range, behind a row or a dead entry (the Index Scan then chosen), in a generic plan, without a histogram, within reach of a `LIMIT`; a value or NULLs one stream does not hold; a group overflowing `work_mem`, first or further on; sorting a later group; a stream with a narrow range; the group of the NULLs, also with ranges that do not meet, and partial indexes without NULLs; a value out of the most common ones; a unique sort column; a set quicker to start offered next to the cheapest |

Every `lf_check(query)` runs the query with the stock plan and with
`leapfrog.force`, compares the multisets with `EXCEPT ALL` in both directions
(and row positions when the sort key is unique) and reports whether the plan
contained the `Custom Scan`, so a test cannot pass by accident through a plain
Index Scan. A canary in it, after TimescaleDB's `skip_scan` tests, captures the
settings each of the two runs saw and fails when they are the same. Every fix
and feature has a test that fails without it; the reverted variants were
built and run.

Where an isolation session is meant to run the node, it sets
`leapfrog.require_node = require`, and its steps with the stock plan switch to
`forbid`, so a silent fallback to either side fails the spec instead of
comparing a plan with itself.

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
| `leapfrog_partition` | EvalPlanQual under a `Merge Append`: inner and outer equalities failing on the new version, an unrelated column, a row moved to another partition |
| `leapfrog_sort_types` | EvalPlanQual with a `text` sort column |
| `leapfrog_nulls` | EvalPlanQual with a sort value becoming NULL and a row of the NULL group no longer matching |

## Benchmarks

Run the benchmarks on a PostgreSQL instance of their own, never on a server
with real work on it: a database of their own isolates the data, not the
load. They write gigabytes of WAL at the default sizes, and `write_bench.sh`
runs `CHECKPOINT` on the whole cluster. The Docker server above,
or one started for the purpose, is the intended target.

```bash
SIZE=100000000 WORK_MEM=512MB bash tests/performance/list_bench.sh   # the list query with rare, scattered matches, each scenario separately; SCENARIOS=two_filters for one; ORDER=id for id order
BASE_ROWS=20000000 STRATEGIES="M G" bash tests/performance/write_bench.sh   # the M and G table: storage, writes and reads for 12 filter columns

# uniform data, filter values spread evenly over the table
SIZES="20000000" WORK_MEM=256MB WARMUP=5 bash tests/performance/uniform_bench.sh   # against BitmapAnd and an exact index, exact bitmaps; DELETED=hashed or batches for one data set
SIZES="100000000" WORK_MEM=512MB WARMUP=5 bash tests/performance/uniform_bench.sh

# for work on the planner
bash tests/performance/cost_bench.sh             # cost model: estimate against time, skewed and correlated data
bash tests/performance/planning_bench.sh         # planning time: 10/20/50 indexes on the table, 1/2/6 used by the query
```

The read benchmarks record `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` after a
warm-up, with a fixed seed, into CSV files. Results:
[BENCHMARKS.md](BENCHMARKS.md).

## Cost model

The structure follows MySQL's `ROR_intersect_plan::add`; the components are
PostgreSQL cost functions:

```text
read    = entries of each stream inside the overlap of their sortcol ranges
matches = rows × outer share × inner share / table share of the overlap
run     = merge_read_cost(outer read, inner read)
        + group_cost(outer + inner read, log2(group size)), group by group
        + heap_fetch_cost(matches)
        + matches × (cpu_tuple_cost + cost of the Filter + tlist cost)
        + one descent per stream that skips into the overlap
startup = descent into both B-trees (as in btcostestimate)
        + startup cost of Filter and tlist
        + max(run / (matches + 1),  -- both streams advance to the first match
              first group of the inner stream, read and sorted)  -- at most run
total   = descents + startup cost of Filter and tlist + run
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
  overlap. Disjoint ranges cost next to nothing, unless the column has NULLs:
  they form one more group, whose share from the statistics counts in every
  stream and in the table. A parameterized path or a
  generic plan is costed without the probe. Like any plan built on actual
  values, a cached plan with constants keeps this estimate until it is
  replanned.
- **Group size**: the NULLs and the most common values inside the overlap by
  their own share; the others share what those leave, among the remaining
  distinct values of the table (`get_variable_numdistinct`). Each entry pays log2(group size)
  TID comparisons at 0.1 × `cpu_operator_cost`, the rate
  `cost_bitmap_tree_node` charges per TID of a bitmap: the comparisons are
  inline, not operator calls.
- **Heap pages**: as `cost_index` charges them, interpolated by the squared
  correlation that `btcostestimate` uses for an Index Scan on the outer index
  (its leading column, ×0.75 for a multicolumn index). The node visits the
  same heap rows in the same order as that Index Scan, so both are charged
  alike; the node wins only by fetching fewer rows.
- **First group**: no row comes before the inner streams have read the group of
  the value the merge stands on. It is the largest group within the share
  wanted / (matches + 1) of the overlap, from the end the merge starts at, where
  wanted is the `LIMIT` of a query on this relation alone and 1 otherwise: the NULLs
  when they come first and every stream holds them, the most common values there,
  or an average one of the others. A group a stream does not hold is passed,
  as the merge passes it: such a value is looked up in the streams (one descent,
  cached per index and value) when it would raise the charge. The other values
  share what the common values and the NULLs leave. A stream with a narrow range holds more of a value than the table
  does: the share is taken of its own range. Without a probe (a parameterized path,
  a generic plan) the overlap is taken for the whole column, as above. The charge
  raises startup, not the total.
- **Overflow**: a NULL or common value group over its share of `work_mem` is not
  sorted, and every outer entry of the value is fetched and checked on the row. It
  is looked up in the streams first. Only a group of a value out of the most common
  ones can overflow unnoticed.
- `LIMIT` is applied by the planner: `startup + (total − startup) × fraction`,
  where fraction is `LIMIT` over the planner's row estimate of the relation,
  not over `matches`.

**Documented assumptions**: inside the overlap, matches are spread evenly
along both indexes, and a TID group out of the most common values has the
average size. Skew among those values, and the correlation of a filter with the sort column, are not seen —
by the node or by PostgreSQL's own estimate of the stock plans; see Known
limitations.

## Known limitations and planned improvements

### Current limitations

Verified against `src/` and the tests.

**Index sets**

- Up to `leapfrog.max_indexes` streams (default 4, at most 16), added
  in one pass, fewest entries first; a set that pass never reaches is not
  considered, except the pairs of the first stream where extended statistics
  cover two columns of the conditions.
- Every index has equality columns or a predicate, then `sortcol`. Every stream
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
- Sort column: any type with a B-tree operator family (`timestamptz`, `date`,
  `numeric`, `text`, `varchar`, `uuid`, arrays, enums, domains …), compared
  with the comparator of the query's sort key. Every stream's index column
  must be in the family, input type and collation of that key: an index
  in another collation or in `text_pattern_ops` serves another order, and is
  no stream of this one.
- Equality (`=`) only on the equality columns; `IN (…)`, ranges and `IS NULL`
  are not supported.
- A nullable sort column: NULL is a value of the merge, in the query's
  `NULLS FIRST`/`LAST` order, and every stream must have its NULLs at that end
  in its scan direction. The node leaves the NULLs out, and their position does
  not matter, for a column `NOT NULL` according to the planner
  (`RelOptInfo.notnullattnums`; dead index entries with NULL are skipped) and
  for a column that a strict condition of the query rejects NULL in
  (`val > 0`, `val > $1`, `val IS NOT NULL`, `val = ANY (…)`, as
  `find_nonnullable_vars` proves it; not `COALESCE(val, 0) > 0` or
  `val > 0 OR val IS NULL`): the streams start past their NULLs and stop at
  them. Only a condition on the relation itself counts, not a join clause.
- Index columns: nbtree v4, `ASC` or `DESC`, `NULLS FIRST` or `LAST`. Every
  stream scans in the direction that gives the query's order in its own
  index, so one node may run them in opposite directions.

**Planner and cost model**

- **Planning time depends on the candidates, not on how many indexes the
  table has.** The planner looks at every index of the table once, but only
  at its metadata (access method, key columns, operator family, predicate
  proven by the planner already): an index whose columns before the sort
  column are not all fixed by the query's equalities is dropped there, at
  the cost of a loop over a few arrays. On a table with 50 indexes and a
  query that uses 2 of them, 48 are dropped this way and never costed,
  probed or combined.

  The expensive work — reading each candidate's sort range from its B-tree and
  costing the sets — is done only for the streams of the one pass over the
  candidates, at most `leapfrog.max_indexes` of them, and not for a stream that
  cannot pay for itself: when the current set, less all it spends on the heap,
  plus the stream's descent and one leaf page is no cheaper than the cheapest
  set so far. That leaves out what a narrower overlap of the ranges could save,
  which only the probe would tell.

  Most of what remains is reading the sort ranges from the B-trees. The share of
  a range comes from the column's histogram and most common values, read once per
  relation, not from a selectivity call each time; the selectivity functions
  answer when the statistics are not in the query's order or the range lies
  inside one bin of a type that cannot interpolate. BENCHMARKS.md, "Planning".
- Only the first key of the query's `ORDER BY` is considered.
- The cost model is conservative: it misses a part of the cases where the node
  is faster, and with dense conditions and the data in memory it can pick the
  node where it is slower (see the top of this file). `EXPLAIN (VERBOSE)` shows
  the entries the model expected against the entries read; in these misses they
  agree within a few percent, so the cause is in how PostgreSQL costs the
  competing plans: their estimates assume the filter is spread evenly along
  `id`, and the heap correlation of a multicolumn index is taken as its leading
  column's × 0.75, as `btcostestimate` does.
- One relation per node, no parallel execution. A partitioned table or an
  inheritance tree gets one node per child, on the child's own indexes, under
  a `Merge Append` or ordered `Append`; a child without suitable indexes gets a
  stock plan there.
- `TABLESAMPLE` relations are not supported: they keep their Sample Scan.
- Under row-level security an equality whose operator is not leakproof
  (`numeric =`) and that does not come from the policy cannot be a stream's
  condition, as it cannot be an `Index Cond`: it stays in `Filter`.

**Executor and memory**

- The inner entries of a value are materialised (`collect_group`): 6-byte TIDs,
  doubling up to `work_mem`, `qsort` and `bsearch`. A group larger than
  `work_mem` falls back to fetching every outer row of the value.
- Skip-ahead thresholds were measured warm and with shared buffers emptied
  before every run; a run with the OS page cache dropped as well needs root on
  the database host and has not been made. The landing check reads nbtree's scan position
  (`BTScanOpaque`, in `lf_scan_leaf_position` only) and the planner calls
  `_bt_metaversion`, so both depend on nbtree internals, not on the index
  AM API. There is no public way to get either; both are unchanged in
  PostgreSQL 19.

**Tests and benchmarks**

- `VACUUM` while the node's scan is positioned on a leaf page is not in the
  isolation tests: `isolationtester` does not see buffer pin waits. It was
  checked by hand (see Known issues).
- Benchmarks ran on one laptop; timings vary up to 2× between runs, and one
  load per size at 10M to 100M rows. The OS page cache was never dropped on
  purpose: up to 20M rows everything is read from it, at 50M and 100M a part
  comes from disk, which the scripts do not tell apart.

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
| P3 | More types and conditions | **partly**: equality and sort columns of any B-tree type, nullable sort columns, `DESC` and `NULLS FIRST` indexes; `IN (…)` open |

#### Cost model: distribution of matches along the sort column

Done: the planner probes the actual smallest and largest sort value of each
stream and costs only the overlap, with the matches estimated there and used
as the path's row estimate.
Then, with the estimated entries shown next to the entries read, the one
component of the node's own cost that disagreed with the measurement was
found and fixed: TID comparisons in a group were charged as operator calls,
ten times the rate PostgreSQL charges the same work in a bitmap, which made
the node dearer than `BitmapAnd` on identical page reads.

Not done, on purpose: estimating the density of the streams inside the
overlap by more probes. In the remaining misses the entries estimate is within
a few percent of the entries read; the competing stock plans are estimated
too cheaply (see Current limitations), and lowering the node's cost further
would be fitting the benchmark.

#### Adaptive skip-ahead

Done: each side starts at 64 entries; a skip that lands on the leaf page it
left or the next one doubles the side's threshold, a longer one halves it.

Open: a run with the OS page cache dropped too (needs root on the database
host), where every block read is a device read.

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
their shares are cached per index, the statistics per relation. Planning time
is measured on tables with 10, 20 and 50 indexes and follows the number the query
can use, not the table's total. Open: the range probes (most of what remains),
and useful pathkeys beyond the query's `ORDER BY`.

#### Memory of non-unique keys

A streaming match without materialising the group when both streams return the
TIDs of a value in TID order (a forward scan with all other key columns fixed;
backward scans and posting lists to be verified against nbtree first).

#### More types and conditions

Done: equality columns of any type with a B-tree operator family, with the
operator looked up in the index column's family and the row rechecks
(EvalPlanQual, overflow fallback) done with that operator and collation;
sort columns of any such type, nullable or not, in indexes of any order. Tested
in `leapfrog_types`, `leapfrog_sort_types`, `leapfrog_nulls` and
`leapfrog_index_order` (regression and isolation).

Open: `IN (…)` as several outer scans merged in `sortcol` order; composite
sort keys. A range on a leading column breaks the
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
  an Index Only Scan. Every stream holds its own pin, so a node with four
  streams can hold four pages of four indexes. `VACUUM` of such an index waits
  until the scan moves to the next page or ends — for example behind a cursor
  left open in the middle of its result. When the merge ends the scans release
  their pages, so an exhausted cursor does not hold `VACUUM`
  (`leapfrog_insert_vacuum`).
- **Misses of the cost model**, see above. `leapfrog.force` shows what the node
  would do; it does not guarantee the node is chosen (a parameterization the
  join order cannot provide, for example).

## Operational safety

- Planner: the hook only adds paths through `add_path`; stock paths are never
  removed or changed. With `leapfrog.enabled = off` the hook returns
  immediately.
- Switching it off: `leapfrog.enabled = off` applies to new plans only, as any
  planner setting. A plan already cached, such as the generic plan of a prepared
  statement, keeps using the node. To switch it off for certain in a session:

  ```sql
  SET leapfrog.enabled = off;
  DISCARD PLANS;
  ```

  With a connection pool, do this on every connection or open new ones. A query
  already running is not affected.
- Executor: index scans use the standard `index_beginscan` / `index_rescan` /
  `index_getnext_tid` / `index_fetch_heap` with the query's snapshot;
  visibility and HOT chains work as for `Index Scan`, and so does `kill_prior_tuple` unless matches are fetched from the heap prefetch queue, where only the entry the scan stands on can be marked: dead rows there are revisited until `VACUUM`.
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
