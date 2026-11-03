# Benchmark results

Three harnesses, all reproducible from the repository:

- [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh) —
  storage, writes and a read mix for a table with 12 filter columns, comparing
  a specialised index set with a general one;
- [`tests/performance/run.sh`](tests/performance/run.sh) — reads only, one
  filter column plus soft deletes, three index strategies over a matrix of
  distributions, deleted shares, customers and limits;
- [`tests/performance/bitmap_bench.sh`](tests/performance/bitmap_bench.sh) —
  the node against `BitmapAnd`, an Index Scan and an exact index at 100k to
  100M rows.

The list-query data sets of the section "100M rows: the list query, needles and the
middle" are [`tests/performance/list_bench.sh`](tests/performance/list_bench.sh)
(`SIZE=100000000 WORK_MEM=512MB`, `ORDER=random` or `ORDER=id`); the needle, middle and
spread data sets there were made with one-off scripts kept outside the repository, and
their data generators are quoted there.

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
  with shared buffers emptied before every query.
- The sections from "10M to 100M rows" on were measured later (2026-11-03,
  commit `fed2cfb`) on the same laptop with `shared_buffers` 512MB and the
  settings stated there; at 50M and 100M rows a part of the pages comes from
  disk.

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

## Cost of the node's own quals (against `f30cf7a`)

The node is charged for the clauses in its `Filter` instead of the whole
`baserestrictcost`, and a predicate implied by the set's other conditions no
longer counts twice in the rows fetched. PostgreSQL 18.6, one container, the
two builds in ABBA order (`f30cf7a`, change, change, `f30cf7a`); each run loads
its data and runs `ANALYZE` again.

`cost_bench.sh` (1M rows, 32 queries, 5 repeats):

| | Result |
|---|---|
| Queries where the planner's choice differs between the builds | 0 of 32 |
| Node cost, change / `f30cf7a`, median over the queries | 1.00 |
| The same, range over the queries, first and last pair of runs | 0.91–1.05 |
| The same between two runs of one build | 0.96–1.07 |

The change to the cost is smaller than what a new `ANALYZE` sample does to it:
an equality costs `cpu_operator_cost` per fetched row, little next to the heap
pages. `planning_bench.sh`, median of the two runs per build: with 1 or 2
equalities no difference above the spread between runs; with 6 equalities
planning takes 3–7 % longer (0.514 against 0.492 ms at 10 indexes, 0.528
against 0.495 at 20, 0.613 against 0.595 at 50), the clause matching the cost
model now does for every set it considers.

`run.sh` (1M rows, `uniform` and `skewed`, 10 and 50 % deleted, `LIMIT 100` and
none, 48 cases of strategy B, 5 repeats per run):

| | Result |
|---|---|
| Median `exec_ms`, change / `f30cf7a`, median over the cases | 0.95 |
| The same, range over the cases | 0.70–1.09 |
| p95, change / `f30cf7a`, median and largest over the cases | 0.88, 1.26 |
| Cases with the same median shared buffers | 46 of 48 |

Three cases, all `uniform`, 10 % deleted, deleted rows, `LIMIT 100`, change
plan between runs (`Index Merge Intersect` or `Bitmap Heap Scan`). One does so
in both builds. The other two stay on the bitmap in both `f30cf7a` runs and
take the node in one of the two runs of the change, so the change may tip such
near-equal costs; two runs per build do not settle it.

## Sort columns of any type (against `f30cf7a`)

The merge compares `Datum`s instead of `int64`, on a `bigint` sort column here.
PostgreSQL 18.6, one container, the two builds in ABBA order (`f30cf7a`, change,
change, `f30cf7a`); each run loads its data and runs `ANALYZE` again. With the
core comparator called through its pointer the node took 9 % longer (median,
`cost_bench.sh`); so the types that compare as plain integers do it inline
(`compare_values`), which gives the numbers below.

`cost_bench.sh` (1M rows, 32 queries, 9 repeats, the node forced):

| | Result |
|---|---|
| Queries where the planner's choice differs between the builds | 0 of 32 |
| Queries with other shared buffers | 0 of 32 |
| Median time, change / `f30cf7a`, median over the queries | 1.04 |
| The same, range over the queries | 0.65–1.21 |
| The stock plans under the same comparison, median and range | 0.96, 0.74–1.35 |

The full merges of about 100,000 entries pay the most: `region0+deleted`
7.9–8.4 ms against 8.7–8.8 (+8 %), `region5+archived` 5.1–5.2 against 6.1–6.2
(+19 %), `region9+customer` 5.0–5.2 against 5.5 (+8 %), with the same buffers.
The spread of the stock plans shows how much of the range is noise; the medians
of the heavy merges are not.

`run.sh` (1M rows, `uniform` and `skewed`, 10 and 50 % deleted, `LIMIT 100` and
none, 48 cases of strategy B, 5 repeats per run): median `exec_ms` 1.06 of
`f30cf7a`, range 0.88–1.13; on the two cases that use the node in every run,
1.02 and 1.07. Three cases (`uniform`, 10 % deleted, deleted rows, `LIMIT 100`)
change plan between runs, here in one run of `f30cf7a` only.

`planning_bench.sh`, median of the two runs per build: no difference above the
spread with 1 or 2 equalities; with 6, 0.670 against 0.642 ms at 10 indexes,
0.684 against 0.652 at 20, 0.839 against 0.787 at 50 (4–7 %).

## Planning (against `9d5422d`)

The MySQL-style pass, the merge in turns from the sparsest stream, the shares from
statistics read once and the pruning, on one build, against `fix/external-review`
(`9d5422d`), in ABBA order. PostgreSQL 18.6, one container, data loaded and
analyzed anew per run.

`planning_bench.sh`, median of two runs per build, 200 plans each, ms:

