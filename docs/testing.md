# Testing

The test suites and the scripts that run them. Docker: [docker.md](docker.md);
lint, pgindent, version and upgrade checks: [tooling.md](tooling.md).

## Layout

| Path | Contents |
|---|---|
| `tests/regress/sql/<name>.sql`, `tests/regress/expected/<name>.out` | regression tests, listed in `REGRESS` (Makefile) |
| `tests/isolation/specs/<name>.spec`, `tests/isolation/expected/<name>.out` | isolation specs, listed in `ISOLATION` |
| `tests/scripts/` | test, lint and Docker scripts |
| `tests/performance/` | benchmarks ([benchmarks.md](benchmarks.md)) |

`leapfrog_setup` runs first and creates the helpers (`lf_check`, `lf_plan`,
`lf_counters`, ...) the other regression tests use.

| Target | What |
|---|---|
| `make installcheck`, `make test` | both suites against `PGHOST`/`PGPORT`/`PGUSER`; stops after a failing regression suite |
| `make installcheck REGRESS=` | the isolation suite only |
| `make test-regress`, `make test-isolation` | one suite |
| `make check` | a temporary server with `--temp-config=tests/scripts/temp.conf` (needs a source-tree build) |
| `make test-one TEST=<name> [REPEATS=N] [KIND=isolation]` | one test N times (`run-one.sh`) |
| `make installcheck-rerun [REPEATS=N]` | the tests the last installcheck failed (`rerun-failed.sh`) |
| `make check-tests` | the test lists and expected files (`check-tests.sh`) |

## Alternative outputs

`expected/<name>_N.out` is the same test under another server; `pg_regress`
accepts whichever file matches. Every alternative is explained by one line in
the header comment of its test (the comment and blank lines at the top of the
`.sql` or `.spec`):

```
-- alternative output <name>_N.out: <why>; remove when <condition>
```

with `#` for `--` in a `.spec`. In a `.sql` the line is echoed into every
expected file of the test.

## check-tests.sh

`make check-tests`; reads the Makefile and the tree, needs no server. Fails when:

- a `tests/regress/sql/*.sql` is not in `REGRESS`, or a
  `tests/isolation/specs/*.spec` not in `ISOLATION`;
- a listed name has no `.sql`/`.spec` or no `<name>.out`;
- an expected file `<name>.out` or `<name>_N.out` belongs to no test;
- an alternative is identical to `<name>.out`;
- an alternative has no header line, or a header line names a file that does
  not exist.

## run-one.sh and rerun-failed.sh

```
run-one.sh <name> [-r N] [--isolation]
rerun-failed.sh [-r N]
```

- Each run gets a fresh scratch database `lf_one_<name>_<pid>` (cut at 63
  bytes), created as pg_regress creates one (`TEMPLATE template0`,
  `lc_messages`, `lc_monetary`, `lc_numeric`, `lc_time` = `C`,
  `bytea_output = hex`, `timezone_abbreviations = Default`) plus
  `CREATE EXTENSION leapfrog`, passed with `--use-existing`, and dropped after
  the run.
- A regression test other than `leapfrog_setup` runs after `leapfrog_setup` in
  the same database, which creates the helpers; `leapfrog_setup`'s own output
  is checked too, so no expected file changes.
- Stops at the first failure, prints the log and the diff, the number of runs
  that passed, and keeps the output directory.
- Environment: `PGHOST`/`PGPORT`/`PGUSER` (a superuser); `PG_REGRESS`,
  `PG_ISOLATION_REGRESS`, `PG_BINDIR` (set by the Makefile; default: the PGXS
  of `PG_CONFIG`); `SCRATCH_ADMIN_DB`.
- Exit: 0 all runs passed, 1 a failure, 2 bad arguments.

`rerun-failed.sh` takes the `not ok` names of `tests/regress/regression.out`
and `tests/isolation/regression.out` and runs each with `run-one.sh`. It is for
a local look at a failure: CI never retries, a failing test stays red. Exit 2
without a `regression.out`.

## Scratch databases

`tests/scripts/scratch_db.sh` (sourced, functions only) is used by
`run-one.sh`, `upgrade-check.sh`, `bench-smoke.sh` and
`tests/performance/bench_db.sh`. A scratch database carries a comment, its
mark. It is created with the mark, dropped only when it carries it, and a
database of that name without the mark is never touched: the caller stops, so
a name that happens to be a database with real data loses nothing.

