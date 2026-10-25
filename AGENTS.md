# AGENTS.md

Guide for AI coding agents working on this repository. Humans: see
[README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md); this file
only adds what an agent cannot infer from the code and tends to get wrong.

## What this is

A PostgreSQL 18 C extension: a planner hook offers a `CustomPath` that
intersects several B-tree indexes in the order of the query's first sort key
(`ORDER BY id … LIMIT n`), so a table needs fewer composite indexes. Source
layout, code style and the test helpers (`lf_check`, `lf_plan`,
`lf_counters`) are described in CONTRIBUTING.md — read it first.

**The current work plan is [docs/roadmap.md](docs/roadmap.md)**: the next
steps in order, with the design decisions already taken. Read it before
starting, follow its order, and update it in the commit that finishes or
changes a step.

## Build and test

There is no PostgreSQL on a typical host; use Docker.

```bash
docker compose --profile test run --rm test         # build + all tests
docker build -f docker/cassert.Dockerfile -t leapfrog-cassert . \
  && docker run --rm leapfrog-cassert               # assert-enabled server
```

Inside a container with the server headers (repository mounted at `/work`):

```bash
make clean                         # after ANY change to src/leapfrog.h
make with_llvm=no WERROR=1 && make with_llvm=no install
PGUSER=postgres make installcheck  # regression + isolation
make pgindent                      # must be clean; pgindent-fix reformats
```

- PGXS does not track header dependencies: stale objects after a
  `leapfrog.h` change have caused segfaults. Always `make clean` then.
- Install with `make install`, never by copying the `.so` over a loaded one.
- A green ordinary build is not enough: run the cassert image before
  declaring a change done. Node-type casts (`castNode`, `list_nth_node`) are
  only checked there; an OID list is `T_OidList`, not `T_List`.
- New `typedef`s go into `src/typedefs.list`, or pgindent misformats them.
- `make installcheck` stops after a failing regression suite without running
  the isolation suite; run `make installcheck REGRESS=` for isolation only.
- Files written by the container are owned by root; `chown` them back.

## Rules

- **Every fix and feature comes with a test that fails without it.** Check
  it: revert the code change, rebuild, see the test fail, restore. Say in
  the commit message what failed.
- Compare results with the stock plan (`lf_check`) and also check that the
  node was actually used (`custom scan: t`), so a test cannot pass through a
  fallback plan.
- Unsupported cases must fall back to stock plans, never produce a wrong
  result. Do not remove a planner check to get more Leapfrog plans; support
  the case in the planner, cost model and executor, or keep the check.
- Do not tune cost constants to make the node win a benchmark.
- One logical change per commit; commit titles are imperative and specific
  (`Planner: …`, `Cost model: …`). Update CHANGELOG.md (`Unreleased`) and the
  README sections the change affects in the same commit.
- Documentation, comments and examples are in English, with neutral names
  (`orders`, `customer_id`), not names from any private project.

## Pitfalls seen in this code

- Values of by-reference types (`text`, `uuid`) must outlive the per-tuple
  memory they were evaluated in; anything kept across rows or used as a scan
  key argument needs its own memory context (see `values_cxt`).
- Equivalence-class members may be wrapped in `RelabelType` (domains,
  `varchar` → `text`); look through it to the `Var` instead of casting.
- An index column's collation must match the condition's.
- Planner-time index probes (`probe_range`) read real B-tree pages: keep
  them cached per candidate and out of loops over index combinations.

## Benchmarks

Scripts are in `tests/performance/`; each writes into a new directory
(`BENCH_OUT` or `results/<kind>-<timestamp>/`) and refuses an existing one,
and runs in its own database (`BENCH_DB`, default `leapfrog_bench`, see
`bench_db.sh`), never in `PGDATABASE`, one run at a time per database
(an advisory lock). A new script sources `bench_db.sh` and calls
`bench_db_use` before its first query. `tests/run-in-docker.sh`
uses a Compose project unique to the run, not the default `leapfrog`.
`make bench-smoke` checks the harness. When comparing builds, run them in
ABBA order on the same data, report medians and tails, and do not conclude
from a single run; record results in BENCHMARKS.md with the commit compared.

## Releases

Versions are `0.0.x` (still experimental). A release commit bumps
`EXTVERSION` (Makefile) and `default_version` (`leapfrog.control`), renames
the install script to `leapfrog--X.sql`, adds `leapfrog--PREV--X.sql`
(empty when the SQL objects did not change), updates
`expected/leapfrog_setup.out` and turns `Unreleased` into the version in
CHANGELOG.md. Tag `vX` (annotated, message `leapfrog X`) only after CI is
green on that commit, and only when asked.
