# Benchmark results

Three harnesses, all reproducible from the repository:

- [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh) —
  storage, writes and a read mix for a table with 12 filter columns, comparing
  a specialised index set with a general one;
- [`tests/performance/run.sh`](tests/performance/run.sh) — reads only, one
  filter column plus soft deletes, three index strategies over a matrix of
  distributions, deleted shares, customers and limits;
- [`tests/performance/bitmap_bench.sh`](tests/performance/bitmap_bench.sh) —
  the node against `BitmapAnd` at 100k to 50M rows.

Raw data of every run goes to `tests/performance/results/` and is not
committed.

## Setup and caveats

| | |
|---|---|
| Date | 2026-10-24 |
| Server | PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2), `postgres:18` container, leapfrog at commit `6bfbe99` |
| Settings | `shared_buffers=128MB`, `work_mem=4MB`, `effective_cache_size=4GB`, `jit=off`, `max_parallel_workers_per_gather=0`; `random_page_cost` 4 (default) and 1.1 as stated |
| Host | developer laptop, Linux 7.2, NVMe; data in the OS page cache after warm-up |

- **Timings vary up to 2× between runs of the same build on this machine**
  (measured: one query of one build ranged from 2.4 to 4.7 ms across rounds).
  Buffer counts, entries read, heap fetches, index sizes and WAL are
  deterministic; conclusions rest on them where timings are close.
- Writes are single measurements per run; the range over four runs is given.
- The OS page cache was never dropped (needs root on the host;
  `skip_bench.sh` takes a `COLD_CMD` for that). `skip_bench.sh` was also run
  with shared buffers emptied before every query. 10M+ rows were not
  measured.

## Write and storage benchmark

500,000 rows, 12 `bigint` filter columns with 100 values each (deterministic
hash, independent of each other and of `deleted_at`), one in five of the oldest
40 % soft-deleted. Then, each after a `CHECKPOINT`: insert 100,000 rows,
soft-delete 25,000, change one filter column of 25,000, delete 25,000.

- **S, specialised (33 indexes)**: per column `(fK, id) WHERE deleted_at IS
  NULL` and `(fK, id) WHERE deleted_at IS NOT NULL`; composite indexes
  `WHERE deleted_at IS NULL` for 6 pairs, 2 triples and 1 quadruple of
  filter columns: `(f1, f2, id)`, `(f1, f2, f3, id)`, `(f1, f2, f3, f4, id)`
  and so on.
- **G, general (14 indexes)**: per column `(fK, id)`; `(id) WHERE deleted_at
  IS NULL`; `(id) WHERE deleted_at IS NOT NULL`. Read with stock PostgreSQL
  (G) or with leapfrog (G+L), which combines 2–4 of them per query.

Last run: N-way intersection, commit after `4eb4a7b`. The earlier run with
30 indexes in S (pairs only) is in the git history of this file.

### Storage and WAL (deterministic)

| | S | G |
|---|---|---|
| Indexes (excluding PK) | 33 | 14 |
| Index size | 375 MB | 201 MB (−46 %) |
| WAL, insert 100,000 rows | 481 MB | 159 MB (−67 %) |
| WAL, soft-delete 25,000 rows | 82 MB | 91 MB (+11 %) |
| WAL, change a filter column of 25,000 rows | 291 MB | 73 MB (−75 %) |
| WAL, delete 25,000 rows | 18 MB | 18 MB |

Soft delete writes slightly more WAL with G: a non-HOT update inserts into 12
full `(fK, id)` indexes and one partial index, against 12 "deleted" partial
indexes with S. Every composite index S adds for a combination of filters
costs WAL on every insert and on every update of one of its columns; G's
indexes do not grow with the number of combinations.

### Write throughput (rows per second)

| | S | G | G vs S |
|---|---:|---:|---|
| insert | 4,035 | 23,017 | 5.7× |
| soft delete | 11,042 | 14,568 | 1.3× |
| change a filter column | 2,658 | 12,684 | 4.8× |
| delete | 76,390 | 92,670 | 1.2× |

One run; earlier runs varied up to 2× between runs on this laptop, the WAL
numbers above are the reliable part.

### Reads, `LIMIT 100`, median of 5

