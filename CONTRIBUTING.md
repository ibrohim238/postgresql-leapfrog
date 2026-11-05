# Contributing

## Environment

You need PostgreSQL 18 with the server headers. Docker is the easiest way:

```bash
bash tests/run-in-docker.sh                    # all tests, in a Compose project of their own
make docker-build PG_MAJOR=18                  # the Compose images only
docker run --rm -v "$PWD:/src/leapfrog" leapfrog-test   # test image, a server of its own
docker build -f docker/cassert.Dockerfile -t leapfrog-cassert . && docker run --rm leapfrog-cassert
docker build --build-arg SANITIZE=address,undefined \
    -f docker/cassert.Dockerfile -t leapfrog-san .        # with sanitizers
```

The images, Compose, the mounted sources and the sanitizer build:
[docs/docker.md](docs/docker.md). Under AddressSanitizer the peak RSS check
of `leapfrog_memory` fails.

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

New `typedef`s of the extension go into `src/typedefs.list`; after a build
(`make`), `make pgindent` fails when one is missing. Details:
[docs/tooling.md](docs/tooling.md#make-pgindent).

### Lint

`make lint` (`tests/scripts/lint.sh`) runs the checks that neither the
compiler nor `pgindent` make: banned C functions, `TODO` notes, whitespace,
include order, GUC order, `CHANGELOG.md` line length, scripts nothing runs,
and `shellcheck`, `actionlint`, `yamllint`, `codespell` and `clang-tidy` when
they are installed (`LINT_STRICT=1` fails without them). `make lint-fix`
repairs whitespace and long `CHANGELOG.md` lines. Every check and its rules:
[docs/tooling.md](docs/tooling.md#make-lint).

## Tests

Every behaviour change comes with a test.

- SQL test — `tests/regress/sql/<name>.sql` + `tests/regress/expected/<name>.out`, and the name goes into
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
- SQL objects, update scripts and releases — `make installcheck-upgrade`
  (after `make install`, against a server on this machine, as a superuser;
  `UPGRADE_FROM="0.0.3 0.0.4"` picks the versions). A new SQL object goes
  into both `leapfrog--X.sql` and the update script, or this test fails.
- Version numbers — `make check-version` (no server needed);
  `make check-version RELEASE=1` before a release tag is pushed. Rules:
  [docs/tooling.md](docs/tooling.md).
- Concurrent scenarios — `tests/isolation/specs/<name>.spec` +
  `tests/isolation/expected/<name>.out`, and the name goes into `ISOLATION`.
  Every permutation must check the **result**, not just the absence of a
  crash; for EvalPlanQual scenarios add a permutation with the stock plan
  under the same interleaving.
- Test lists and expected files — `make check-tests` (no server needed).

The scripts, the scratch databases and the test servers:
[docs/testing.md](docs/testing.md).

Updating expected output after an intended change:

```bash
make test-regress; cp tests/regress/results/<name>.out tests/regress/expected/
make test-isolation; cp tests/isolation/results/<name>.out tests/isolation/expected/
```

Read the diffs in full: `tests/regress/regression.diffs`, `tests/isolation/regression.diffs`.

An alternative output `expected/<name>_N.out` (regression or isolation) is the
same test under another server; `pg_regress` accepts whichever file matches.
`leapfrog_basic`, `leapfrog_parameters` and `leapfrog_mvcc` have one for the
`EXPLAIN` output and plans of PostgreSQL 19, `leapfrog_sort_icu` for a database
without ICU, and the isolation test `leapfrog_outer_partial` for PostgreSQL 19,
which makes the other index the outer stream. A change to such a test changes
every file. Add an alternative only when the output cannot be made the same on
both servers, and say in the header comment of the test, on one line, why it
exists and when it can be removed
([format](docs/testing.md#alternative-outputs); `make check-tests` checks it).

### One test, repeated

```bash
make test-one TEST=leapfrog_nulls                    # once
make test-one TEST=leapfrog_nulls REPEATS=50         # 50 times, stop at a failure
make test-one TEST=leapfrog_delete KIND=isolation    # an isolation spec
make installcheck-rerun                              # what the last installcheck failed
```

Against the server of `PGHOST`/`PGPORT`/`PGUSER`, in a scratch database per run;
on a failure it prints the diff and keeps the output
([docs/testing.md](docs/testing.md#run-onesh-and-rerun-failedsh)).

### Flaky tests

A test that fails now and then is a bug, in the test or in the extension; it is fixed,
not retried. CI never reruns a failed test, and `installcheck-rerun` is for a local
look only: a failing test stays red.

1. Reproduce it: `make test-one TEST=<name> REPEATS=50` (more for a rare one). If it
   only fails in the full suite, it depends on what an earlier test left behind.
2. Fix the cause, in this order:
   - `ORDER BY` on every query that returns more than one row, with a unique key;
   - statistics that do not depend on the ANALYZE sample: the whole table in it,
     `SET default_statistics_target = 1000` before `ANALYZE` on a small table, as
     `leapfrog_first_group` does;
   - `COLLATE "C"` on a text `ORDER BY`, as `leapfrog_nulls` does, so that the order
     does not depend on the database's collation;
   - `SET` every GUC the plan depends on (`enable_*`, `work_mem`,
     `random_page_cost`, …) in the test instead of relying on the server's value;
   - no `_N.out` alternative just to accept a second result: `_1.out` is for another
     server (see above), not for nondeterminism.
3. Check the fix with the same `REPEATS` that reproduced the failure.

## Source layout

| File | Contents |
|---|---|
| `src/leapfrog.h` | structures shared between the files, the plan info (`IntersectPlanInfo`), settings, prototypes |
| `src/compat.h` | every PostgreSQL version conditional: shims for the differences between major versions ([docs/compat.md](docs/compat.md)); the `.c` files test no `PG_VERSION_NUM` |
| `src/leapfrog.c` | `_PG_init`, settings, SQL-callable functions |
| `src/planner.c` | planner hook: index candidates and pairs, the path, the plan and its `Filter` |
| `src/costsize.c` | cost model, including the range probe |
| `src/indexstream.c` | one index as a sorted stream: scan keys, reading entries |
| `src/executor.c` | the merge, TID groups, skip-ahead, EvalPlanQual recheck, `EXPLAIN` |

Functions shared between files are prefixed `lf_` and declared in
`leapfrog.h`; everything else is `static`. The library exports only
`_PG_init` and the SQL-callable functions (PGXS builds with hidden
visibility).

Design notes and the reasons behind the code are in
[docs/design.md](docs/design.md); source comments keep only the
non-obvious point.

## What to check when changing the planner part

- `planner.c`: `find_index_candidate`, `is_inner_candidate` — conditions for a
  stream to join a set; `search_intersection` — one pass over the candidates,
  fewest entries first, plus the first stream's pairs under extended statistics,
  keeping the cheapest set (`leapfrog.max_indexes`);
  `build_set_path` — which stream is the outer one; planning time is measured
  with `tests/performance/planning_bench.sh`;
- `planner.c`: `intersect_scan_qual` — which conditions stay in `Filter`; for
  the target relation of `UPDATE/DELETE/FOR UPDATE` conditions implied by the
  predicate must stay (EvalPlanQual);
- `costsize.c`: `lf_cost_intersect_path` — cost; accompany cost model changes
  with `tests/performance/cost_bench.sh` and a benchmark run
  (`tests/performance/list_bench.sh`), and update the "Cost model" section of the
  README;
- `planner.c`: `intersect_plan_path` — plan dependencies (`relationOids`) and
  `custom_exprs` (outer `Var`s become nestloop parameters in
  `create_customscan_plan`);
- `planner.c`: what the plan carries to the executor is `IntersectPlanInfo`
  (`leapfrog.h`), kept as a struct in the path (`IntersectPath`), except the
  expressions of each stream (`keys`, `pred`): they stay in the path's
  `custom_private`, in the layout of the plan's `custom_exprs`, so that
  `intersect_reparameterize` (`ReparameterizeCustomPathByChild`) can turn a
  `Var` of a partitioned table into one of its partition under
  partitionwise join; `intersect_plan_path` puts them into the struct. An
  expression field goes there too, never only into the struct.
  `form_plan_info` writes it into `custom_private` and `custom_exprs`,
  `lf_deform_plan_info` reads it back in `intersect_create_scan_state`; no
  other code knows the list layout. A new field goes into the struct and into
  both functions; an assert-enabled build checks that `custom_private`
  survives `nodeToString`, `stringToNode` and `copyObject`.

## What to check when changing the executor part

- `executor.c`: `find_common_value` — the streams catching up with a candidate,
  sparsest first; `intersect_next` — groups of every inner stream and the heap,
  `fetching_match` / `xs_heap_continue`, `CHECK_FOR_INTERRUPTS`, skip-ahead
  (`skip_ahead`, `check_landing`);
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
