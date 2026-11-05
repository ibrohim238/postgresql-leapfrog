# Sources

Practices of the test and build tooling taken from other PostgreSQL
extensions.

| Project | File | Here |
|---|---|---|
| Citus | `ci/banned.h.sh` | `lint.sh`: banned C functions |
| Citus | `ci/sort_and_group_includes.sh` | `lint.sh`: include order |
| Citus | `ci/check_gucs_are_alphabetically_sorted.sh` | `lint.sh`: GUCs sorted |
| Citus | `ci/disallow_long_changelog_entries.sh` | `lint.sh`: CHANGELOG line length |
| Citus | `ci/check_all_ci_scripts_are_run.sh` | `lint.sh`: every script is run |
| Citus | `ci/check_all_tests_are_run.sh` | `check-tests.sh`: test lists |
| Citus | `src/test/regress/README.md` | the alternative-output header line |
| Citus | `src/test/regress/citus_tests/run_test.py -r` | `run-one.sh` |
| Citus | `ci/check_migration_files.sh` | `check-version.sh`: update scripts |
| Citus | `src/include/pg_version_constants.h` | `src/compat.h`: `PG_VERSION_18`, `PG_VERSION_19` |
| TimescaleDB | `scripts/check_orphaned_test_output_files.sh` | `check-tests.sh`: orphaned expected files |
| TimescaleDB | `TESTS=` of `test/pg_regress.sh` | `make test-one` |
| TimescaleDB | `test/ci_rerun.sh` | `rerun-failed.sh` |
| TimescaleDB | `.github/workflows/release_sanity.yml` | `check-version.sh` |
| TimescaleDB | the `[f]ixme` grep of `.github/workflows/code_style.yaml` | `lint.sh`: notes |
| TimescaleDB | `.github/workflows/code_style.yaml`, `.github/workflows/shellcheck.yaml` | `lint.sh`: shellcheck, actionlint, yamllint, codespell |
| TimescaleDB | `test/postgresql.conf.in` | `temp.conf`: locale- and time-zone-independent settings |
| TimescaleDB | `timescaledb.debug_require_vector_agg` | `leapfrog.require_node` |
| TimescaleDB | the `skip_scan` tests' canary | the canary of `lf_check` |
| TimescaleDB | SkipScan's `check_notnull_skipkey` | `is_notnull_column`: NOT NULL from strict restrictions |
| TimescaleDB | `ChunkAppendPath` | `IntersectPath`, a `CustomPath` subclass |
| PG-Strom | `src/pg_compat.h` | `src/compat.h`: every version conditional in one header |
| pgaudit | `Makefile` (version read from `pgaudit.control`) | `check-version.sh`: the control file is the source of truth |
| pg_auto_failover | `Dockerfile` (build, test and run stages, `PGVERSION` argument), `Makefile.docker` | `Dockerfile` stages, `PG_MAJOR`, `make docker-build` |
| pg_stat_monitor | `dump-typedefs.sh` | `pgindent.sh`: `src/typedefs.list` checked with `find_typedef` |
