# Roadmap

Working plan for the next changes, with the design decisions already taken.
Update this file in the commit that finishes or changes a step; delete a
step once it is released and described in README.md and CHANGELOG.md.

State at 0.0.4: no step is planned; what is left is below. Baseline measurements:
BENCHMARKS.md.

## Later

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