| Function | Does |
|---|---|
| `scratch_db_state <name> <mark>` | prints `t` (exists with the mark), `f` (exists without it), nothing (does not exist) |
| `scratch_db_exists <name>` | 0 when it exists, marked or not |
| `scratch_db_refuse_foreign <name> <mark>` | 4 when it exists without the mark |
| `scratch_db_create <name> <mark> [setting=value ...]` | `CREATE DATABASE` + `SCRATCH_DB_OPTIONS`, the mark, `ALTER DATABASE ... SET` each setting, one psql session; the database must not exist |
| `scratch_db_drop <name> <mark> [--no-force]` | drops it `WITH (FORCE)` when marked; nothing when missing; 4 when foreign |

- Return codes: 0 success; 4 (`SCRATCH_DB_FOREIGN`) the database exists without
  the mark, nothing printed, so the caller says what it refuses; otherwise
  psql's status (1 to 3) after psql printed its error. psql never returns 4.
- Environment: `SCRATCH_ADMIN_DB`, the database the commands run from (default
  `BENCH_ADMIN_DB`, then `postgres`); `SCRATCH_DB_OPTIONS`, text that follows
  `CREATE DATABASE <name>` as it is, e.g. `TEMPLATE template0`.

| Script | Database | Mark |
|---|---|---|
| `run-one.sh` | `lf_one_<name>_<pid>` | `leapfrog run-one scratch database (pid N)` |
| `upgrade-check.sh` | `leapfrog_upgrade_fresh`, `leapfrog_upgrade_<version>` | `leapfrog installcheck-upgrade scratch database` |
| `bench-smoke.sh` | `leapfrog_bench_smoke`, `leapfrog_bench_smoke_foreign` | benchmark mark; a stand-in mark for the foreign one |
| `tests/performance/bench_db.sh` | `BENCH_DB` (default `leapfrog_bench`) | `leapfrog benchmark scratch database` |

### Benchmark database

The benchmarks drop and recreate tables with common names (`orders`), so they
never run in `PGDATABASE`. `bench_db.sh` (sourced; `bench_db_use` before the
first query):

- `bench_db_prepare` creates `BENCH_DB` with the mark when missing and refuses
  it without the mark; the database is kept after a run.
- `bench_db_lock` holds an advisory lock in `BENCH_DB` (key `1818650210, 1`)
  from a background psql that reads a pipe this shell keeps open: when the
  script ends, however it ends, the pipe closes and the lock goes. The session
  is found by an application name with a random token (`$$` repeats across
  containers). A second run in the same database is refused.
- `bench_db_drop` drops a marked `BENCH_DB` without `FORCE`, so it fails while
  a benchmark is connected; an unmarked one is left alone.
- `CREATE DATABASE` runs from `BENCH_ADMIN_DB` (default `postgres`;
  `SCRATCH_ADMIN_DB` takes precedence).

## Test servers

`tests/scripts/temp.conf` holds the settings of every test server:
`shared_preload_libraries = 'leapfrog'`, `max_parallel_workers_per_gather = 0`,
`jit = off`, and for machine-independent output `extra_float_digits = 0`,
`timezone = 'UTC'`, `datestyle = 'ISO, MDY'`, `lc_messages = 'C'`. Used by
`make check` (`--temp-config`), `start-cluster.sh`, and the runtime image,
which appends it to `postgresql.conf.sample` (the Compose server). The tests
also `SET max_parallel_workers_per_gather = 0` themselves, for installcheck
against any server.

`start-cluster.sh [postgres options ...]`: `initdb` into `PGDATA`, append
`temp.conf`, `shared_buffers` and the socket or address, start, wait, and run
the smoke check. The extension must be installed. Used by the cassert image,
the test image without `PGHOST`, and CI. Stop with `pg_ctl -w stop`.

| Variable | Default | Meaning |
|---|---|---|
| `PGDATA` | (required) | data directory to create; missing or empty |
| `PGHOST` | `/tmp` | a directory: the socket goes there, TCP off; a host name: listen on it |
| `PGPORT` | `5432` | port |
| `PGUSER` | `postgres` | bootstrap superuser |
| `PGLOG` | `$PGDATA/server.log` | server log |
| `LEAPFROG_SHARED_BUFFERS` | `128MB` | `shared_buffers` |

`tests/scripts/smoke.sql` runs in its own database `leapfrog_smoke`, dropped at
the end: `CREATE EXTENSION`, the library loaded, the key query planned with
the node under `leapfrog.force` and without it under `leapfrog.enabled = off`.

`run-tests.sh [--build]` runs both suites against the server of
`PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`, waiting up to 60 s for it, and prints
the diffs; it warns when `shared_preload_libraries` lacks `leapfrog` (the
tests `LOAD` it per session). `--build` is for the test image: see
[docker.md](docker.md).

## What the tests cover

Regression:

