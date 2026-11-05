# Benchmarks

The scripts in `tests/performance/`. How to run them and where: README,
"Benchmarks"; results: [BENCHMARKS.md](../BENCHMARKS.md); the benchmark
database and its lock: [testing.md](testing.md#benchmark-database); the smoke
test: [tooling.md](tooling.md#make-bench-smoke).

Every script but `planning_bench.sh` writes into `BENCH_OUT` or
`tests/performance/results/<kind>-<timestamp>/` and refuses an existing
directory. All take `PGHOST`/`PGPORT`/`PGUSER` and `BENCH_DB`.
`make bench` runs `list_bench.sh` with `SIZE` 20000000 by default.

## Modes

`list_bench.sh` and `uniform_bench.sh` run every query in each mode, in ABBA
order, so that no mode always follows the one evicting most pages:

| Mode | Settings |
|---|---|
| `node` | leapfrog on, stock scans disabled |
| `bitmap` | leapfrog off, a bitmap plan |
| `indexscan` | leapfrog off, an Index Scan with a Filter |
| `stock` | leapfrog off, the planner's choice |
| `auto` | leapfrog on, the planner's choice |
| `exact` | leapfrog off, with an index made for the query; runs last, as the index would change the other plans (`EXACT=0` skips it) |

## list_bench.sh

The list query with rare, scattered matches, one scenario at a time, as a test
looks at one case: each has its query, its exact index and its own output
directory, and runs without the exact index of another.

| Scenario | Filter |
|---|---|
| `large_customer` | a customer with 5 % of the rows, one live per 200,000 ids |
| `small_customer` | a customer with 1 % of the rows, one live per 200,000 ids |
| `two_filters` | that customer and a product with 2 % of the rows |

- At 100M rows each customer has 500 live rows and the two filters share
  20,012 rows, 11 live. Below 20M rows the customers have fewer live rows than
  `LIMIT 100` and the query never stops early, another workload; the script
  warns.
- Table: `SIZE` rows in random physical order (`ORDER=id`: in id order), 5 %
  live; indexes `(customer_id, id)`, `(product_id, id)`, `(id) WHERE
  deleted_at IS NULL`; loaded once.
- Environment: `SCENARIOS` (all three), `SIZE` (1000000), `ORDER` (`random` |
  `id`), `REPEATS` (3), `WARMUP` (1), `WORK_MEM` (the server's), `EXACT` (1).
- Output `results/list-<timestamp>/`: `server.txt`, `sizes.csv`, and per
  scenario `runs.csv`, `summary.csv`, `explain-<mode>.txt` (text plans of
  `node`, `stock`, `exact`).

## uniform_bench.sh

Filter values spread evenly over the table: the node against `BitmapAnd` and
an exact index as the table grows.

- Table: `customer_id` (100 values), `product_id` (50), `deleted_at`; indexes
  `(customer_id, id)`, `(product_id, id)`, `(id) WHERE deleted_at IS NOT
  NULL`. Deleted rows `hashed` (10 %, evenly spread) or `batches` (12.5 %, per
  customer in blocks of id, loaded in random order; stock plans misjudge
  this).
- A bitmap over `work_mem` turns lossy: 256MB keeps it exact up to 50M rows.
- Environment: `SIZES` (`100000 1000000 10000000`), `REPEATS` (11), `WARMUP`
  (2), `DELETED` (`hashed batches`), `WORK_MEM` (the server's), `EXACT` (1).
- Output `results/uniform-<timestamp>/`: `runs.csv`, `summary.csv` (median,
  p90), `sizes.csv` (table and indexes), `server.txt`.

## write_bench.sh

What index composition saves on writes, and costs or gains on reads, on a
table with `NFILTERS` filter columns and soft deletes. Filter values: 100 per
column from a deterministic hash, independent of the other columns and of
`deleted_at`.

| Strategy | Indexes |
|---|---|
| `S`, specialised | `(fK, id) WHERE deleted_at IS [NOT] NULL` per column, plus composite indexes for frequent filter combinations |
| `M`, moderate | the composite indexes of `S`, plus `(fK, id)` for `M_SINGLES`, the columns no composite starts with (`f3` left out, its pairs cover it) |
| `G`, general | `(fK, id)` per column, `(id) WHERE deleted_at IS [NOT] NULL` |
| `G+L` | the indexes of `G` with leapfrog; shares `G`'s writes |

- Measured per strategy: index size; rows per second and WAL of insert
  (`BATCH_ROWS`), soft delete, filter update and delete (`BATCH_ROWS/4`
  each), each after a `CHECKPOINT`; a read mix of 1 to 4 filters, first, on
  the freshly loaded table, with the default page costs and with
  `random_page_cost = 1.1`.
- Environment: `NFILTERS` (12), `BASE_ROWS` (500000), `BATCH_ROWS` (100000),
  `REPEATS` (5), `STRATEGIES` (`S G`; also `M`), `M_SINGLES`.
- Output `results/write-<timestamp>/`: `write.csv`, `read.csv`, `size.csv`.

## cost_bench.sh

Estimated cost against measured time, on skewed and correlated data:
`customer_id`, `product_id` (hashed), `region` (follows the heap order),
`deleted_at` (10 % of the oldest 20 % of ids), `archived` (1.6 %, uniform).
Modes: leapfrog on; forced (stock scans disabled: the node wins on
`disabled_nodes` and keeps its real estimate, which `leapfrog.force` would
scale down); off.

| Mark | Means |
|---|---|
| `miss` | the forced node > 15 % faster than the planner's choice, which is not it |
| `wrong` | the planner chose the node, stock > 15 % faster |
| `bias` | (node cost / ms) / (stock cost / ms); above 1 the node is overcosted |
| `est_ratio` | entries expected / read; meaningful without `LIMIT` |

- Environment: `ROWS` (1000000), `REPEATS` (5), `RANDOM_PAGE_COST` (4).
- Output `results/cost-<timestamp>/cost.csv` and a summary, one line per
  query and order.

## planning_bench.sh

Planning time against the number of indexes. For each N in `INDEX_COUNTS` a
table with 50 `bigint` filter columns gets N indexes `(fK, id)` plus `(id)
WHERE deleted_at IS NULL`; queries with 1, 2 and 6 equalities `ORDER BY id
LIMIT 10` are planned `REPEATS` times with the extension on and off. Prints
the median planning time (`EXPLAIN SUMMARY`) and whether the plan under
`leapfrog.force` has the node. The library must be preloaded or loadable by
`LOAD`. Environment: `INDEX_COUNTS` (`10 20 50`), `REPEATS` (200).
