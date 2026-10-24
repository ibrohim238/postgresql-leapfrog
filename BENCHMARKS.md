# Benchmark results

Two harnesses, both reproducible from the repository:

- [`tests/performance/write_bench.sh`](tests/performance/write_bench.sh) —
  storage, writes and a read mix for a table with 12 filter columns, comparing
  a specialised index set with a general one;
- [`tests/performance/run.sh`](tests/performance/run.sh) — reads only, one
  filter column plus soft deletes, three index strategies over a matrix of
  distributions, deleted shares, customers and limits.

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

## Not done

- 10M and 100M rows (`BENCH_SIZES="10000000" bash tests/performance/run.sh`).
- OS-cold runs: everything above is with data in the OS page cache.
- Real-world data: synthetic data only.