| Query | S | G stock | G+L planner (indexes) | G+L forced |
|---|---:|---:|---|---:|
| `random_page_cost = 4` | | | | |
| one filter, live | 0.05 | 0.12 | 0.10 (Index Scan) | 0.51 |
| one filter, deleted | 0.06 | 1.77 | 2.50 (Index Scan) | 0.53 |
| 2 filters, composite in S | 0.06 | 1.72 | **0.90 (node, 2)** | 0.56 |
| 2 filters, none in S | 2.97 | 1.73 | **0.93 (node, 2)** | 0.58 |
| 3 filters, composite in S | 0.02 | 2.14 | 2.31 (Bitmap) | 0.58 |
| 3 filters, none in S | 4.07 | 2.11 | **0.96 (node, 3)** | 0.57 |
| 4 filters, composite in S | 0.02 | 2.06 | **0.98 (node, 3)** | 0.59 |
| 4 filters, none in S | 4.78 | 1.98 | **0.96 (node, 3)** | 0.57 |
| `random_page_cost = 1.1` | | | | |
| one filter, live | 0.06 | 0.06 | 0.07 (Index Scan) | 0.51 |
| one filter, deleted | 0.13 | 1.35 | **0.57 (node, 2)** | 0.53 |
| 2 filters, composite in S | 0.07 | 1.48 | **0.68 (node, 2)** | 0.56 |
| 2 filters, none in S | 5.56 | 1.48 | **0.65 (node, 2)** | 0.58 |
| 3 filters, composite in S | 0.02 | 1.49 | **0.62 (node, 2)** | 0.58 |
| 3 filters, none in S | 5.98 | 1.48 | **0.62 (node, 2)** | 0.57 |
| 4 filters, composite in S | 0.04 | 1.43 | **0.80 (node, 3)** | 0.59 |
| 4 filters, none in S | 6.76 | 1.59 | **0.63 (node, 2)** | 0.57 |

Milliseconds. The forced node is the cheapest set by its own estimate
(here always a pair); its work does not depend on the page costs. The 3- and
4-filter queries match no row: the filters have 100 values each, so all
combinations are scanned to the end, the case that costs every plan the most.

- S answers every query it has an exact composite for in under 0.1 ms and
  pays 3–7 ms for every combination it has none for: the composite index
  helps only the query it was built for.
- G+L answers every 2-, 3- and 4-filter query in 0.6–1.0 ms, chosen by the
  planner in 15 of 16 cases, 1.5–3.5× faster than stock PostgreSQL on the
  same indexes and 3–10× faster than S without a matching composite.
- The planner takes a third index where the cost model sees it pay
  (`random_page_cost = 4`: the third stream is read through instead of heap
  fetches) and stays with a pair at 1.1, where heap fetches are cheap; the
  measured times of the two choices differ by under 0.2 ms either way.
- Two cases go to stock plans: "one filter, deleted" at the default page cost
  (2.5 ms against the forced node's 0.53; the stock Index Scan on the
  partial index is estimated too cheaply, see the README's Current
  limitations) and "3 filters, composite in S" at the default page cost
  (`BitmapAnd`, 2.3 ms against 0.58).
- Planning: 0.25–0.57 ms with leapfrog against 0.09–0.12 ms stock. The table
  has 14 indexes; a query with k filters can use k + 1 of them (the filter
  columns and one `deleted_at` index), and only those are costed — the time
  follows k, not 14 (see the README's planning table).

## Read benchmark, 1M rows

`run.sh`: 1,000,000 rows, `setseed(0.42)`; uniform (1,000 customers of equal
size) and skewed (10 customers hold 50 % of the rows; deleted rows only among
the oldest 40 % of ids); 1/10/50/90 % deleted; largest, median and smallest
customer; live and deleted rows; `LIMIT 1/100/1000/none`: 192 queries per
strategy, 5 repetitions after a warm-up.

- **A**: `(customer_id, id)`.
- **B**: A + `(id) WHERE deleted_at IS NULL` + `(id) WHERE deleted_at IS NOT
  NULL`, planner's choice; **B\*** the same with `leapfrog.force`.
- **C**: `(customer_id, id) WHERE deleted_at IS NULL` + `(customer_id, id)
  WHERE deleted_at IS NOT NULL`.

### Planner choices

Counted by `tests/performance/choices.sql` from the `results.csv` of a run
with `BENCH_FORCE=1`. A miss is a query where the node (B\*) is more than 15 %
faster than both B's choice and A: A's index is one of B's, so A's plan is
open to B's planner as well.

| `random_page_cost` | Node chosen (of 192) | Chosen and >15 % slower than the best of A, B\* | Missed |
|---|---|---|---|
| 4 | 2 | 1 | 27 |
| 1.1 | 5 | 4 | 21 |

Final code (commit `ebeb049`, range probe and row estimate). The wrong
choices are all `LIMIT 1` queries, off by 0.02–0.09 ms. Most misses are
deleted rows: 1 % uniform (node 0.5 ms against 0.7–1.7 ms) and skewed with
`LIMIT 1000` (1.1 ms against 2–8 ms). In them the competing stock plans are
estimated too cheaply — PostgreSQL assumes the customer is spread evenly
along `id` and costs `BitmapAnd` below the node on the same index entries —
rather than the node too dearly; see the README's Current limitations.

The earlier count on this matrix (48 and 38 misses, nothing chosen) used B\*
against B only. With that definition the largest "misses" were queries where
the stock planner itself picked a poor `BitmapAnd` with B's indexes (12.3 ms,
while A's plan on the same `(customer_id, id)` index takes 1.6 ms and the
node 3.6 ms) — not cases the node should win.

