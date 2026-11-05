# Contributing

## Environment

You need PostgreSQL 18 with the server headers. Docker is the easiest way:

```bash
bash tests/run-in-docker.sh                    # all tests, in a Compose project of their own
make docker-build PG_MAJOR=18                  # the Compose images only
```

The test image (`Dockerfile`, target `test`) has the build tools but no
sources: Compose mounts the repository at `/src/leapfrog`, and the entrypoint
(`tests/scripts/run-tests.sh --build`) runs `make clean`, builds with
`WERROR=1` and installs before the suites. It runs as a user created with the
build arguments `UID`/`GID`, which `run-in-docker.sh` and `make docker-build`
set to yours (`LEAPFROG_UID`/`LEAPFROG_GID` for a plain `docker compose`), so
what it writes into the tree belongs to you. `PG_MAJOR` picks the PostgreSQL
major version, `LEAPFROG_TAG` the image tag (default `PG_MAJOR`).

The test servers take their settings from one file,
`tests/scripts/temp.conf`: `make check` passes it as `--temp-config`, the
runtime image (the Compose server) appends it to `postgresql.conf.sample`, and
`tests/scripts/start-cluster.sh` appends it to the cluster it creates.
`start-cluster.sh` runs `initdb` into `PGDATA`, adds `shared_buffers`
(`LEAPFROG_SHARED_BUFFERS`, 128MB) and the socket or address from
`PGHOST`/`PGPORT`, starts the server, passing its arguments to it, and runs
the smoke check `tests/scripts/smoke.sql`; the cassert image, CI and the test
image started without `PGHOST` use it:

```bash
docker build --target test -t leapfrog-test .
docker run --rm -v "$PWD:/src/leapfrog" leapfrog-test   # a server of its own
```

The assert-enabled image, `docker/cassert.Dockerfile`, builds PostgreSQL from
git in a stage `pg` and the extension on top of it; its build arguments:

| Argument | Default | Meaning |
|---|---|---|
| `PG_BRANCH` | `REL_18_STABLE` | PostgreSQL branch or tag |
| `SANITIZE` | empty | a `-fsanitize=` list, e.g. `address,undefined`: PostgreSQL and the extension are built with clang, `-fsanitize=$SANITIZE -fno-omit-frame-pointer -fno-sanitize-recover=all` (`--enable-cassert` stays) |
| `UID`, `GID` | `1000` | ids of the user running the server and the tests |

```bash
docker build --build-arg SANITIZE=address,undefined \
    -f docker/cassert.Dockerfile -t leapfrog-san .
docker run --rm leapfrog-san
```

`tests/scripts/run-cassert.sh` runs the server with `-c max_stack_depth=8MB`
and the sanitizers with `ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:log_path=/tmp/asan`
and `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:log_path=/tmp/ubsan`;
after the suites it prints every `/tmp/asan.*` and `/tmp/ubsan.*` report and
fails if there is one, as it fails on a `TRAP:` or a crashed backend in the
server log. Leak detection is off. Under AddressSanitizer the peak RSS check
of `leapfrog_memory` (growth below 32MB) fails: the shadow memory and the
quarantine of freed blocks count in the backend's RSS.

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
extension go into `src/typedefs.list`: after a build (`make`), the script
also runs PostgreSQL's `src/tools/find_typedef` on `src/*.o` (it reads the
debugging symbols with `objdump`; `pg_config`'s `CFLAGS` carry `-g`) and
fails when a typedef defined in `src/` that the objects use is missing from
the list, the way pgindent would misformat it. An entry that `src/` no
longer defines is reported as a warning. Without objects or `objdump` the
check is skipped with a notice.

### Lint

`make lint` (`tests/scripts/lint.sh`) runs the checks that neither the
compiler nor `pgindent` make, after those of Citus (`ci/`) and TimescaleDB
(its code style workflow). Each failing check prints its findings and one
line with the reason, and the script goes on with the next one:

- banned C functions in `src/`: `strcpy`, `strcat`, `sprintf`, `vsprintf`,
  `strncpy`, `strncat`, `gets`, `alloca` (use `strlcpy`, `snprintf`,
  `psprintf`, a `StringInfo`); a line that must keep one carries an
  `IGNORE-BANNED` comment with the reason;
- no `TODO`, `FIXME` or `XXX` notes in `src/` and `tests/`: planned work goes
  into `docs/roadmap.md`;
- no trailing whitespace and a final newline in every tracked text file, as
  `.editorconfig` says; expected test output (`tests/**/expected/*.out`) is
  exempt;
- `#include` order in `src/*.c`: `"postgres.h"`, then `<system>` headers,
  then PostgreSQL headers, then the extension's own (`"leapfrog.h"`), each
  group sorted;
- the `DefineCustom*Variable` calls in alphabetical order of the GUC names,
  as in the Settings table of the README;
- `CHANGELOG.md` lines of at most 100 characters;
- every `tests/scripts/*.sh` is run from the Makefile, a workflow, a
  Dockerfile, a compose file or another script.

`make lint-fix` (`lint.sh --fix`) first removes trailing whitespace, adds the
final newline and wraps long `CHANGELOG.md` lines; the other findings are
fixed by hand.

Then the external tools, as in TimescaleDB's workflows:

- `shellcheck -S warning -x` on every `*.sh`: errors and warnings, not
  style. A `# shellcheck disable=SCxxxx` goes on the line before the one it
  covers, with the reason in a comment next to it;
- `actionlint` on `.github/workflows/*.yml`, with the shell of the `run:`
  blocks checked at the same severity;
- `yamllint` on every `*.yml` and `*.yaml` (`.yamllint`: no `---` required,
  lines over 120 characters are reported as warnings, `on:` is a key);
