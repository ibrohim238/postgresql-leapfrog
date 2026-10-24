# Benchmark results

Reproduced with `tests/performance/run.sh` (see the Benchmarks section of the
README). Raw data of every run goes to `tests/performance/results/<timestamp>/`
(`results.csv`, `plans.jsonl`, `server.txt`, `summary.txt`) and is not
committed.

## Setup

| | |
|---|---|
| Date | 2026-10-24 |
| Server | PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2), `postgres:18` container, leapfrog 0.0.1 |
| Settings | `shared_buffers=128MB`, `work_mem=4MB`, `random_page_cost=4`, `seq_page_cost=1`, `effective_cache_size=4GB`, `jit=off`, `max_parallel_workers_per_gather=0` |
| Host | developer laptop, Linux 7.2, NVMe; data fully in the OS page cache after warm-up |
| Data | 1,000,000 rows, `setseed(0.42)`, two distributions, 1/10/50/90 % deleted |
| Query | `SELECT * FROM orders WHERE customer_id = :c AND deleted_at IS [NOT] NULL ORDER BY id DESC [LIMIT n]` |
| Repetitions | 1 warm-up + 5 measurements, median |
| Query mix | 2 distributions × 4 deleted shares × 3 customers × live/deleted × 4 limits = 192 queries per strategy |

Distributions:

- **uniform** — 1000 customers of equal size (≈1000 rows each), deleted rows
  spread evenly over `id`;
- **skewed** — 10 customers hold 50 % of the rows (≈50,000 each), another
  1000 share the rest; deleted rows only among the oldest 40 % of `id`s. This
  is the typical soft-delete shape the extension is written for: recent rows
  are live, the trash is far away at the start of the index.

Strategies:

- **A** `(customer_id, id)`;
- **B** `(customer_id, id)` + `(id) WHERE deleted_at IS NULL` + `(id) WHERE deleted_at IS NOT NULL`, the planner chooses;
- **B\*** the same with `leapfrog.force = on`;
- **C** `(customer_id, id) WHERE deleted_at IS NULL` + `(customer_id, id) WHERE deleted_at IS NOT NULL`.

Index size at 1M rows (excluding the PK): A 30.1 MB, B 51.6 MB, C 30.1 MB.

## What the planner chose

Of the 192 queries of strategy B (without `force`) the planner chose Index
Merge Intersect in **14**, all of them in the **skewed** distribution for the
largest customer: `live` with `LIMIT 100/1000` at every deleted share, and
`deleted` with `LIMIT 100/1000/none` at 50/90 % deleted. Elsewhere it stayed
with stock plans (`Index Scan` on the partial or the outer index, `Bitmap Heap
Scan`).

## Skewed, largest customer (50,172 rows)

Median execution time, ms. `A/B` is how many times B is faster than A.

| deleted % | predicate | LIMIT | A | B | B\* | C | A/B | plan chosen for B |
|---|---|---|---|---|---|---|---|---|
| 1 | deleted (510 rows) | 1 | 143.19 | 0.02 | 0.84 | 0.02 | 8949 | Index Scan, partial index |
| 1 | deleted | 100 | 134.76 | 0.27 | 1.05 | 0.03 | 494 | Index Scan, partial index |
| 1 | deleted | 1000 | 22.65 | 1.80 | 1.80 | 0.30 | 12.6 | Index Scan, partial index |
| 1 | deleted | none | 21.24 | 2.12 | 1.85 | 0.31 | 10.0 | Index Scan, partial index |
| 1 | live | 100 | 0.52 | **0.10** | 0.10 | 0.16 | 5.4 | **Index Merge Intersect** |
| 1 | live | 1000 | 5.08 | **0.78** | 0.73 | 1.73 | 6.5 | **Index Merge Intersect** |
| 1 | live | none | 61.28 | 25.34 | 44.00 | 24.85 | 2.4 | Bitmap Heap Scan |
| 10 | deleted (5042) | 100 | 51.75 | 0.18 | 0.90 | 0.04 | 281 | Index Scan, partial index |
| 10 | deleted | 1000 | 57.40 | 1.98 | 1.84 | 0.18 | 29.0 | Index Scan, partial index |
| 10 | deleted | none | 15.28 | 15.66 | 6.76 | 2.14 | 0.98 | Index Scan, partial index |
| 10 | live | 100 | 0.16 | **0.09** | 0.09 | 0.16 | 1.7 | **Index Merge Intersect** |
| 10 | live | 1000 | 1.82 | **0.73** | 0.73 | 1.74 | 2.5 | **Index Merge Intersect** |
| 50 | deleted (20,150) | 100 | 54.65 | **0.88** | 0.88 | 51.38 | 62 | **Index Merge Intersect** |
| 50 | deleted | 1000 | 55.78 | **1.60** | 1.55 | 53.38 | 35 | **Index Merge Intersect** |
| 50 | deleted | none | 16.42 | **18.54** | 20.05 | 7.18 | 0.89 | **Index Merge Intersect** |
| 50 | live | 1000 | 1.74 | **0.72** | 0.73 | 1.68 | 2.4 | **Index Merge Intersect** |
| 90 | deleted | 100 | 142.35 | **0.86** | 0.89 | 51.04 | 166 | **Index Merge Intersect** |
| 90 | deleted | 1000 | 124.68 | **1.56** | 1.49 | 55.25 | 80 | **Index Merge Intersect** |
| 90 | deleted | none | 27.38 | **19.41** | 19.01 | 6.82 | 1.4 | **Index Merge Intersect** |
| 90 | live | 1000 | 1.98 | **0.74** | 0.79 | 1.76 | 2.7 | **Index Merge Intersect** |