### Skewed, largest customer (50,172 rows), `random_page_cost = 1.1`

| deleted % | rows | LIMIT | A | B (planner) | B\* (node) | C |
|---|---|---|---|---|---|---|
| 1 | deleted | 100 | 7.88 | 0.36 (partial Index Scan, 866 buf) | 0.37 (125 buf) | 0.04 |
| 1 | deleted | 1000 | 16.56 | 2.26 (partial Index Scan, 4,557 buf) | **1.53** (597 buf) | 0.20 |
| 10 | deleted | 1000 | 7.74 | 2.42 (1,076 buf) | **1.24** (731 buf) | 0.25 |
| 50 | deleted | 1000 | 7.42 | 1.95 (332 buf) | **1.06** (339 buf) | 0.19 |
| 90 | deleted | 1000 | 6.92 | 2.03 (332 buf) | **1.06** (339 buf) | 0.40 |
| any | live | 100 | 0.04 | 0.04 (Index Scan on `(customer_id, id)`) | 0.13–0.14 | 0.04–0.08 |

Milliseconds. With B's indexes the stock planner already finds a good plan for
the deleted rows (a backward scan of the partial index); the node is up to 2×
faster for `LIMIT 1000` and equal for `LIMIT 100`, and is not picked. Against A
— no partial index at all — both are 3–22× faster (30–300× at the default
`random_page_cost`, where A's plan is worse). The dedicated partial indexes of
C remain the fastest read.

### 100k rows

An earlier smoke run at 100,000 rows showed the same picture at a smaller
scale, with every timing below 2 ms.

## Equality types, 1M rows (baseline for `bc83b54`)

`types_bench.sh`: 1,000,000 rows; one key with 200 values stored as
`bigint`, `integer`, `smallint`, `uuid`, `text` and `varchar`, each with an
index `(key, id)`, and a filter `f` with 20 values and `(f, id)`; `WHERE key =
17 AND f = 3 ORDER BY id DESC LIMIT n` matches about 250 rows. The same data
and physical layout for every build; warm cache (`shared_buffers` 128 MB,
the rest in the OS cache); 2 warm-up and 15 measured runs per cell through
`EXPLAIN (ANALYZE, BUFFERS, MEMORY)`; builds run in the order 86d2f42,
bc83b54, bc83b54, 86d2f42 (ABBA) to tell drift from difference; compared with
`types_compare.sh`. Median execution time in milliseconds; both ABBA pairs
agree within the noise below.

| Case | LIMIT | 86d2f42 (node where supported, else stock) | bc83b54 node | Stock plan |
|---|---:|---:|---:|---:|
| `bigint = bigint` | 1 | node 0.021–0.022 | 0.022–0.023 | 0.013 (Index Scan) |
| `bigint = bigint` | 10 | node 0.094–0.101 | 0.094–0.102 | 0.051–0.055 (Index Scan) |
| `bigint = bigint` | 100 | node 0.80–0.89 | 0.75–0.88 | 3.7–4.1 (Bitmap) |
| `bigint = bigint` | 1000 | node 2.08–2.24 | 2.01–2.18 | 3.96–4.01 (Bitmap) |
| `integer = bigint` | 100 | stock 3.68–3.82 | 0.81–0.84 | 3.98–4.07 |
| `smallint = bigint` | 100 | stock 3.76–3.81 | 0.84–0.91 | 3.87–3.91 |
| `uuid = uuid` | 100 | stock 3.76–3.78 | 0.82–0.84 | 3.86–3.92 |
| `text = text` | 100 | stock 3.97–3.98 | 0.90–0.94 | 3.97–4.76 |
| `varchar = text` | 100 | stock 4.00–4.06 | 0.81–0.84 | 3.97–4.12 |
| `uuid = uuid` | 1000 | stock 3.81–3.88 | 2.07–2.19 | 3.85–4.20 |
| `text = text` | 1000 | stock 3.87–3.93 | 2.56–2.62 | 3.97–4.02 |

- **No regression on `bigint = bigint`.** The node reads the same entries
  (185 / 2,280 / 21,866 / 54,656) and buffers in both builds; medians differ
  by −10 % to +8 % in either direction between the pairs, i.e. noise.
- **New types:** where the old build fell back to `Bitmap Heap Scan`, the
  node is 4.2–4.7× faster at `LIMIT 100` and 1.5–1.9× at `LIMIT 1000`, with
  the same work as for `bigint`. `text` costs 0.1–0.5 ms more at `LIMIT 1000`
  than `bigint` (collation-aware comparisons in the B-tree descents).
- **By-reference values** (`uuid`, `text`, `varchar`) add about 0.02 ms per
  execution under `EXPLAIN ANALYZE` at `LIMIT 1`/`10`. End to end with
  `pgbench` (20,000 runs, `leapfrog.force`) `uuid` and `integer` take the same
  0.16 ms, `text` 0.18 ms.
- **Planning:** 0.09–0.13 ms with the node against 0.03–0.06 ms stock, the
  same in both builds; planner memory 36 kB against 34 kB.
- **A wrong choice, in both builds:** at `LIMIT 1` and `10` the planner picks
  the node although the stock `Index Scan` on `(key, id)` is faster (0.022
  against 0.013 ms, 0.10 against 0.05 ms) and planning adds 0.06 ms more.
  Absolute differences are small, but the cost model overrates the node for
  very small limits.

## Against BitmapAnd as the table grows

### Three runs at 1M, 10M and 50M rows, `work_mem` 256MB (the README's table)

`bitmap_bench.sh` on the C code of commit `daf9ece`,
`SIZES="1000000 10000000 50000000" WORK_MEM=256MB WARMUP=5`, run three
times, each on a freshly loaded table, the four plans in ABBA order;
the Compose server (`shared_buffers` 512MB, `random_page_cost` 4), one
laptop. Every bitmap exact (no lossy heap blocks). The 50M-row table,
about 11 GB with its indexes, does not fit in the laptop's memory (14 GB,
about 4 GB free); the warm-up runs bring the pages the queries read into
the caches. Median and 90th percentile of the 33 measured runs, then the
medians of the three runs, in milliseconds.

