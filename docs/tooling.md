# Tooling

Lint, code style, version and upgrade checks, the benchmark smoke test. The
test suites: [testing.md](testing.md).

## make lint

`tests/scripts/lint.sh [--fix]` (`make lint`, `make lint-fix`). Each failing
check prints its findings and one line with the reason; the script goes on
with the next and exits 1 if any failed. Needs bash, grep, sed, sort and
python3. Without `.git` (a container) it checks every file but the build and
test output instead of the tracked ones.

| Check | Fails on |
|---|---|
| `banned` | `strcpy`, `strcat`, `sprintf`, `vsprintf`, `strncpy`, `strncat`, `gets`, `alloca` in `src/`; a line marked `IGNORE-BANNED` with a reason is allowed |
| `notes` | `TODO`, `FIXME`, `XXX` in `src/` and `tests/`: plans go to `docs/roadmap.md` |
| `whitespace` | trailing whitespace, a missing final newline (`.editorconfig`); `tests/**/expected/*.out` exempt |
| `includes` | `#include` order in `src/*.c`: `"postgres.h"`, `<system>`, PostgreSQL, the extension's own; each group sorted by byte value |
| `gucs` | `DefineCustom*Variable` calls not in alphabetical order (as the README's Settings table) |
| `changelog` | `CHANGELOG.md` lines over 100 characters |
| `scripts-run` | a `tests/scripts/*.sh` referenced from no Makefile, workflow, Dockerfile, compose file or other script |
| `shellcheck` | `shellcheck -S warning -x` on every `*.sh`; a `# shellcheck disable=` says why next to it |
| `actionlint` | `.github/workflows/*.yml`, `run:` shell at `-S warning` |
| `yamllint` | every `*.yml`/`*.yaml` with `.yamllint` |
| `codespell` | `src/`, `tests/`, `docs/`, `*.md` with `.codespellrc`; a term it does not know goes to `ignore-words-list` |
| `clang-tidy` | `src/*.c` with `.clang-tidy` (`bugprone-*` and the static analyzer, less the checks that only flag PostgreSQL idioms) against the headers of `PG_CONFIG`; `CLANG_TIDY` picks the binary; a false positive gets `NOLINTNEXTLINE(<check>)` with the reason |

- Checks `.clang-tidy` leaves out, as they flag PostgreSQL idioms:
  `bugprone-easily-swappable-parameters` (adjacent parameters of one type
  are everywhere in the planner API); `bugprone-narrowing-conversions` (int
  counters stored as `AttrNumber`, `Index` read into int, int64 counters into
  double for EXPLAIN); `bugprone-implicit-widening-of-multiplication-result`
  (`ALLOCSET_SMALL_SIZES` and other core macros);
  `bugprone-multi-level-implicit-pointer-conversion` (`palloc()` assigned to
  a pointer to pointers); `bugprone-branch-clone` (conditions with the same
  outcome kept apart for their own reasons, `intersect_scan_qual`);
  `clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling`
  (asks for C11 Annex K functions glibc lacks);
  `clang-analyzer-optin.performance.Padding` (the scan state's field order
  follows meaning). Warnings are errors; only `src/*.h` among headers.
- yamllint: no `---` document start; lines over 120 characters warn without
  failing; `truthy` ignores keys (Actions' `on:`).
- `--fix` first removes trailing whitespace, adds final newlines and wraps
  long `CHANGELOG.md` lines at a space (not in code fences or tables).
- A missing external tool is skipped with a notice; `LINT_STRICT=1` makes it
  a failure, for CI. Debian/Ubuntu: `apt-get install shellcheck yamllint
  codespell clang-tidy`; `actionlint` is a single binary from its releases.

## make pgindent

`tests/scripts/pgindent.sh [--fix]` (`make pgindent`, `make pgindent-fix`).

- Fetches `src/tools/pgindent` and `src/tools/pg_bsd_indent` from
  `REL_18_STABLE` (sparse clone into `PGINDENT_WORKDIR`, default
  `$TMPDIR/leapfrog-pgindent`) and builds `pg_bsd_indent` with `CC` against
  the headers and `libpgcommon`/`libpgport` of `PG_CONFIG`.
- The typedefs list is the core one plus `src/typedefs.list`.
- Without `--fix` it fails with a diff when `src/*.c`, `src/*.h` are not
  pgindent-clean.

Typedefs check, before pgindent: PostgreSQL's `src/tools/find_typedef` reads
the typedef names from the debugging symbols of `src/*.o` with `objdump`
(`pg_config`'s `CFLAGS` carry `-g`; run `make` first). A typedef defined in
`src/` (`} NAME;` or `typedef ... NAME;`) that the objects use and the list
lacks fails the check, since pgindent would misformat the code that uses it.
The objects also name typedefs of PostgreSQL and the system, which the core
list and the definition test leave out. An entry `src/` no longer defines is
a warning; it is looked up in the sources, as `find_typedef` misses a typedef
that declares nothing. Without objects, `objdump` or symbols the check is
skipped with a notice; an object older than its source is reported.

## make check-version

`tests/scripts/check-version.sh [--release]`; `make check-version
[RELEASE=1]`. No server; the tag checks need the history (`git fetch --tags`).
`leapfrog.control` is the source of truth.

- `EXTVERSION` (Makefile) equals `default_version` (`leapfrog.control`).
- `leapfrog--EXTVERSION.sql` exists and is in `DATA`; every `leapfrog--*.sql`
  is in `DATA` and every file of `DATA` exists.
- `EXTVERSION` is not older than the newest `v*` tag; the update script from
  the newest tag below it, `leapfrog--PREV--EXTVERSION.sql`, exists and is in
  `DATA` (empty when the SQL objects did not change). Without tags this is
  skipped with a notice; a repository git cannot read is an error.
- `tests/regress/expected/leapfrog_setup.out` shows `EXTVERSION`.
- `CHANGELOG.md` has `## [Unreleased]`; once `EXTVERSION` is newer than the
  newest tag, Unreleased has entries or `## [EXTVERSION]` exists; every
  released section has its `[X]: ` link; the `[Unreleased]: ` link compares
  `v<newest section>...HEAD`.
- `--release`, after `git tag -a vX -m 'leapfrog X'` and before pushing the
  tag: Unreleased is empty, `## [EXTVERSION] — YYYY-MM-DD` exists, and
  `vEXTVERSION` is an annotated tag on `HEAD` with the message
  `leapfrog EXTVERSION`.

Exit: 0 consistent, 1 a problem, 2 bad arguments.

## make installcheck-upgrade

`tests/scripts/upgrade-check.sh`. A release renames the install script, so
`leapfrog--PREV.sql` exists only at tag `vPREV`.

1. Copies the control file and every `leapfrog--*.sql` of the tree, plus
   `leapfrog--PREV.sql` of each version from its tag (`git show`), into a
   scratch directory the server reads through `extension_control_path`
   (PostgreSQL 18): nothing is written into the installation, but the server
   must run on this machine. The library must be installed and match the tree.
2. A fresh `CREATE EXTENSION leapfrog` in `leapfrog_upgrade_fresh` gives the
   reference: the member objects with their definitions and comments.
3. For each version, in `leapfrog_upgrade_<version>`:
   `CREATE EXTENSION leapfrog VERSION 'X'`, `ALTER EXTENSION leapfrog UPDATE`;
   then `extversion` and `leapfrog_version()` equal `EXTVERSION`, the objects
   equal the reference, and `leapfrog_setup` passes.

| Variable | Meaning |
|---|---|
| `EXTVERSION`, `PG_REGRESS`, `PG_BINDIR` | set by the Makefile |
| `UPGRADE_FROM` | versions to update from; default: the newest tag below `EXTVERSION` and every older one the tree has an update script from |
| `SCRATCH_ADMIN_DB` | see [testing.md](testing.md#scratch-databases) |
| `PGHOST`/`PGPORT`/`PGUSER` | a superuser (`extension_control_path` is a superuser setting) |

A new SQL object goes into both `leapfrog--X.sql` and the update script, or
this test fails.

## make bench-smoke

`tests/scripts/bench-smoke.sh`: tiny runs of `list_bench.sh` and
`uniform_bench.sh`, so CI catches a broken harness. Checks that they:

- refuse a `BENCH_DB` without the benchmark mark and leave its data intact;
- refuse to run while another benchmark holds the lock of the database;
- replace helper objects left in another shape by an older version;
- leave no `lf_bitmap`/`lf_list` table behind, also on failure;
- run every scenario and mode, with the node and the exact index used;
- refuse an output directory that exists and leave it unchanged.

Databases: `leapfrog_bench_smoke` and `leapfrog_bench_smoke_foreign`, marked
and dropped ([testing.md](testing.md#scratch-databases)); one run per server.
Environment: `PGHOST`/`PGPORT`/`PGUSER`.