| Indexes | Equalities | Extension off | `9d5422d` | This build |
|---:|---:|---:|---:|---:|
| 10 | 1 | 0.04 | 0.12 | 0.07 |
| 10 | 2 | 0.05 | 0.16 | 0.10 |
| 10 | 6 | 0.07 | 0.66 | 0.15 |
| 20 | 1 | 0.06 | 0.14 | 0.09 |
| 20 | 2 | 0.07 | 0.18 | 0.13 |
| 20 | 6 | 0.09 | 0.68 | 0.17 |
| 50 | 1 | 0.11 | 0.19 | 0.14 |
| 50 | 2 | 0.12 | 0.24 | 0.17 |
| 50 | 6 | 0.16 | 0.84 | 0.26 |

Where the hook's time goes, one instrumented build (timers around each function,
not committed), 10 indexes, 6 equalities, ms per plan:

| | `9d5422d` | MySQL-style pass only | This build |
|---|---:|---:|---:|
| The hook | 0.799 | 0.178 | 0.074 |
| Finding the equalities | 0.004 | 0.003 | 0.003 |
| `probe_range` | 0.125 | 0.053 | 0.054 |
| Shares of the ranges | 0.522 | 0.106 | 0.002 |
| Rows, `Filter` and the rest of the costing | 0.082 | 0.008 | 0.007 |
| Sets costed | 41 | 3 | 3 |

So a cost computed incrementally, as `ROR_intersect_plan::add` does, was not worth
doing: all it could save is a few microseconds of that "rest". The pruning does not
fire on this table, where the fourth stream still pays; on `leapfrog_planner`'s it
saves one set and one range probe of three.

`cost_bench.sh` (1M rows, 32 queries, 9 repeats): the planner's choice differs in
none. Node time, minimum of the two runs per build, change / `9d5422d`: median 0.85,
range 0.50–0.96, same buffers on 28 of the 32 and fewer on the other 4. Node cost median 1.00, range
0.26–1.04; the lowest is the three-stream `customer+product+deleted`, which reads half
the entries (0.58 ms against 0.30, 95 buffers against 49), with the estimated entries
close to those read.

`run.sh` (1M rows, 48 cases of strategy B, 5 repeats per run): median `exec_ms` 0.87,
range 0.66–1.00, of `9d5422d`. One case (`uniform`, 10 % deleted, deleted rows,
`LIMIT 100`, large owner) took the node in one run of `9d5422d` and the bitmap in the
others, as in earlier comparisons.

Three streams with a dense third, 1M rows, the node forced, median of 15, ms: 2,000
and 2,000 entries with 40,000: 0.80 against 0.27; with 460,000: 0.87 against 0.29.
20,000, 40,000 and 460,000: 31 against 24. Before the order from the sparsest stream,
the circle of `RowIDIntersectionIterator::DoRead` took 2.0 and 22 in the first two.

## Duplicates of the sort value (against `v0.0.4`)

The node reads the whole group of a value before its first row. Startup now counts
the group of the first value. `SELECT * … WHERE user_id = 7 AND status = 2 ORDER BY
created_at DESC LIMIT 100`, 1.2M rows, indexes `(user_id, created_at)` and
`(status, created_at)`, data in memory, median of 7, ABBA, ms:

| `created_at` | `v0.0.4`, the planner's choice | Change, the planner's choice | Stock |
|---|---:|---:|---:|
| 1M rows on the newest value | 2.8 (node, 102 buffers) | 0.08-0.13 (Index Scan, 143 buffers) | 0.08-0.13 |
| 10 values | 0.6-0.7 (node, 110 buffers) | 0.6-0.9 (node) | 0.10-0.27 (335 buffers) |
| unique | 0.26 (node, 93 buffers) | 0.26-0.40 (node) | 0.07-0.10 (114 buffers) |

The same at `random_page_cost` 1.1. The last two rows do not change: the node
touches fewer buffers there and costs less, and is slower with the data in memory.
None of this was measured with cold data. The group fits in `work_mem` in all of
them; no group overflowed.

`cost_bench.sh` (32 queries): the choice differs in none; node time 1.01 of `v0.0.4`
in median, cost 0.95-1.17. `run.sh`: 1.00 in median. Three cases (`uniform`, 10 %
deleted, deleted rows, `LIMIT 100`) change plan between runs in both builds.
`planning_bench.sh`: no change above the spread between runs.

## First group behind a row, in a generic plan (against `b03a8d9`)

`SELECT * … WHERE user_id = 7 AND status = 2 ORDER BY created_at DESC LIMIT 100`,
1.2M rows, `user_id` 50 values, `status` 4, indexes `(user_id, created_at)` and
`(status, created_at)`, data in memory, ABBA, the median of 7 of each run, ms, the
planner's choice:

| `created_at` | `b03a8d9` | Change |
|---|---:|---:|
| 1M rows on the newest value, one row ahead of them | 3.8, 5.7 (node, 103 buffers) | 0.14, 0.14 (Index Scan, 144 buffers) |
| 1M rows on the newest value, generic plan | 6.6, 5.5 (node, 103 buffers) | 0.23, 0.21 (Index Scan, 144 buffers) |
| The same, one row ahead of them | 6.6, 6.1 (node, 103 buffers) | 0.21, 0.22 (Index Scan, 144 buffers) |
| 1M rows on the newest value | 6.6, 6.6 (node, 103 buffers) | 0.17, 0.17 (Index Scan, 144 buffers) |
| unique, `LIMIT 100` | 0.69, 0.66 (node, 89 buffers) | 0.54, 0.57 (node, 89 buffers) |
| unique, `LIMIT 1` | 0.03, 0.03 (Index Scan) | 0.04, 0.03 (Index Scan) |

The fourth row is near the point where `b03a8d9` changes plan: on another `ANALYZE`
sample of the same data it chose the Index Scan (0.17-0.23 ms).

With `shared_buffers` emptied by a restart before each query (the median of 5, the
files still in the page cache of the system): 8.8, 9.2 against 3.0, 3.2 with a row
ahead; 8.8, 8.9 against 3.1, 3.0 on the value alone; unique 2.6, 2.5 against 2.4, 2.4.

With rows 60 bytes wider and `user_id` of 1,000 values, measured before the groups
further on were costed, neither build left the node (7-13 ms, 186 buffers, against
an Index Scan of more buffers): reading the outer stream through that value is the
time there, the case of "slower with the data in memory" above. No group overflowed
in any of these.

