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

- **S, specialised (30 indexes)**: per column `(fK, id) WHERE deleted_at IS
  NULL` and `(fK, id) WHERE deleted_at IS NOT NULL`; composite
  `(fI, fJ, id) WHERE deleted_at IS NULL` for 6 pairs.
- **G, general (14 indexes)**: per column `(fK, id)`; `(id) WHERE deleted_at
  IS NULL`; `(id) WHERE deleted_at IS NOT NULL`. Read with stock PostgreSQL
  (G) or with leapfrog (G+L).

### Storage and WAL (deterministic)

| | S | G |
|---|---|---|
| Indexes (excluding PK) | 30 | 14 |
| Index size | 302 MB | 201 MB (−33 %) |
| WAL, insert 100,000 rows | 354 MB | 159 MB (−55 %) |
| WAL, soft-delete 25,000 rows | 82 MB | 91 MB (+11 %) |
| WAL, change a filter column of 25,000 rows | 205 MB | 73 MB (−64 %) |
| WAL, delete 25,000 rows | 18 MB | 18 MB |

Soft delete writes slightly more WAL with G: a non-HOT update inserts into 12
full `(fK, id)` indexes and one partial index, against 12 "deleted" partial
indexes with S.

### Write throughput (rows per second, four runs)

| | S | G |
|---|---|---|
| insert | 7,968 · 8,741 · 10,298 · 8,752 | 14,576 · 21,553 · 17,555 · 33,327 |
| soft delete | 26,234 · 24,965 · 11,331 · 24,885 | 13,437 · 17,474 · 8,600 · 16,795 |
| change a filter column | 4,033 · 9,054 · 4,781 · 9,284 | 23,090 · 19,758 · 10,719 · 7,700 |
| delete | 73,459 · 152,159 · 80,912 · 47,442 | 198,701 · 161,261 · 119,217 · 85,920 |

Inserts were faster with G in every run (1.7–3.8×), deletes too (1.1–2.7×),
filter-column updates in three runs of four. Soft deletes were faster with S
in every run (1.3–2×). The spread between runs is large; the WAL numbers above
are the reliable part.

### Reads, `LIMIT 100`, median of 5 (last run)

| Query | S | G stock | G+L planner | G+L forced |
|---|---|---|---|---|
| `random_page_cost = 4` | | | | |
| one filter, live | 0.05 | 0.06 | 0.12 (Index Scan) | 0.41 |
| one filter, deleted | 0.05 | 1.41 | 1.28 (Index Scan) | 0.77 |
| pair with a composite in S | 0.05 | 1.60 | 1.51 (Bitmap) | 0.50 |
| pair without one | 3.11 | 1.58 | 1.52 (Bitmap) | 0.50 |
| `random_page_cost = 1.1` | | | | |
| one filter, live | 0.07 | 0.06 | 0.09 (Index Scan) | 0.41 |
| one filter, deleted | 0.06 | 1.59 | **0.48 (node)** | 0.77 |
| pair with a composite in S | 0.03 | 1.49 | 1.76 (Bitmap) | 0.50 |
| pair without one | 3.01 | 1.50 | 1.57 (Bitmap) | 0.50 |

Milliseconds. Forced rows are with the default page costs; the forced node's
work does not depend on them.

- S answers every query it has an index for in ~0.05 ms and pays 3 ms for the
  pair it has none for.
- With G, the planner picks the node for the deleted-rows query at
  `random_page_cost = 1.1` (3.3× faster than stock). For the pairs the forced
  node is 3× faster than the stock `BitmapAnd`, but the cost model does not
  pick it.
- For "one filter, live" the node is slower (0.41 forced vs 0.06) and the
  planner correctly does not pick it. The previous cost model did, at 0.9 ms;
  that was fixed.

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

## Not done

- 10M and 100M rows (`BENCH_SIZES="10000000" bash tests/performance/run.sh`).
- OS-cold runs: everything above is with data in the OS page cache.
- Real-world data: synthetic data only.