| Rows | Query | Index Merge Intersect, ms | per run | BitmapAnd, ms | per run | Stock choice, ms | With leapfrog, ms |
|---:|---|---:|---|---:|---|---|---|
| 1M | pair | 1.32 (1.69) | 1.37 1.21 1.47 | 4.19 (5.04) | 4.53 4.13 4.03 | BitmapAnd 4.11 (5.30) | Index Merge Intersect 1.41 (1.72) |
| 10M | pair | 1.27 (1.53) | 0.84 1.29 1.29 | 53.0 (60.4) | 48.0 52.4 58.6 | BitmapAnd 53.3 (61.6) in runs 1 and 3, Index Scan 2.85 (3.13) in run 2 | Index Merge Intersect 1.22 (1.48) |
| 50M | pair | 1.27 (1.72) | 1.03 1.35 1.15 | 231 (236) | 180 233 235 | Index Scan 3.13 (3.70) | Index Merge Intersect 1.57 (1.74) |
| 1M | deleted | 0.95 (1.20) | 1.05 0.93 0.60 | 9.02 (13.2) | 12.9 8.87 8.38 | Index Scan 2.88 (3.54) | Index Scan 2.49 (3.32) |
| 10M | deleted | 0.85 (1.27) | 0.63 0.96 0.88 | 80.9 (84.0) | 83.4 80.5 75.3 | Index Scan 2.37 (2.59) | Index Scan 1.78 (2.28) |
| 50M | deleted | 0.87 (1.22) | 0.87 1.02 0.74 | 409 (415) | 362 413 411 | Index Scan 2.18 (3.02) | Index Scan 1.71 (2.26) |
| 1M | pair, all rows | 2.08 (2.85) | 1.76 2.71 1.69 | 4.30 (5.99) | 3.84 5.63 4.20 | BitmapAnd 4.22 (6.07) | Index Merge Intersect 2.07 (2.86) |
| 10M | pair, all rows | 17.1 (19.1) | 17.3 16.9 17.1 | 45.2 (50.3) | 50.2 39.4 43.1 | BitmapAnd 44.4 (51.8) | Index Merge Intersect 17.2 (18.0) |
| 50M | pair, all rows | 84.3 (85.0) | 84.5 84.2 84.3 | 223 (228) | 181 226 224 | BitmapAnd 222 (229) | Index Merge Intersect 84.4 (85.4) |

Index entries and buffers are the same in every run and as in the earlier
runs below: node / `BitmapAnd` 17,587 / 30,236, 13,682 / 299,961 and
18,621 / 1,500,743 for the pair, 10,752 / 110,458, 10,891 / 1,100,609 and
10,980 / 5,501,611 for the deleted rows; the node reads 133–179 buffers
with a `LIMIT` at every size.

- With a `LIMIT` the node's median is 0.85–1.32 ms and its 90th percentile
  at most 1.72 ms at every size; `BitmapAnd` is 3.2–9.5× slower at 1M
  rows, 42–95× at 10M and 180–470× at 50M.