Buffers for the "1 %, deleted, no LIMIT" row: A 13,226, B (Index Scan on the
partial index) 4,557, B\* (the node) **705** with 510 `Heap Fetches`, C 485.

Observations:

- Where the planner picks the node it is 1.7–6.5× faster than A for
  `live … LIMIT` and 35–166× faster for `deleted … LIMIT` with a large trash;
  the dedicated partial indexes of C are either comparable (`live`) or lose
  (at 50/90 % deleted the PostgreSQL planner switches C to a backward PK scan
  with a filter — 51–55 ms).
- For `deleted … LIMIT 1/100` at 1–10 % deleted the planner rightly prefers the
  stock `Index Scan` on the partial index (0.02–0.27 ms) over the node
  (0.84–1.05 ms under `force`): the trash is small and the customer filter
  drops few rows. Under `force` the node reads 30,000 outer index entries to
  reach the first deleted row — `Outer Entries Read: 30026`,
  `Inner Entries Read: 26`, `Heap Fetches: 1`. This is the case the
  skip-ahead item of the roadmap addresses.
- Without `LIMIT`, for `live` the node loses to the bitmap scan (44 vs 25 ms):
  50,000 random heap visits in `id` order against a bitmap walk in physical
  order. The planner sees this and does not pick the node.
- The only case where picking the node was worse than A: "50 % deleted,
  deleted, no LIMIT" — 18.5 ms against 16.4 ms for A (bitmap scan) and 7.2 ms
  for C, a difference within 15 %; both plans read the whole result.

## Uniform, largest customer (≈1,100 rows)

The planner never picks the node here, and rightly so: under `force` the node
reads a large part of the partial index for ≈1000 rows of the customer, and
B\* is 5–70× slower than the stock plans (`live LIMIT 1000`: 30.7 ms against
0.44 for B and 2.42 for A).

## Is the planner's choice good overall?

Comparing B (the planner's choice with B's indexes) with the best of A and
B\* over all 192 queries, B is more than 15 % and more than 0.05 ms slower in
**39** of them. In none of the 39 did the planner choose the node:

- in 25 of them A is faster: with the extra partial indexes present, the stock
  planner picks a `Bitmap Heap Scan` or a partial index scan that is slower
  than its plan with A's single index (for example uniform, 10 % deleted,
  `deleted`: B 3.4–4.0 ms against A 0.4–0.6 ms). This is a property of
  strategy B's index set, not of the node;
- in 14 of them B\* is faster: the node would have won but the cost model did
  not pick it (for example uniform, 1 % deleted, `deleted`: B 1.1 ms against
  B\* 0.3–0.4 ms). These are missed opportunities.

In all 14 queries where the planner did choose the node, the node was the
best of A, B and B\* or within 15 % of it. No case was found where choosing
the node made a query noticeably slower than the best available plan.

## 100k rows

Smoke run (`BENCH_SIZES=100000 BENCH_REPEATS=3`): the same picture at a
smaller scale; for skewed `deleted LIMIT 100` at 10 % deleted the node gives
0.20 ms against 5.88 ms for A (×30). All timings are below 2 ms and the
differences between strategies are mostly within noise.

## Not done

- 10M and 100M rows: not run on this machine (a laptop; data generation and
  `CREATE INDEX` take tens of minutes at 10M). The harness is ready:
  `BENCH_SIZES="10000000" bash tests/performance/run.sh`.
- Cold cache: every measurement is after warm-up with data in memory. With
  disk I/O the node's advantage (few `Heap Fetches` against thousands of random
  reads) should be larger, but this has not been measured.
- Real-world data: not used, synthetic data only.