- `leapfrog_setup`: the helpers; `lf_check` fails when both runs saw the same
  settings (a canary after TimescaleDB's skip_scan tests).
- `leapfrog_basic`: the main pair; owner 19 never and 18 always deleted for
  empty and full intersections, rows out of id order; the fallbacks.
- `leapfrog_btree_pair`: two ordinary indexes; an overflowing group (over 10,922
  TIDs in 64kB) must recheck `product_id`, which the Filter lacks.
- `leapfrog_cost`: only the clauses in the node's Filter are charged; a
  condition implied by another stream counts once in the rows.
- `leapfrog_duplicates`: a non-unique sort column; order within a group is
  undefined, so the multiset and the key order are checked apart.
- `leapfrog_example`: the README example verbatim, so its plans and counters
  cannot drift; timings and buffers are left out.
- `leapfrog_explain`: EXPLAIN in every format and the cost components by
  direction; the in-place tablespace is per database and marked, an unmarked one
  stops the test.
- `leapfrog_first_group`: no row before the inner streams read the first group;
  costs compared, not stored, since they depend on the ANALYZE sample.
- `leapfrog_heap_prefetch`: prefetch only when the Filter drops most rows; a
  queued dead row must not get the outer scan's entry marked dead (that row was
  lost to index scans).
- `leapfrog_index_order`: DESC and NULLS FIRST columns; streams of one node may
  scan in opposite directions.
- `leapfrog_memory`: the predicate fallback must reset the per-tuple context
  (about 200 MB without it), by-reference equality values are freed on
  rescan; VmHWM, so a file of its own.
- `leapfrog_merge_order`: the MySQL index merge rule; the sparsest stream leads,
  a dense one reads only around agreed values.
- `leapfrog_mvcc`: row versions in one session, including a dead NULL-id entry
  from before SET NOT NULL that a backward scan reads first.
- `leapfrog_nulls`: NULL is a merge value; a stream that skipped on values must
  come back for the NULLs after them.
- `leapfrog_nway`: three to five streams, added only while cheaper; under force
  the sets are still compared by their own costs (a scaled cost once beat them
  all).
- `leapfrog_outer_partial`: `intersect_scan_qual` keeps the outer predicate's
  conditions in the Filter, for EvalPlanQual.
- `leapfrog_overflow`: a TID group over work_mem; the group estimate uses the
  table's distinct sort values, not the query's rows.
- `leapfrog_parameters`: Params, nestloop parameters, InitPlans, rescans; ORDER
  BY the nullable side of an outer join (`varnullingrels`) is not the node's
  order.
- `leapfrog_partition`: the node per partition; in a partitionwise join the
  equality values must refer to the partition (the parent's Var crashed the
  executor).
- `leapfrog_planner`: planning work counted by `leapfrog.trace_planner`, as time
  cannot be checked; estimates from range overlap and extended statistics.
- `leapfrog_require`: `leapfrog.require_node`, so a query meant for the node
  cannot pass through a stock plan unnoticed.
- `leapfrog_security`: a scan key also runs on rows RLS hides, so only leakproof
  clauses become stream conditions.
- `leapfrog_skip`: skip-ahead keeps entries equal to the target; the adaptive
  threshold rises after short skips.
- `leapfrog_sort_icu`: an ICU collation whose order differs from "C".
- `leapfrog_sort_types`: every B-tree sort type; a by-reference skip bound must
  outlive its stream.
- `leapfrog_types`: equality columns of any type; by-reference values outlive
  per-tuple memory; a domain sort column through `RelabelType`.

Isolation (each EvalPlanQual permutation also runs with the stock plan):

- `leapfrog_btree_pair`: the inner equality, absent from the Filter, is
  rechecked on the new version.
- `leapfrog_concurrent_update`: the recheck covers conditions, not order: a row
  whose id changed keeps its old position in every plan.
- `leapfrog_delete`: dead entries until VACUUM; nothing returned twice or lost.
- `leapfrog_hot_update`: HOT chains followed to the visible version.
- `leapfrog_insert_vacuum`: VACUUM under an open cursor; a buffer-pin wait on
  the scan's leaf page is not visible to isolationtester, so not tested.
- `leapfrog_nulls`, `leapfrog_nway`, `leapfrog_sort_types`, `leapfrog_types`:
  EvalPlanQual for those shapes.
- `leapfrog_outer_partial`: the outer predicate's condition is rechecked from
  the Filter.
- `leapfrog_overflow_epq`: EvalPlanQual through the overflow fallback.
- `leapfrog_partition`: under a Merge Append; a row moved to another partition
  fails the same way in both plans.
- `leapfrog_predicate_flip`: the partial predicate's column flips under a
  snapshot.
- `leapfrog_repeatable_read`: stable reads; FOR UPDATE on a row changed after
  the snapshot fails to serialize.