- Without a `LIMIT` the node is 2.1–2.6× faster than `BitmapAnd`.
- Stock PostgreSQL's Index Scan, where it picks one, is 2.2–3.0× slower
  than the node. For the pair at 10M rows it picked `BitmapAnd` after two
  of the three loads and an Index Scan after the third: the plans are
  close in cost and the statistics are a sample. The node's plan and
  counters did not change.
- `BitmapAnd` at 50M rows was about 20 % faster in the first run than in
  the other two, for all three queries, with the same buffers; the node was
  not. One load differing from the next is part of the spread, which is why
  three loads and not one.
- With leapfrog the planner picks the node for the pair queries at every
  size, and an Index Scan for the deleted rows (README, Current
  limitations).

### Three runs with `shared_buffers` 128MB

The same three runs on a server with PostgreSQL's default `shared_buffers`
(128MB, the `leapfrog-dev` container), same commit and settings otherwise.
Median (90th percentile) of 33 runs:

| Rows | Query | Index Merge Intersect, ms | BitmapAnd, ms | Stock choice, ms |
|---:|---|---:|---:|---|
| 1M | pair | 0.97 (1.61) | 4.21 (4.35) | BitmapAnd 4.11 (4.37) |
| 10M | pair | 1.27 (1.50) | 64.1 (69.4) | Index Scan 2.76 (3.05) in runs 1 and 3, BitmapAnd 61.0 (66.2) in run 2 |
| 50M | pair | 1.33 (1.73) | 279 (290) | Index Scan 3.37 (18.1) |
| 1M | deleted | 0.78 (1.20) | 8.69 (9.10) | Index Scan 2.35 (2.91) |
| 10M | deleted | 0.68 (1.25) | 76.8 (95.7) | Index Scan 2.59 (3.29) |
| 50M | deleted | 0.99 (1.31) | 605 (615) | Index Scan 2.44 (6.95) |
| 1M | pair, all rows | 1.76 (2.25) | 3.98 (4.63) | BitmapAnd 4.21 (4.88) |
| 10M | pair, all rows | 17.1 (17.7) | 43.4 (47.2) | BitmapAnd 43.4 (47.1) |
| 50M | pair, all rows | 90.5 (92.3) | 233 (241) | BitmapAnd 233 (240) |

- The node's times are within the spread of the 512MB runs: the 133–179
  pages it reads stay in shared buffers either way.
- `BitmapAnd` at 50M rows reads 15,656 and 64,063 pages, more than 128MB
  holds, and is up to 1.5× slower than with 512MB.
- The stock Index Scan at 50M rows has a tail (90th percentile 7–18 ms
  against a median of 2.4–3.4 ms): some of its 1,454–4,534 heap pages come
  from the OS cache or the disk.

### Deleted rows in batches, three runs at 1M, 10M and 50M rows

`bitmap_bench.sh DELETED=batches` on the same server and settings
(`WORK_MEM=256MB WARMUP=5`, `shared_buffers` 512MB), three runs at 1M and
10M rows and three at 50M, each on a freshly loaded table. The id range is
cut into 64 blocks; a customer's rows in a block are deleted all or none,
in every 8th block, a different one for each customer, 12.5 % of the rows
in all; the rows are loaded in random physical order. Customer 7 has no
deleted rows in the 6 newest blocks; the other customers have theirs there.
Median (90th percentile) of 33 runs, then the medians of the three runs.

| Rows | Query | Index Merge Intersect, ms | per run | BitmapAnd, ms | per run | Stock choice, ms | With leapfrog, ms |
|---:|---|---:|---|---:|---|---|---|
| 1M | deleted | 1.27 (1.48) | 1.18 1.46 1.10 | 10.7 (16.4) | 10.6 16.3 10.6 | Index Scan 0.81 (1.13) | Index Merge Intersect 1.01 (1.40) |
| 10M | deleted | 6.83 (7.12) | 6.80 6.49 6.90 | 120 (127) | 123 117 122 | Index Scan 6.34 (6.82) | Index Merge Intersect 6.37 (6.99) |
| 50M | deleted | 44.7 (344) | 31.7 44.5 51.9 | 1,464 (2,865) | 1,409 1,404 2,775 | Index Scan 37.0 (5,108) | Index Merge Intersect 49.3 (243) |
| 1M | pair | 1.20 (1.65) | 1.05 1.47 0.98 | 4.32 (5.87) | 4.31 5.39 4.09 | BitmapAnd 4.31 (5.84) | Index Merge Intersect 1.52 (1.72) |
| 10M | pair | 0.87 (1.48) | 1.07 0.83 0.87 | 46.2 (49.4) | 45.7 46.1 47.7 | BitmapAnd 46.7 (51.0) | Index Merge Intersect 0.83 (1.44) |
| 50M | pair | 1.08 (1.58) | 1.10 1.08 1.06 | 268 (277) | 267 268 273 | Index Scan 3.96 (4.37) | Index Merge Intersect 1.32 (1.71) |
| 1M | pair, all rows | 1.62 (2.24) | 1.65 1.60 1.62 | 4.21 (4.75) | 4.43 3.89 4.21 | BitmapAnd 3.91 (4.55) | Index Merge Intersect 1.64 (2.31) |
| 10M | pair, all rows | 17.4 (18.2) | 17.3 17.6 17.3 | 47.9 (50.7) | 45.8 49.0 48.2 | BitmapAnd 47.6 (49.7) | Index Merge Intersect 17.2 (17.8) |
| 50M | pair, all rows | 86.8 (89.8) | 86.8 86.8 86.8 | 278 (326) | 275 280 285 | BitmapAnd 278 (289) | Index Merge Intersect 86.5 (88.5) |

