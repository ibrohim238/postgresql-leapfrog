# Roadmap

Working plan for the next changes, with the design decisions already taken.
Update this file in the commit that finishes or changes a step; delete a
step once it is released and described in README.md and CHANGELOG.md.

State at 0.0.3 (`a6c91f9`): equality columns of any B-tree type, equality
values that are expressions of parameters and outer columns, sort columns
`smallint`/`integer`/`bigint` and domains over them, `NOT NULL` and `ASC`
only. Baseline measurements: BENCHMARKS.md, "Equality types".

Order: 5, then 6, then 7 — each depends on the previous one. One step per
change set: code in planner, cost model and executor, tests (regression and
isolation, each verified by reverting the change), the cassert image,
`types_bench.sh`-style measurements against the previous build (ABBA), README
and CHANGELOG.

## Step 5. Sort column of any B-tree type

Goal: `ORDER BY created_at` (`timestamptz`), `date`, `numeric`, `uuid`,
`text`, `varchar` … as the sort column, not only integers.

Design:

- **Comparison.** Replace the `int64` values of the merge with `Datum`s and
  one `SortSupportData` per node, prepared from the pathkey's ordering
  operator: `get_opfamily_member(pk_opfamily, type, type, pk_strategy)` and
  `PrepareSortSupportFromOrderingOp`, `ssup_collation` = the pathkey's
  collation, `ssup_nulls_first` = `pk_nulls_first`. "a is ahead of b in scan
  direction" becomes `ApplySortComparator(...) > 0`. No per-type `switch`.
- **Validation in the planner.** Every stream's index column at `sortpos`
  must have `sortopfamily == pk_opfamily`, the same `opcintype`, and an index
  collation equal to the pathkey's (`ec_collation`). Replace
  `is_integer_column`/`INTEGER_BTREE_FAM_OID` checks accordingly.
- **Plan data.** Store the sort type, opfamily, collation, strategy and
  nulls-first flag in `custom_private` (extend the layout in `leapfrog.h`).
- **Lifetime of by-reference values.** A stream's current value points into
  its scan's `xs_itup` and stays valid until that stream advances. But
  - `group_value` is taken from one stream while the others advance in
    `collect_group`: copy it (`datumCopy`) into a per-group memory context
    reset when the group ends;
  - the skip-ahead bound is the `sk_argument` of a scan key that nbtree
    evaluates on every following tuple: copy it into a per-stream context
    reset on that stream's next rescan.
  For by-value types `datumCopy` does not allocate.
- **Skip-ahead key.** `>=` for an ascending pathkey, `<=` for a descending
  one, from the opfamily with `(type, type)`; nbtree applies it to `DESC`
  index columns itself.
- **Cost model.** `probe_range` keeps `Datum` lo/hi (copied into planner
  memory) instead of `int64`; overlap via the comparator; the range share
  through `clauselist_selectivity` on `col >= lo AND col <= hi` with the
  type's own operators and `Const`s of the type (`sortcol_range_selectivity`).
- **Integer fast path.** Keep `int64` only if the measurement shows the
  generic comparator costs noticeably on `bigint` (compare against 0.0.3 with
  `types_bench.sh`-style runs on a `bigint` and a `timestamptz` sort column).
- **Tests.** Sort columns `timestamptz`, `date`, `numeric`, `text` (with a
  non-C collation and with `COLLATE "C"`), `uuid`, `varchar`; duplicates of
  the sort value across streams; skip-ahead with long `text` values; LIMIT;
  LATERAL and generic plans; overflow; EPQ; an index in another collation or
  opfamily than the pathkey must not be used.

## Step 6. Nullable sort column

Goal: drop the `NOT NULL` requirement (`is_notnull_column`,
`RelOptInfo.notnullattnums`) with correct `NULLS FIRST`/`NULLS LAST`.

Design:

- NULL is a value of the merge in B-tree order (not SQL equality): the
  comparator from step 5 already orders it by `ssup_nulls_first`; a NULL
  group is intersected by TID like any other.
- `lf_read_index_entry` stops skipping NULL entries (today it skips dead
  NULL entries left before `SET NOT NULL`).
- Skip-ahead across the NULL boundary: a bounded key (`col >= v`) excludes
  NULLs. With NULLs last in scan order, when a bounded stream runs out,
  rescan it once with `SK_ISNULL | SK_SEARCHNULL` and continue; skipping to
  a NULL target also uses `SK_SEARCHNULL`. With NULLs first a bounded skip
  never needs them (they are behind every non-NULL value).
- Cost model: add the null fraction to the overlap share when the column is
  nullable.
- Tests: all four `ASC/DESC × NULLS FIRST/LAST` orders, NULL groups in
  several streams, LIMIT inside the NULL group, skip-ahead into and across
  it, MVCC/EPQ (a row whose sort value becomes NULL), HOT.

## Step 7. `DESC` and `NULLS FIRST` index columns

Goal: use indexes like `(customer_id, id DESC)` or `(id DESC NULLS LAST)`.

Design:

- Per stream, choose the scan direction: forward when the index order at
  `sortpos` (`reverse_sort`, `nulls_first`) matches the pathkey, backward
  when both flags are the opposite; otherwise the index is not a candidate.
  Store the direction per stream in `custom_private` instead of the node-wide
  `descending` flag; `skip_ahead` and `check_landing` use the stream's own
  direction (`prevPage`/`nextPage`).
- Streams of one node may scan in different directions; TID groups are
  sorted by `qsort` anyway, so duplicates need no ordering between streams.
- Remove `!index->reverse_sort[pos]` from `is_usable_btree`.
- Tests: the four index orders mixed in one intersection, both query
  directions, duplicates, LIMIT, partial indexes.

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
- Planning time: the histogram share of the sort ranges dominates what
  remains; profile before changing.