`cost_bench.sh` (32 queries, ABBA, a database per build): the node's buffers do not
change, the median time of the planner's choice is 0.77, 0.79 against 0.80, 0.81 ms.
One choice differs: `customer+deleted`, `desc 10`, left in one of the two runs of the
change and kept in the other (the two plans cost within a few units); a run of a build
loads its data anew.

`run.sh` (1M rows, 10 % deleted, 44 rows of the summary, ABBA): 1.00-1.02 of `b03a8d9`
in median in every column, and no query apart by more than 30 % in both runs above
0.2 ms. `planning_bench.sh` (100 repeats, ABBA), time on minus time off, 6 equalities,
ms: 10 indexes 0.168, 0.130 against 0.183, 0.179; 20 indexes 0.117, 0.082 against
0.182, 0.176; 50 indexes 0.083, 0.087 against 0.085, 0.091. The time off, which the
change cannot affect, moves as much between runs with 20 indexes (0.114-0.225), so
this bounds the cost and does not settle it. These tables have no common values
to look up.

## 10M to 100M rows, reads and writes (`fed2cfb`)

One laptop (14 GB of memory, 16 threads), `shared_buffers` 512MB, other containers idle.
`bitmap_bench.sh`, `WARMUP=5`, `WORK_MEM=256MB` (512MB at 100M), median of 11, ms. Every
bitmap exact (no lossy heap blocks). Pages outside `shared_buffers` come from the OS page
cache or the disk, which the script does not tell apart; that matters from 50M on.

The columns: "exact index" has indexes made for the query, with the extension off. "Node"
forces the node on the small indexes, "auto" is the planner's choice with the extension on,
"stock" with it off, and `BitmapAnd` is forced. Only "exact" has the three extra indexes,
and it runs as a separate block after the others on the same table, not interleaved.

Two filters, `LIMIT 1`:

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 0.03 | 0.07 | node 0.07 | Index Scan 0.07 | 99.0 | 5, 8, 35 |
| 20M | `hashed` | 0.04 | 0.04 | node 0.05 | Index Scan 0.04 | 153 | 5, 9, 9 |
| 50M | `hashed` | 0.03 | 0.06 | node 0.06 | Index Scan 0.05 | 465 | 5, 9, 15 |
| 100M | `hashed` | 0.04 | 0.06 | node 0.05 | Index Scan 0.04 | 548 | 5, 10, 15 |
| 10M | `batches` | 0.04 | 0.04 | node 0.04 | Index Scan 0.07 | 64.3 | 5, 8, 45 |
| 20M | `batches` | 0.04 | 0.05 | node 0.05 | Index Scan 0.05 | 200 | 5, 9, 12 |
| 50M | `batches` | 0.03 | 0.06 | node 0.06 | Index Scan 0.06 | 506 | 5, 9, 18 |
| 100M | `batches` | 0.03 | 0.05 | node 0.04 | Index Scan 0.05 | 607 | 5, 10, 23 |

Two filters, `LIMIT 100`:

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 0.13 | 1.75 | node 1.71 | Index Scan 3.65 | 94.0 | 101, 156, 3,382 |
| 20M | `hashed` | 0.09 | 1.84 | node 1.77 | Index Scan 3.91 | 172 | 104, 164, 3,506 |
| 50M | `hashed` | 0.13 | 1.47 | node 1.09 | Index Scan 3.85 | 251 | 105, 179, 4,534 |
| 100M | `hashed` | 0.12 | 1.01 | node 0.77 | Index Scan 2.79 | 495 | 104, 161, 3,331 |
| 10M | `batches` | 0.09 | 1.73 | node 1.73 | Index Scan 4.73 | 102 | 104, 159, 4,597 |
| 20M | `batches` | 0.08 | 1.87 | node 1.87 | Index Scan 5.07 | 201 | 104, 164, 4,818 |
| 50M | `batches` | 0.13 | 2.21 | node 2.18 | Index Scan 5.56 | 455 | 105, 179, 6,245 |
| 100M | `batches` | 0.13 | 1.16 | node 1.24 | Index Scan 3.26 | 552 | 104, 161, 4,643 |

Two filters, `LIMIT 1000`:

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 1.01 | 18.6 | node 18.5 | `BitmapAnd` 94.2 | 97.0 | 1,000, 1,571, 3,077 |
| 20M | `hashed` | 1.05 | 8.93 | node 9.00 | `BitmapAnd` 83.4 | 82.1 | 1,003, 1,582, 6,244 |
| 50M | `hashed` | 0.91 | 9.26 | node 9.04 | `BitmapAnd` 254 | 253 | 1,006, 1,592, 15,656 |
| 100M | `hashed` | 0.91 | 8.66 | node 8.48 | `BitmapAnd` 526 | 533 | 1,003, 1,571, 31,337 |
| 10M | `batches` | 1.11 | 18.3 | node 18.4 | `BitmapAnd` 97.5 | 98.8 | 1,008, 1,579, 3,080 |
| 20M | `batches` | 1.03 | 9.15 | node 9.02 | `BitmapAnd` 109 | 110 | 1,009, 1,588, 6,240 |
| 50M | `batches` | 0.56 | 9.06 | node 9.06 | `BitmapAnd` 263 | 264 | 1,009, 1,595, 15,665 |
| 100M | `batches` | 0.92 | 8.93 | node 8.69 | `BitmapAnd` 576 | 592 | 1,009, 1,577, 31,343 |

Two filters, no `LIMIT`, all rows found (1,936, 3,962, 9,965, 19,973):

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 4.32 | 16.9 | node 16.9 | `BitmapAnd` 49.8 | 49.4 | 1,934, 3,077, 3,077 |
| 20M | `hashed` | 8.18 | 33.9 | node 34.3 | `BitmapAnd` 78.3 | 75.4 | 3,959, 6,244, 6,244 |
| 50M | `hashed` | 23.8 | 83.5 | node 85.0 | `BitmapAnd` 226 | 226 | 9,951, 15,656, 15,656 |
| 100M | `hashed` | 44.2 | 166 | node 167 | `BitmapAnd` 478 | 485 | 19,932, 31,337, 31,337 |
| 10M | `batches` | 4.15 | 18.4 | node 17.2 | `BitmapAnd` 51.8 | 51.4 | 1,937, 3,092, 3,080 |
| 20M | `batches` | 9.27 | 33.5 | node 34.2 | `BitmapAnd` 80.5 | 81.2 | 3,955, 6,270, 6,240 |
| 50M | `batches` | 25.7 | 85.5 | node 85.9 | `BitmapAnd` 261 | 260 | 9,960, 15,723, 15,665 |
| 100M | `batches` | 48.2 | 173 | node 173 | `BitmapAnd` 577 | 594 | 19,938, 31,480, 31,343 |