The stock Index Scan is on `(customer_id, id)` with `deleted_at IS NOT
NULL` as a filter. Buffers, Index Merge Intersect / Index Scan /
`BitmapAnd`, for the deleted rows: 146 / 1,042 / 1,551 at 1M rows, 470 /
9,556 / 15,794 at 10M, 1,896 / 47,200 / 78,797 at 50M; index entries read
by Index Merge Intersect 13,692, 127,838 and 633,657.

The deleted-rows query split by whether the plan ran right after
`BitmapAnd` (in the ABBA order the Index Scan does so in the even runs,
Index Merge Intersect in the odd ones), median and range:

| Rows | Index Merge Intersect, other runs, ms | right after BitmapAnd, ms | Index Scan, other runs, ms | right after BitmapAnd, ms |
|---:|---|---|---|---|
| 1M | 1.34 (0.71–1.56) | 1.23 (0.71–1.59) | 0.78 (0.50–1.09) | 0.93 (0.71–1.23) |
| 10M | 6.90 (6.18–7.68) | 6.75 (6.32–7.54) | 6.30 (5.46–11.3) | 6.39 (6.05–9.89) |
| 50M | 43.6 (29.9–52.1) | 45.4 (29.9–378) | 33.8 (30.3–37.8) | 4,461 (3,950–5,192) |

- At 1M and 10M rows everything is in memory, and the Index Scan is as
  fast or faster: Index Merge Intersect reads 7–20× fewer pages, but steps
  through the other customers' deleted entries, about 8 ids apart, too
  close for skip-ahead (README, Skip-ahead).
- At 50M rows `BitmapAnd` evicts the Index Scan's 47,200 pages from shared
  buffers and the OS cache; the Index Scan right after it reads about
  43,000 of them back and takes 4–5 s (in the last run's plans: 42,890–
  43,013 pages read). Index Merge Intersect's 1,896 pages mostly stay; in
  6 of its 18 runs after `BitmapAnd` (runs 5 and 7 of each load) it read
  about 1,500 back and took 237–378 ms.
- With leapfrog the planner picks Index Merge Intersect for every query at
  every size; for the deleted rows at 1M rows that is 1.01 ms against the
  stock 0.81 ms.
- The pair queries are as with evenly deleted rows, except that the
  random physical order makes the stock Index Scan at 50M rows read 6,245
  pages instead of 4,534.

### Deleted rows in batches, 50M rows with `shared_buffers` 1.5GB

The same three loads at 50M rows (`DELETED=batches WORK_MEM=256MB
WARMUP=5`) on a server with `shared_buffers` 1.5GB, enough for the 1,896,
47,200 and 78,797 pages of the three plans together: no page of any
measured run was read from outside shared buffers. The deleted-rows query,
33 runs:

| Plan | Median, ms | 90th percentile, ms | Range, ms | Per load, ms |
|---|---:|---:|---|---|
| Index Merge Intersect | 31.6 | 32.3 | 30.9–34.3 | 31.5 31.6 31.6 |
| Stock: Index Scan on `(customer_id, id)` | 31.7 | 33.9 | 30.0–35.9 | 31.3 30.9 33.1 |
| `BitmapAnd` | 857 | 899 | 792–974 | 846 821 885 |
| With leapfrog (Index Merge Intersect) | 31.7 | 33.4 | 29.7–34.3 | 31.5 31.3 32.1 |

- With every page in memory the node and the Index Scan take the same
  time, the node stepping through 633,657 index entries, the Index Scan
  checking 47,000 heap rows; `BitmapAnd` is 27× slower.
- The spread is small here (90th percentile within 7 % of the median), so
  the tails in the 512MB runs above come from pages read back, not from
  the plans.

