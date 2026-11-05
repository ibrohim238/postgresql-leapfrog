# Roadmap

Working plan for the next changes, with the design decisions already taken.
Update this file in the commit that finishes or changes a step; delete a
step once it is released and described in README.md and CHANGELOG.md.

State at 0.0.5: no step is planned; what is left is below. Baseline measurements:
BENCHMARKS.md.

## Later

- Cost model: on a table in `id` order the planner keeps an Index Scan on a
  partial index that filters the other column on the heap where the node is
  15–27× faster (611 against 430 for `customer_id = $1 AND deleted_at IS NULL`
  at 100M rows, 500 live rows for the customer; BENCHMARKS.md, "The list query
  with rare, scattered matches"). The Index Scan's heap reads are costed as
  nearly sequential by correlation, the node's are not; test from that data set.
- Cost model: the third stream against the heap prefetch. On the list query's third
  case (customer 1M × product 2M, 11 live) the pair fetches 20,012 heap rows, asked
  for ahead, in 1.25 s from disk and 165 ms warm; the set with the live-rows index
  reads 4.7M more entries for 11 fetches and takes 2.1 s and 320 ms. The two estimates
  lie within a few percent and the ANALYZE sample decides, three streams in two loads
  of four. The heap fetch cost does not know the pages are asked for ahead; cost them
  as a bitmap heap scan's pages, with a test from this data set (BENCHMARKS.md, "The
  index pairs of the third query").
- Planner: pick the next stream by estimated cost, not by size. The pairs of the
  first stream reach only some correlated sets: `(product_id, id)` with the live rows
  stays unpriced where a smaller `(customer_id, id)` is first, and a winning pair gets no
  third stream unless the pass reaches that set.
- Planner: the node is chosen at `LIMIT 1`/`10` although the stock
  `Index Scan` on `(key, id)` is faster (BENCHMARKS.md, "Equality types").
- Expression index columns (`lower(email)`), through
  `match_index_to_operand`-style matching.
- `IS NULL` on an equality column (`SK_SEARCHNULL` scan key).
- `IN (…)`: several equality ranges of one index merged by the sort column
  (bounded multiway merge), no duplicates.
- Range conditions on a leading column: not an ordered stream as such;
  investigate, otherwise keep the stock fallback and document why.
- nbtree versions before 4: the merge relies on heap TID order within equal
  keys; keep the check unless that can be shown, document `REINDEX`.