- `codespell` on `src/`, `tests/`, `docs/` and the Markdown files
  (`.codespellrc`; expected output is skipped). A PostgreSQL or code term it
  takes for a misspelling goes into `ignore-words-list` there;
- `clang-tidy` on `src/*.c` against the headers of the server `pg_config`
  names (`PG_CONFIG`, `CLANG_TIDY` pick others), with `.clang-tidy`:
  `bugprone-*` and the static analyzer, every warning an error. The checks
  left out only flag PostgreSQL idioms; `.clang-tidy` names each with the
  reason. A false positive gets a `NOLINTNEXTLINE(<check>)` comment with a
  comment saying why above it, as in `lf_instr_stop`.

A tool that is not installed is skipped with a notice; `LINT_STRICT=1 make
lint` fails instead, as CI should. On Debian or Ubuntu:
`apt-get install shellcheck yamllint codespell clang-tidy`; `actionlint` is a single
binary from its [releases](https://github.com/rhysd/actionlint/releases).

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
  (after `make install`, against a server on this machine, as a superuser).
  It takes `leapfrog--X.sql` of every earlier release from its tag `vX`
  (`git show`; a shallow clone needs `git fetch --tags`), creates it with
  `CREATE EXTENSION leapfrog VERSION 'X'` in a scratch database, runs
  `ALTER EXTENSION leapfrog UPDATE`, and checks that the result is
  `EXTVERSION`, has the same objects as a fresh `CREATE EXTENSION` and passes
  `leapfrog_setup`. The scripts are read from a scratch directory through
  `extension_control_path`, so nothing is installed. By default it updates
  from the newest tag and every older one that still has an update script;
  `UPGRADE_FROM="0.0.3 0.0.4"` picks the versions. A new SQL object goes into
  both `leapfrog--X.sql` and the update script, or this test fails.
- Version numbers — `make check-version` (no server needed): `EXTVERSION`
  equals `default_version` in `leapfrog.control`; `leapfrog--EXTVERSION.sql`
  and the update script from the newest release tag below it exist and are in
  `DATA`, as is every `leapfrog--*.sql`; `leapfrog_setup.out` shows
  `EXTVERSION`; `CHANGELOG.md` has `## [Unreleased]`, entries there or a
  `## [EXTVERSION]` section once `EXTVERSION` is newer than the newest tag,
  and a link for every released section. Without tags (a shallow clone) the
  tag checks are skipped with a notice. `make check-version RELEASE=1` checks
  a release before its tag is pushed: `Unreleased` is empty,
  `## [EXTVERSION] — YYYY-MM-DD` exists, and `vEXTVERSION` is an annotated tag
  on `HEAD` with the message `leapfrog EXTVERSION`.
- Concurrent scenarios — `tests/isolation/specs/<name>.spec` +
  `tests/isolation/expected/<name>.out`, and the name goes into `ISOLATION`.
  Every permutation must check the **result**, not just the absence of a
  crash; for EvalPlanQual scenarios add a permutation with the stock plan
  under the same interleaving.
- Test lists and expected files — `make check-tests` (no server needed): every `.sql` is in `REGRESS` and every `.spec` in `ISOLATION`, every
  listed name has its file and `<name>.out`, every expected file belongs to a
  test, and every alternative output is explained (below) and differs from
  `<name>.out`.

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
both servers, and say in the header comment of the test (the comment and blank
lines at the top of the `.sql` or `.spec`), on one line, why it exists and when
it can be removed, after the rule of Citus:

```
-- alternative output <name>_N.out: <why>; remove when <condition>
```

with `#` in place of `--` in a `.spec`. `make check-tests` fails without that
line, for a line naming a file that does not exist, and for an alternative
identical to `<name>.out`. In a `.sql` the line is echoed into every expected
file of the test.

### One test, repeated

```bash
make test-one TEST=leapfrog_nulls                    # once
make test-one TEST=leapfrog_nulls REPEATS=50         # 50 times, stop at a failure
make test-one TEST=leapfrog_delete KIND=isolation    # an isolation spec
make installcheck-rerun                              # what the last installcheck failed
```

`tests/scripts/run-one.sh <name> [-r N] [--isolation]` (what `test-one` runs) uses
the server of `PGHOST`/`PGPORT`/`PGUSER`, as `make installcheck` does, and a scratch
database per run, `lf_one_<name>_<pid>`, created as pg_regress creates its own and
dropped after the run (only when it carries the script's comment). A regression test
runs after `leapfrog_setup` in that database, which creates `lf_check` and the other
helpers; `leapfrog_setup`'s own output is checked too. On a failure it prints the diff
and how many runs passed, and keeps the output directory.
`make installcheck-rerun` takes the `not ok` names from `tests/regress/regression.out`
and `tests/isolation/regression.out` and runs each with `run-one.sh`.

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
| `src/compat.h` | every PostgreSQL version conditional: shims for the differences between major versions; the `.c` files test no `PG_VERSION_NUM` |
| `src/leapfrog.c` | `_PG_init`, settings, SQL-callable functions |
| `src/planner.c` | planner hook: index candidates and pairs, the path, the plan and its `Filter` |
| `src/costsize.c` | cost model, including the range probe |
| `src/indexstream.c` | one index as a sorted stream: scan keys, reading entries |
| `src/executor.c` | the merge, TID groups, skip-ahead, EvalPlanQual recheck, `EXPLAIN` |

Functions shared between files are prefixed `lf_` and declared in
`leapfrog.h`; everything else is `static`. The library exports only
`_PG_init` and the SQL-callable functions (PGXS builds with hidden
visibility).

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