### Earlier: one run at `daf9ece`

The README's table before the three runs above: one run, the four modes
always in the same order (node, bitmap, stock, auto), `shared_buffers`
512MB, `WORK_MEM=256MB WARMUP=5`. Medians of 11 runs. The node's are
within 0.4 ms of the three runs above with a `LIMIT`, and 86.4 ms against
84.2–84.5 for all rows at 50M; `BitmapAnd`'s at 50M rows were
higher (237, 505 and 286 ms against run medians of 180–235, 362–413 and
181–226), one more load-to-load difference.

| Rows | Query | Index Merge Intersect, ms | BitmapAnd, ms | Stock choice, ms | With leapfrog, ms | Index entries, Index Merge Intersect / BitmapAnd |
|---:|---|---:|---:|---|---|---:|
| 1M | pair | 0.98 | 3.99 | BitmapAnd 3.59 | Index Merge Intersect 1.36 | 17,587 / 30,236 |
| 10M | pair | 1.21 | 52.6 | BitmapAnd 53.6 | Index Merge Intersect 1.50 | 13,682 / 299,961 |
| 50M | pair | 1.01 | 237 | Index Scan 3.51 | Index Merge Intersect 1.54 | 18,621 / 1,500,743 |
| 1M | deleted | 0.59 | 8.23 | Index Scan 2.33 | Index Scan 2.11 | 10,752 / 110,458 |
| 10M | deleted | 0.58 | 67.9 | Index Scan 2.77 | Index Scan 1.84 | 10,891 / 1,100,609 |
| 50M | deleted | 0.68 | 505 | Index Scan 3.04 | Index Scan 3.15 | 10,980 / 5,501,611 |
| 1M | pair, all rows | 2.04 | 3.79 | BitmapAnd 4.20 | Index Merge Intersect 2.01 | 30,236 / 30,236 |
| 10M | pair, all rows | 17.1 | 36.5 | BitmapAnd 36.4 | Index Merge Intersect 17.3 | 299,961 / 299,961 |
| 50M | pair, all rows | 86.4 | 286 | BitmapAnd 286 | Index Merge Intersect 86.8 | 1,500,743 / 1,500,743 |

It agrees with the earlier runs below, made on the C code before
`0366f2c` with `work_mem` set per size: the node's counters are the same,
its times within the usual spread.

### Earlier runs: 100k to 10M rows, `work_mem` 4MB and 64MB

`bitmap_bench.sh` at commit `d2ea3d4`, same container and laptop as above
(`shared_buffers` 512MB here, `random_page_cost` 4). Table: `customer_id`
100 values, `product_id` 50 values, 10 % of the rows deleted, all hashed;
indexes `(customer_id, id)`, `(product_id, id)` and `(id) WHERE deleted_at
IS NOT NULL`. Each query runs as the node (stock scans disabled, not
`leapfrog.force`), as a bitmap plan (Index Scan and Seq Scan disabled),
as stock PostgreSQL and as PostgreSQL with leapfrog; the four interleaved,
2 warm-up and 11 measured runs, medians in milliseconds.

Queries: `customer_id = 7 AND product_id = 3 ORDER BY id DESC LIMIT 100`
(pair), `customer_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT
100` (deleted) and the pair without `LIMIT` (pair, all rows: 20, 178 and
1,936 rows at the three sizes).

| Rows | Query | Index Merge Intersect, ms | BitmapAnd, ms | Stock choice, ms | With leapfrog, ms | Index entries, Index Merge Intersect / BitmapAnd |
|---:|---|---:|---:|---|---|---:|
| 100k | pair | 0.42 | 0.75 | BitmapAnd 0.65 | Index Merge Intersect 0.38 | 3,065 / 3,065 |
| 1M | pair | 1.06 | 4.27 | BitmapAnd 4.23 | Index Merge Intersect 1.14 | 17,587 / 30,236 |
| 10M | pair | 0.78 | 214 (lossy) | Index Scan 2.82 | Index Merge Intersect 0.84 | 13,682 / 299,961 |
| 100k | deleted | 1.09 | 1.18 | Index Scan 3.09 | Index Scan 2.85 | 9,862 / 11,033 |
| 1M | deleted | 0.61 | 8.90 | Index Scan 2.59 | Index Scan 1.91 | 10,752 / 110,458 |
| 10M | deleted | 0.61 | 312 (lossy) | Index Scan 2.97 | Index Scan 2.00 | 10,891 / 1,100,609 |
| 100k | pair, all rows | 0.30 | 0.69 | BitmapAnd 0.57 | Index Merge Intersect 0.38 | 3,065 / 3,065 |
| 1M | pair, all rows | 1.97 | 3.82 | BitmapAnd 4.29 | Index Merge Intersect 1.80 | 30,236 / 30,236 |
| 10M | pair, all rows | 17.7 | 208 (lossy) | BitmapAnd 210 | Index Merge Intersect 17.8 | 299,961 / 299,961 |

