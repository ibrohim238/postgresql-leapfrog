# Contributing

## Environment

You need PostgreSQL 18 with the server headers. Docker is the easiest way:

```bash
docker compose up -d --build --wait            # server with the library preloaded
docker compose --profile test run --rm test    # all tests
```

Locally:

```bash
make WERROR=1 && sudo make install
make installcheck
```

`WERROR=1` adds `-Werror` on top of the core warning set
(`-Wall -Wextra -Wmissing-prototypes -Wdeclaration-after-statement
-Wshadow=compatible-local …`). CI builds with it on `gcc` and `clang`; code
must compile without warnings.

## Code style

The code follows the PostgreSQL core conventions:

- 4-column tabs, wrap at column 79, `pgindent`-compatible layout;
- a header comment with a short description above every function;
- `ereport`/`elog` for errors, `Assert` for invariants;
- comments explain **why**, not **what**;
- no `//` comments, no declarations in the middle of a block
  (`-Wdeclaration-after-statement`).

The layout is enforced by `pgindent`, the core formatter, and checked in CI:

```bash
make pgindent        # fail with a diff when src/ is not pgindent-clean
make pgindent-fix    # reformat in place
```

The script fetches `pgindent` and `pg_bsd_indent` from `REL_18_STABLE` and
builds them against the installed server headers. New `typedef`s of the
extension go into `src/typedefs.list`.

## Tests

Every behaviour change comes with a test.

- SQL test — `sql/<name>.sql` + `expected/<name>.out`, and the name goes into
  `REGRESS` in the `Makefile`. Compare results with the stock plan through
  `lf_check(query)` from `leapfrog_setup`: it runs the query with
  `leapfrog.enabled = off` and with `leapfrog.force = on`, compares with
  `EXCEPT ALL` in both directions and reports whether the plan contained the
  `Custom Scan`.
- Plan checks — `lf_plan(query)` (with `force`) or `EXPLAIN (COSTS OFF)`.
  Numeric costs are not stored in expected files: `lf_plan_costs` masks the
  numbers.
- `EXPLAIN ANALYZE` counters — `lf_counters(query)`.
- A fix is not done until a test fails without it: build the code with the
  fix reverted and check that the new test catches it.
- Benchmark harness changes — `make bench-smoke`.
- Concurrent scenarios — `tests/isolation/specs/<name>.spec` +
  `tests/isolation/expected/<name>.out`, and the name goes into `ISOLATION`.
  Every permutation must check the **result**, not just the absence of a
  crash; for EvalPlanQual scenarios add a permutation with the stock plan
  under the same interleaving.

Updating expected output after an intended change:

```bash
make test-regress; cp results/<name>.out expected/
make test-isolation; cp tests/isolation/results/<name>.out tests/isolation/expected/
```

Read the diffs in full: `regression.diffs`, `tests/isolation/regression.diffs`.

## What to check when changing the planner part

- `find_outer_candidate` / `is_inner_index` — conditions for choosing a pair;
- `intersect_scan_qual` — which conditions stay in `Filter`; for the target
  relation of `UPDATE/DELETE/FOR UPDATE` conditions implied by the predicate
  must stay (EvalPlanQual);
- `add_intersect_path` — cost; accompany cost model changes with a benchmark
  run (`tests/performance/run.sh`) and update the "Cost model" section of the
  README;
- `intersect_plan_path` — plan dependencies (`relationOids`) and
  `custom_exprs` (outer `Var`s become nestloop parameters in
  `create_customscan_plan`).

## What to check when changing the executor part

- `intersect_next` — the merge loop, `fetching_match` / `xs_heap_continue`,
  `CHECK_FOR_INTERRUPTS`;
- `collect_group` / `group_contains` — the `work_mem` limit, overflow;
- `intersect_recheck` — EvalPlanQual: equalities and predicate on the new
  version;
- `intersect_rescan` — reset of all state, including the cached parameter
  values;
- `intersect_end` — releasing scans, indexes and the group array.

## Commits and pull requests

- One logical change per commit, with a meaningful title.
- In the PR description: what changed, why, which tests were added, and the
  output of `make installcheck`.
- Changes to the `EXPLAIN` format or to GUCs get an entry in `CHANGELOG.md`.
- Benchmark results are not committed (`tests/performance/results/` is in
  `.gitignore`); add summaries to `BENCHMARKS.md` together with the setup.

## License

By sending changes you agree to publish them under the
[PostgreSQL License](LICENSE).