One filter and deleted rows, `LIMIT 100`:

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 0.12 | 1.29 | Index Scan 3.35 | Index Scan 3.56 | 165 | 96, 133, 1,447 |
| 20M | `hashed` | 0.09 | 0.83 | Index Scan 1.86 | Index Scan 2.65 | 161 | 100, 139, 1,522 |
| 50M | `hashed` | 0.08 | 1.01 | Index Scan 2.00 | Index Scan 2.54 | 427 | 99, 136, 1,454 |
| 100M | `hashed` | 0.14 | 1.01 | Index Scan 2.38 | Index Scan 4.41 | 1,264 | 101, 140, 1,523 |
| 10M | `batches` | 0.13 | 7.27 | node 6.97 | Index Scan 7.15 | 158 | 104, 470, 9,556 |
| 20M | `batches` | 0.13 | 11.8 | node 11.6 | Index Scan 11.7 | 270 | 104, 828, 18,787 |
| 50M | `batches` | 0.07 | 28.5 | node 28.2 | Index Scan 42.8 | 1,063 | 104, 1,896, 47,200 |
| 100M | `batches` | 0.07 | 67.6 | node 59.0 | Index Scan 445 | 2,278 | 104, 3,681, 94,689 |

Two filters and deleted rows, `LIMIT 100`:

| Rows | Deleted | Exact index | Node | Auto | Stock | `BitmapAnd` | Buffers: exact, node, stock |
|---:|---|---:|---:|---:|---:|---:|---:|
| 10M | `hashed` | 0.09 | 12.0 | node 11.7 | `BitmapAnd` 55.0 | 56.4 | 102, 1,704, 3,077 |
| 20M | `hashed` | 0.11 | 12.6 | node 15.6 | Index Scan 649 | 132 | 104, 1,814, 84,623 |
| 50M | `hashed` | 0.12 | 9.14 | node 10.3 | Index Scan 392 | 270 | 103, 1,642, 77,876 |
| 100M | `hashed` | 0.12 | 8.30 | node 8.10 | Index Scan 341 | 566 | 104, 1,521, 70,172 |
| 10M | `batches` | 0.15 | 8.01 | node 8.10 | `BitmapAnd` 43.2 | 46.7 | 104, 1,515, 3,080 |
| 20M | `batches` | 0.11 | 7.94 | node 7.75 | `BitmapAnd` 81.9 | 83.4 | 103, 1,460, 6,240 |
| 50M | `batches` | 0.13 | 8.57 | node 8.63 | `BitmapAnd` 258 | 255 | 104, 1,613, 15,665 |
| 100M | `batches` | 0.08 | 17.0 | node 16.6 | Index Scan 454 | 652 | 105, 3,138, 99,054 |

Sizes with `hashed`, GB. The small set is what the node needs; the exact indexes come on top:

| Rows | Table | Small set | `(customer_id, product_id, id)` | `(customer_id, id)`, deleted | `(customer_id, product_id, id)`, deleted |
|---:|---:|---:|---:|---:|---:|
| 10M | 1.10 | 0.82 | 0.38 | 0.03 | 0.04 |
| 20M | 2.20 | 1.64 | 0.76 | 0.06 | 0.08 |
| 50M | 5.49 | 4.09 | 1.89 | 0.15 | 0.19 |
| 100M | 10.99 | 8.18 | 3.78 | 0.29 | 0.38 |

Compare along a row more than down a column. Each size is one load, and the same work can
take twice as long on another one: the node at `LIMIT 1000` takes 18.6 ms at 10M and 8.9 ms
at 20M for 1,571 and 1,582 buffers, the cause not looked into. Buffers are the steadier
measure.

What the tables show:

- An exact index wins nearly every query, but by very different margins against the node:
  within 3 times at `LIMIT 1`, about 4 times with no `LIMIT`, 7 to 20 times at `LIMIT 100`,
  and up to 900 times for rare matches at 100M.
- With `LIMIT` reached and matches common, the node does not grow with the table:
  161 to 179 buffers at `LIMIT 100`, 8 to 10 at `LIMIT 1`.
- With rare matches it grows in step with the table: deleted rows in `batches` take 3,681
  buffers at 100M against 470 at 10M. So does the query with no `LIMIT`, as the number of
  rows found grows.
- The planner leaves the node for an Index Scan on the `hashed` deleted query at every size,
  at 2 to 2.6 times the time (`auto` against "node").
- Stock's plan can change between loads. At 10M two filters with `LIMIT 100` took `BitmapAnd`
  in one load, 77 ms, and an Index Scan in another, 3.6 ms; at 20M to 100M three filters in
  `hashed` take an Index Scan at 340 to 650 ms, at 10M `BitmapAnd` at 55 ms.
- The three exact indexes add 54 % to the small set's size (4.45 GB on 8.18 GB at 100M).

`write_bench.sh`, `BASE_ROWS` 20M, `BATCH_ROWS` 100,000, strategies M and G (one load each,
the same generator as S and G below), median of 5 for reads. M is the 9 composite
indexes of S plus `(fK, id)` for the 6 columns no composite starts with, 15 indexes; G
14 general ones:

| | M, 20M | G, 20M |
|---|---:|---:|
| Index size | 11.18 GB | 8.02 GB |
| `INSERT` 100,000 rows: WAL | 3,595 MB | 166 MB |
| `INSERT`: rows per second | 945 | 12,592 |
| `UPDATE` of a filter column, 25,000 rows: WAL | 1,004 MB | 70 MB |
| The same: rows per second | 1,059 | 6,354 |
| Soft delete, 25,000 rows: WAL | 46 MB | 77 MB |
| `DELETE`, 25,000 rows: WAL | 18 MB | 18 MB |