At 10M rows the bitmaps outgrow the default `work_mem` of 4MB and turn
lossy: 25,000–33,000 heap pages kept whole and 1.8–2.3 million rows
removed by the recheck. A second run at 10M with `WORK_MEM=64MB` keeps them
exact:

| 10M rows, `work_mem` 64MB | Index Merge Intersect, ms | BitmapAnd, ms | Stock choice, ms | With leapfrog, ms |
|---|---:|---:|---|---|
| pair | 1.43 | 51.2 | BitmapAnd 52.0 | Index Merge Intersect 1.10 |
| deleted | 0.60 | 68.8 | Index Scan 2.62 | Index Scan 1.92 |
| pair, all rows | 16.8 | 37.4 | BitmapAnd 36.1 | Index Merge Intersect 17.0 |

- With a `LIMIT` the node's work does not grow with the table: at most
  about 18,000 index entries and 170 buffers at every size (3,065 and
  9,862 entries at 100k rows, 10,752–17,587 at 1M and 10M), while
  `BitmapAnd` reads every entry of both conditions, ten times more per ten
  times the rows. At 10M rows with exact bitmaps it is 36× (pair) and 115×
  (deleted) slower than the node; lossy, 270× and 510×.
- Without a `LIMIT` both read the same entries and buffers; the node is
  2.2× faster at 10M rows with exact bitmaps (no bitmap, no sort), 12×
  against lossy ones. This is the lower bound of the difference.
- Against the plan stock PostgreSQL picks, the margin is smaller and
  depends on `work_mem`: at 10M rows with 4MB it turns to an Index Scan
  (2.8 ms against 0.8 for the pair), with 64MB to `BitmapAnd` (52 ms).
- With leapfrog the planner picks the node for the pair queries at every
  size, and misses it for the deleted rows: the stock Index Scan on the
  partial index is estimated too cheaply (README, Current limitations).
- One run per setting; the node's pair time at 10M was 0.78 ms in one run
  and 1.43 ms in the other, the usual spread on this laptop. Entries and
  buffers are deterministic.

### Earlier runs: 50M rows, `work_mem` 4MB and 256MB

The same script and server image (the C code of `d2ea3d4`, before
`0366f2c`), `SIZES=50000000`, once with the default `work_mem` and once
with `WORK_MEM=256MB`, each on a freshly loaded table. The table and its
indexes, about 11 GB, do not fit in the laptop's memory (14 GB, about 5 GB
free).

| 50M rows | Index Merge Intersect, ms | BitmapAnd, 256MB (exact), ms | BitmapAnd, 4MB (lossy), ms | Stock choice, ms | With leapfrog, ms |
|---|---:|---:|---:|---|---|
| pair | 1.25 | 227 | 2,180 | Index Scan 3.43 | Index Merge Intersect 1.39 |
| deleted | 0.61 | 422 | 2,957 | Index Scan 2.86 | Index Scan 1.89 |
| pair, all rows (9,965) | 85.5 | 232 | 2,161 | BitmapAnd 230 | Index Merge Intersect 85.4 |

Times from the 256MB run except the lossy column. Index entries, node /
BitmapAnd: 18,621 / 1,500,743 (pair), 10,980 / 5,501,611 (deleted),
1,500,743 / 1,500,743 (all rows); buffers 179, 136 and 15,656 for the
node at every `work_mem`, 15,656 and 64,063 for exact `BitmapAnd`,
266,159 and 363,980 lossy.

- With a `LIMIT` the node reads the same at 50M rows as at 1M and 10M
  (130–180 buffers); `BitmapAnd` with exact bitmaps is 180× (pair) and
  690× (deleted) slower, lossy 1,700× and 4,800×.
- Without a `LIMIT` both read the same 1.5M entries; the node is 2.7×
  faster with exact bitmaps.
- The stock plan with a `LIMIT` is an Index Scan that stops early too, and
  the node stays 2.7× (pair) and 4.7× (deleted) faster than it, about as
  at 10M rows. In the first, 4MB run the same Index Scans took 17.5 and
  7.0 ms with the same buffers: their heap pages were read from disk on a
  table loaded just before. The second run, also freshly loaded, came after
  the first had warmed the OS cache for those pages; its times are the ones
  above. The node's pages stay in shared buffers either way.

## Not done

- 10M and 100M rows for `run.sh` (`BENCH_SIZES="10000000" bash tests/performance/run.sh`).
- OS-cold runs: everything above is with data in the OS page cache.
- Real-world data: synthetic data only.