Reads with M at 20M rows, `random_page_cost` 1.1, `LIMIT 100`, ms: the queries with a
composite index of their own 0.03–0.08 (Index Scan on it, with leapfrog on as well);
one filter on deleted rows 460 (no partial index in M: Index Scan on `(f5, id)`
filtering `deleted_at`); two, three and four filters without a composite 304, 299 and
300 for stock (`BitmapAnd`) against 1.2, 29 and 29 with leapfrog merging M's
single-column indexes. So the node serves the specialised set too, for the
combinations it has no index for.

`write_bench.sh`, `BASE_ROWS` 10M and 20M, `BATCH_ROWS` 100,000, median of 5 for reads. S is
33 specialised indexes, G 14 general ones. The extension plays no part in the write
numbers: they compare the two index sets. Rows per second are one run. S at 50M and 100M
does not fit on this disk (about 43 GB and 85 GB of indexes), and G at 50M ran out of its
34 GB free during the load.

| | S, 10M | G, 10M | S, 20M | G, 20M |
|---|---:|---:|---:|---:|
| Index size | 7.49 GB | 4.01 GB | 14.97 GB | 8.02 GB |
| `INSERT` 100,000 rows: WAL | 3,275 MB | 165 MB | 3,793 MB | 166 MB |
| `INSERT`: rows per second | 959 | 14,476 | 747 | 13,746 |
| `UPDATE` of a filter column, 25,000 rows: WAL | 980 MB | 70 MB | 1,029 MB | 70 MB |
| The same: rows per second | 1,104 | 11,329 | 800 | 9,631 |
| Soft delete, 25,000 rows: WAL | 68 MB | 77 MB | 68 MB | 77 MB |
| The same: rows per second | 10,861 | 8,227 | 9,058 | 9,024 |
| `DELETE`, 25,000 rows: WAL | 18 MB | 18 MB | 18 MB | 18 MB |

Where the INSERT WAL comes from. The same 20M table, the index groups of S added one at
a time, `EXPLAIN (ANALYZE, WAL)` of an `INSERT` of 100,000 rows after a `CHECKPOINT`,
`full_page_writes` on, `wal_compression` off, one run per set (ad hoc script, not in
the repository; `seconds` is the execution time):

| Index set, added one group at a time | Indexes | WAL, 100k INSERTs | Full-page images | Time |
|---|---:|---:|---:|---:|
| The 14 general indexes | 14 | 157 MB | 3,593 | 5.6 s |
| 24 single-column partial indexes | 24 | 150 MB | 3,591 | 8.5 s |
| + 6 two-column composites | 30 | 603 MB | 63,626 | 25 s |
| + 2 three-column composites | 32 | 2,866 MB | 373,518 | 93 s |
| + 1 four-column composite = the 33 | 33 | 3,785 MB | 547,729 | 149 s |

The same for the groups of M, one run per set, a separate load of the same data:

| Index set, added one group at a time | Indexes | WAL, 100k INSERTs | Full-page images | Time |
|---|---:|---:|---:|---:|
| The 14 general indexes | 14 | 157 MB | 3,593 | 7.3 s |
| 6 single-column indexes | 6 | 89 MB | 1,797 | 4.1 s |
| + 6 two-column composites | 12 | 550 MB | 61,832 | 23 s |
| + 2 three-column composites | 14 | 2,763 MB | 363,667 | 85 s |
| + 1 four-column composite = the 15 | 15 | 3,688 MB | 536,770 | 134 s |

The 24 single-column partial indexes cost what the 14 general ones do: a new row goes
into 13 of them (the `IS NULL` ones and the primary key) against 14. The composites add
3.6 GB of the 3.8 GB, nearly all of it full-page images: `(f1, id)` has 100 values, so
new rows append at the end of 100 runs on the same pages, while `(f1, f2, f3, id)` has a
million prefixes and each new row lands on a page of its own, logged in full on its
first write after the checkpoint. The checkpoint right before each batch makes this the
high end; the ratio between the sets stays under a steady load, the size of the gap
depends on how many pages are revisited between checkpoints.

Reads at 20M rows, `LIMIT 100`, `random_page_cost` 1.1, ms:

| Query | Rows found | S | G, stock | G, planner with the node |
|---|---:|---:|---:|---:|
| one filter, live rows | 100 | 0.04 | 0.05 | 0.04 |
| one filter, deleted rows | 100 | 0.04 | 1.73 | 0.38 |
| 2 filters, composite index in S | 100 | 0.04 | 507 | 0.60 |
| 2 filters, no composite in S | 100 | 4.27 | 267 | 0.77 |
| 3 filters, composite index in S | 21 | 0.02 | 512 | 18.0 |
| 3 filters, no composite in S | 23 | 548 | 343 | 18.0 |
| 4 filters, composite index in S | 0 | 0.01 | 210 | 18.0 |
| 4 filters, no composite in S | 0 | 552 | 251 | 17.6 |

With three or four filters fewer rows match than the `LIMIT` asks, so the merge runs to the
end of the sparsest stream, and it does not stay under a millisecond. At `random_page_cost`
4, with three or four streams at both sizes, it doubles with the rows: 32 ms at 10M, 65 ms at
20M. At 1.1 it took 22 to 28 ms at 10M and 18 ms at 20M, with up to four streams at 10M and two
at 20M, so these two loads show no growth at that page cost.

## 100M rows: the list query, needles and the middle (`fed2cfb`)

One laptop (14 GB of memory, 16 threads, NVMe), PostgreSQL 18.6 in Docker,
`shared_buffers` 512MB, `work_mem` 512MB for the queries, `jit` off, no parallel
workers, `max_parallel_maintenance_workers` 6 for the index builds. Each data set is
one load of 100M rows (`generate_series`, `hashint8` for the columns, a 60-byte
payload; table 11–12 GB), in `id` order, `VACUUM ANALYZE` before the queries. Indexes
`(customer_id, id)` and `(product_id, id)` (3 GB each) and, where the query needs it,
`(id) WHERE deleted_at IS NULL` (101 MB). The scripts (`run.sh` of each set, kept
outside the repository for now, to be folded into `tests/performance/`) run every
query in six modes, 3 measured runs in ABBA order, `EXPLAIN (ANALYZE, BUFFERS)`:

- `node`: leapfrog on, stock scans disabled; `auto`: leapfrog on, the planner's choice;
- `stock`: leapfrog off, the planner's choice; `indexscan`: leapfrog off, no bitmaps;
  `bitmap`: leapfrog off, no Index Scan;
- `exact`: leapfrog off, with an index built for the query after the other modes.

Times in ms, median of 3, with the slowest run in brackets where it differs by more
than 2×; "buffers" is the median of shared hits and reads, "read" the most pages read
from outside `shared_buffers` in a run (OS page cache or disk: not told apart). The
runs follow each other on the same server, so a plan that reads 290,000 pages evicts
what the next one needs: the cold figures are real, the warm ones are the best case.

### The list query with rare, scattered matches

`customer_id = $1 AND deleted_at IS NULL [AND product_id = $2] ORDER BY id DESC LIMIT
100`. 5 % of all rows are live. Customer 4 has 999,058 rows, customer 5 has 5,004,172,
each with exactly 500 live rows spread evenly (one per 200,000 `id`s); product 120 has
2M rows; about 11 of customer 4's live rows have it. Exact indexes `(customer_id, id)
WHERE deleted_at IS NULL` (142 MB) and `(customer_id, product_id, id) WHERE deleted_at
IS NULL` (182 MB).

| Query | Mode | ms | Plan | Buffers | Read |
|---|---|---:|---|---:|---:|
| customer 4 (1M rows) | exact | 0.4 | Index Scan, exact | 106 | 102 |
| | node | 59 (224) | Index Merge Intersect | 3,409 | 842 |
| | auto | 1,615 (3,059) | Index Scan on `(id) WHERE deleted_at IS NULL`, Filter | 290,149 | 290,146 |
| | stock | 1,614 (2,508) | the same | 290,149 | 290,149 |
| | indexscan | 1,597 (4,255) | the same | 290,149 | 290,149 |
| | bitmap | 829 | `BitmapAnd` | 17,190 | 16,719 |
| customer 5 (5M rows) | exact | 19,667 | Index Scan on `(id) WHERE deleted_at IS NULL`, Filter: the exact index not chosen | 291,619 | 291,619 |
| | node | 107 (1,054) | Index Merge Intersect | 6,476 | 5,921 |
| | auto | 1,579 (2,892) | Index Scan on the live-rows index, Filter | 291,619 | 291,616 |
| | stock | 1,600 | the same | 291,619 | 291,619 |
| | indexscan | 1,594 (3,163) | the same | 291,619 | 291,619 |
| | bitmap | 1,300 (2,290) | `BitmapAnd` | 32,536 | 32,035 |
| customer 4 and product 120 | exact | 0.1 | Index Scan, exact | 18 | 15 |
| | node | 259 (3,794) | Index Merge Intersect, three streams | 31,374 | 30,649 |
| | auto | 3,874 | Index Merge Intersect, three streams | 31,374 | 30,934 |
| | stock | 167,753 (174,925) | Index Scan on the live-rows index, Filter | 1,465,764 | 1,465,764 |
| | indexscan | 152,602 | the same | 1,465,764 | 1,465,308 |
| | bitmap | 1,126 (2,193) | `BitmapAnd` | 31,380 | 30,708 |

The stock Index Scan removes 929,658 rows by filter for customer 4 and 4,703,248 for
the third query; the node reads 198,190 outer and 929,756 inner entries for customer 4,
and 2,001,433 + 999,058 + 4,702,364 entries for the third query, with 100 and 11 heap
fetches. Written out: the text plans are in `explain-*.txt` next to the results.

Estimates. The planner expects 45,971 live rows for customer 4 (1M × the 4.5 % live
share) and 224,349 for customer 5, against 500: the statistics cannot see that a
customer's live rows are rare. Both plans are scaled by the `LIMIT` fraction of that
estimate, so the choice between them comes down to the total costs:

```
Index Scan Backward using (id) WHERE deleted_at IS NULL   cost=0.43..197514  rows=45971   with LIMIT: 430
Custom Scan (Index Merge Intersect)                        cost=7.04..277879  rows=45971   with LIMIT: 611
  Outer Entries Estimated: 1029965   Inner Entries Estimated: 4463184
```

The table is in `id` order, so the Index Scan's 4.5 million heap fetches are costed
as nearly sequential; the node is charged more for its index entries and gets no such
discount. With leapfrog loaded the planner therefore keeps the Index Scan in the first
two queries, 15–27× slower than the node, and picks the node in the third. This is the
cost-model miss to fix next, with this data set as the test. The same mis-estimate
keeps stock on the live-rows index for customer 5 even with the exact partial index
present (19.7 s, all pages from disk after the index builds).

Cold against warm: the Index Scan's 290,000 pages take 1.6 s from the OS page cache
and 19 to 23 s from disk (`explain-c1M-stock.txt`: 22.9 s, `explain-c5M-exact.txt`:
18.8 s); the node's 3,400 pages 59 ms and 224 ms.

Data generator:

```sql
INSERT INTO lf_bitmap
SELECT g, c0, 100 + abs(hashint8(g * 4 + 2)) % 50,
  CASE WHEN c0 = 4 THEN CASE WHEN g % 200000 = 0 THEN NULL ELSE '2026-01-01'::timestamptz END
       WHEN c0 = 5 THEN CASE WHEN g % 200000 = 100000 THEN NULL ELSE '2026-01-01'::timestamptz END
       WHEN h3 = 0 THEN NULL ELSE '2026-01-01'::timestamptz END,
  repeat('x', 60)
FROM (SELECT g, CASE WHEN g % 200000 = 0 THEN 4 WHEN g % 200000 = 100000 THEN 5
                     WHEN h1 = 4 THEN 4 WHEN h1 BETWEEN 5 AND 9 THEN 5 ELSE 100 + h1 END AS c0, h3
      FROM (SELECT g, abs(hashint8(g * 4 + 1)) % 100 AS h1, abs(hashint8(g * 4 + 3)) % 20 AS h3
            FROM generate_series(1, 100000000) g) s) t;
```

### The same data with the rows in random physical order

The same generator with `ORDER BY hashint8(g * 4 + 7)` on the insert, so that the heap is
in no relation to `id`, as a table is after years of updates; `work_mem` 1GB for the
load. The sort column's correlation is then near zero, the stock Index Scan's heap
reads are costed as random, and the planner with leapfrog picks the node in all three
queries. "exact_only" is the exact index with `(id) WHERE deleted_at IS NULL` dropped,
so that nothing competes with it; here the planner used the exact index in the
"exact" mode as well.

| Query | Mode | ms | Plan | Buffers | Read |
|---|---|---:|---|---:|---:|
| customer 4 (1M rows) | exact | 0.4 | Index Scan, exact | 106 | 97 |
| | node | 92 (240) | Index Merge Intersect | 3,409 | 855 |
| | auto | 159 (186) | Index Merge Intersect | 3,409 | 3,127 |
| | stock | 2,333 (3,808; text plan 22,176) | Index Scan on `(customer_id, id)`, Filter `deleted_at` | 198,956 | 190,659 |
| | indexscan | 2,132 (18,414) | the same | 198,956 | 191,091 |
| | bitmap | 1,614 | `BitmapAnd` | 17,190 | 16,901 |
| customer 5 (5M rows) | exact | 0.3 | Index Scan, exact | 106 | 99 |
| | node | 235 (879) | Index Merge Intersect | 6,476 | 6,467 |
| | auto | 880 | Index Merge Intersect | 6,476 | 6,293 |
| | stock | 91,896 (104,261) | Index Scan on the live-rows index, Filter | 937,182 | 897,804 |
| | indexscan | 96,175 | the same | 937,182 | 898,990 |
| | bitmap | 2,692 (3,365) | `BitmapAnd` | 32,536 | 32,362 |
| customer 4 and product 120 | exact | 0.3 | Index Scan, exact | 18 | 4 |
| | node | 399 (4,046) | Index Merge Intersect, two streams, `deleted_at` in `Filter`: 20,012 heap fetches | 24,383 | 24,186 |
| | auto | 3,495 | the same | 24,383 | 24,195 |
| | stock | 1,481 | `BitmapAnd` of three indexes | 24,374 | 0 |
| | indexscan | 88,663 (96,796) | Index Scan on `(customer_id, id)`, Filter | 1,002,892 | 961,692 |
| | bitmap | 1,636 | `BitmapAnd` of three indexes | 24,374 | 24,115 |

For customer 5 the stock Index Scan removes 934,525 rows by filter and reads 897,834
pages from disk: 94 s in its text plan against 0.87 s for the node (6,465 pages read).
For the third query the planner takes two streams and filters `deleted_at` on the
heap, 20,012 random fetches, where the ordered load got three streams and 11 fetches;
with the pages cached that is 0.4 s, cold 3.5–4 s, against stock's `BitmapAnd` at
1.5 s: not a win here, and the cause (the third stream's cost) is to be looked into.

### The random-order data set with the leaf page prefetch (`9e8b7cd`)

The same load through `list_bench.sh` (`SIZE=100000000 WORK_MEM=512MB`, rows in random
order) on the code with `leapfrog.prefetch` and the stream blocks of `EXPLAIN`, one
run of the three queries, 3 measured runs in ABBA order, ms, cold run in brackets:

| Query | exact | node | auto | stock | indexscan | bitmap |
|---|---:|---:|---:|---:|---:|---:|
| customer 4 (1M rows) | 0.14 | 121 (58–123) | 122 (152) | Index Scan 1,762 (4,755) | 1,822 (7,415) | 1,497 |
| customer 5 (5M rows) | 0.14 | 228 (104–228) | 160 (559) | Index Scan 117,411 | 112,480 | 2,715 |
| customer 4 and product 120 | 0.07 | 1,983 (831–2,001) | 843 (2,021) | `BitmapAnd` 1,267 | 112,025 | 2,187 |

Against the run above without the prefetch: the planner's node for customer 5 went
from 880 ms to 160 (the cold run from 886 to 559), its 6,292 pages read from outside
`shared_buffers` in both. For the third query the planner took three streams this
time, 7,702,855 entries and 11 heap fetches, where the earlier load got two streams
and 20,012 fetches: the estimate of the third stream sits close to the line, and the
statistics of a new load fell on the other side. With three streams the node beats
stock's `BitmapAnd` here, 843 against 1,267 ms. The stream blocks of the text plans
(`explain-*.txt`) show where the time goes: for customer 5, 269 ms in the customer's
index (995,834 entries, 3,815 pages read) and 90 ms in the live-rows index (934,626
entries, 2,554 pages) of a 619 ms cold run.

### Two filters, 100 matches spread one per million ids

Customers with 10k, 100k and 1M rows, products with 1M and 10M rows (`h1 =
abs(hashint8(g*4+1)) % 10000`: 0 → customer 7, 1–10 → 8, 11–110 → 9; `h2 = ... % 100`:
0 → product 3, 1–10 → 4). Each queried pair has exactly 100 rows, at `g % 1000000 =
1..5`, the pair's natural rows moved to product 99, so `ORDER BY id DESC LIMIT 100`
walks to the oldest one. Exact index `(customer_id, product_id, id)`, 3.9 GB.

| Customer × product rows | exact | node | auto | stock | indexscan | bitmap |
|---|---:|---:|---:|---:|---:|---:|
| 10k × 1M | 0.4 | 108 | 104 | `BitmapAnd` 338 | 20 (3,774) | 295 |
| 10k × 10M | 0.4 | 270 | Index Scan 12 | Index Scan 13 | 12 | 17 (one bitmap) |
| 100k × 1M | 0.5 | 54 | 57 (447) | `BitmapAnd` 197 | 1,102 (12,768) | 216 |
| 1M × 1M | 0.5 | 119 (903) | 919 | Index Scan 81,068 | 79,056 | 486 |
| 1M × 10M | 0.3 | 1,100 (5,947) | 5,930 | Index Scan 73,150 | 73,356 | 1,608 |

Buffers: node 3,948 / 39,404 / 4,281 / 7,721 / 41,846; stock's Index Scan in the last
two rows 725,557, all read from disk (`Rows Removed by Filter: 987960`); `BitmapAnd`
the same pages as the node. The planner expects 10,000 matches for 1M × 1M (1M × 1M /
100M) against 100, and picks the Index Scan; `auto` and `node` are the same plan, the
difference is whether the index pages were still cached after the stock run. For
10k × 10M both planners pick the plain Index Scan and are right: the node forced reads
4.7 million entries of product 4 with 5,279 skips.

### 5,000 matches spread evenly, and 5 million

Customer 4 with 1,003,520 rows and product 10 with 202,956, exactly 5,000 rows with
both (every 20,000th `id`; the pair's natural rows moved to product 11, independence
would give 2,000); customer 5 with 20,006,400 rows and product 20 with 24,992,503,
4,999,454 rows with both, as independence gives. Exact index `(customer_id,
product_id, id)`.

| Pair | exact | node | auto | stock | indexscan | bitmap |
|---|---:|---:|---:|---:|---:|---:|
| 1M × 200k, 5,000 match | 1.1 | 2.3 (16) | 2.5 (the node) | `BitmapAnd` 384 | 6.7 (37) | 373 |
| 20M × 25M, 5M match | 0.3 (on the primary key) | 0.6 | 0.5 (Index Scan on the primary key) | 0.7 (the same) | 2.6 | 12,045 (one bitmap, 1.5M pages) |

For the first pair stock expects 2,022 matches and costs the Index Scan on `(product_id,
id)` filtering the customer above `BitmapAnd` with a sort; the scan reads 3,944 entries
and 3,720 pages (13.9 ms in its text plan), the node 19,792 + 3,945 entries and 198
pages. For the second pair every plan but the bitmap stops within the first few
thousand rows: matches that common make the index choice irrelevant.

### 500 matches in the middle of the table

Customer 4 with 999,061 rows, product 10 with 198,462, spread evenly; exactly 500 rows
have both, one per 1,000 `id`s between 49,751,000 and 50,250,000, so the query walks
the newer half of both before the first match. The planner expects 1,746 matches.

| Mode | ms | Buffers | Read |
|---|---:|---:|---:|
| exact | 0.6 | 108 | 5 |
| node | 65 | 2,396 | 1 |
| auto (the node) | 66 (152) | 2,396 | 751 |
| stock: `BitmapAnd` | 353 | 5,101 | 2,701 |
| indexscan, on `(product_id, id)` | 1,521 (5,918) | 92,755 | 92,270 |
| bitmap | 371 | 5,101 | 2,701 |

The node reads 497,479 entries of the customer's index and 98,734 of the product's,
fetches 100 rows; `BitmapAnd` reads both indexes whole (1.2 million entries) and sorts
500 rows.

### The limit of the merge, not measured to the end

Both filters on half the table each (50M rows per index, rows alternating so that
nothing can be skipped) and the only matches at the oldest 1,000 `id`s. One run each
before the set was stopped: node 59.0 s (383,149 buffers), bitmap on one index with a
heap filter 14.8 s (1,620,154 buffers), Index Scan 167.5 s (1,701,786 buffers). The
node iterates 100 million entries at about 0.6 µs each: where neither stream is
sparse it reads everything, like `BitmapAnd`, and is slower per entry. Not a case
anyone writes an index for; it bounds the node's per-entry cost.

## Leaf page prefetch (against `a598e73`)

20M rows in `id` order, customer 5 with 5 % of the rows and one live row per 40,000
`id`s, 5 % of all rows live; indexes `(customer_id, id)` and `(id) WHERE deleted_at IS
NULL`; `customer_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100`, the node
forced: 197,987 outer and 188,536 inner entries, 762 and 519 index pages. One laptop,
`shared_buffers` 2GB. Cold means a server restart and the OS page cache of the table
and index files dropped (`dd iflag=nocache`) before every run; `leapfrog.prefetch` on
and off in ABBA order, `EXPLAIN (ANALYZE, TIMING OFF)`, ms:

| Round | Prefetch on | Prefetch off |
|---:|---:|---:|
| 1 | 199 | 397 |
| 2 | 186 | 390 |
| 3 | 177 | 334 |
| 4 | 108 | 224 |
| 5 | 106 | 208 |

Warm, on or off: 21–27 ms. The rounds get faster as the kernel keeps more of the
files despite the drop; the ratio holds at about 2×. The prefetch asks for the leaf
page after the one just reached (`PrefetchBuffer`, the sibling link of the leaf), so
one page is in flight per stream while its entries are merged.

The per-stream clock of `EXPLAIN ANALYZE` was measured on the same query: clocking
every entry doubled the time under `TIMING` (92 ms against 48); clocking only the
descents and the reads that step to another leaf page costs nothing measurable (49.8
against 48.0 ms) and reports 12.5 and 11.2 ms for the two streams, the rest being
the merge itself.

## Not done

- 10M and 100M rows for `run.sh` (`BENCH_SIZES="10000000" bash tests/performance/run.sh`).
- 50M and 100M rows for `write_bench.sh`: they need more disk than was free here.
- The needle, middle and spread data sets of 100M rows as scripts in
  `tests/performance/` (the list query is `list_bench.sh`). The `bitmap_bench.sh` rerun
  with the `indexscan` mode was stopped after 10M and 20M (no change against the run
  above; the forced Index Scan equals stock's choice where that is an Index Scan).
- Why the planner takes two streams and 20,012 heap fetches for the three-filter
  query on the random-order table, where the ordered one got three streams.
- Write cost of the exact indexes of `bitmap_bench.sh`; only the S, M and G sets of
  `write_bench.sh` were measured.
- OS-cold runs: everything above is with data in the OS page cache.
- Real-world data: synthetic data only.
