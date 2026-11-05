# postgresql-leapfrog — Index Merge Intersect custom scan for PostgreSQL 18
#
# Build with PGXS:
#   make            build the shared library
#   make install    install library, control file and SQL script
#   make installcheck   run regression and isolation tests against a
#                       running server (PGHOST/PGPORT/PGUSER are honoured)
#   make check      run the same tests against a temporary installation
#                   (requires a source-tree build of PostgreSQL)
#   make docker-build PG_MAJOR=18   build the compose images
#   make docker-test PG_MAJOR=18    the suites in Docker (tests/run-in-docker.sh)
#   make installcheck-upgrade   create the previous releases (install
#                   scripts from their git tags) and ALTER EXTENSION ...
#                   UPDATE them on a running server on this machine;
#                   UPGRADE_FROM="0.0.4" picks the versions
#   make test-one TEST=leapfrog_nulls [REPEATS=50] [KIND=isolation]
#                   run one test N times against a running server, stop at
#                   the first failure (tests/scripts/run-one.sh)
#   make installcheck-rerun   rerun the tests the last installcheck failed
#   make check-tests    the test lists, the expected files and the
#                       alternative outputs agree (no server needed)
#   make check-version  the version numbers, scripts and CHANGELOG.md agree;
#                       RELEASE=1 checks a release and its tag
#   make lint           static checks of the tree (CONTRIBUTING.md, "Lint");
#                       lint-fix repairs whitespace and long CHANGELOG lines

MODULE_big = leapfrog
OBJS = \
	$(WIN32RES) \
	src/costsize.o \
	src/executor.o \
	src/indexstream.o \
	src/leapfrog.o \
	src/planner.o

EXTENSION = leapfrog
EXTVERSION = 0.0.5
DATA = leapfrog--$(EXTVERSION).sql \
	leapfrog--0.0.1--0.0.2.sql \
	leapfrog--0.0.2--0.0.3.sql \
	leapfrog--0.0.3--0.0.4.sql \
	leapfrog--0.0.4--0.0.5.sql
PGFILEDESC = "leapfrog - Index Merge Intersect custom scan"
PG_CPPFLAGS = -DLEAPFROG_VERSION='"$(EXTVERSION)"'

REGRESS = \
	leapfrog_setup \
	leapfrog_basic \
	leapfrog_duplicates \
	leapfrog_overflow \
	leapfrog_parameters \
	leapfrog_mvcc \
	leapfrog_memory \
	leapfrog_explain \
	leapfrog_example \
	leapfrog_btree_pair \
	leapfrog_skip \
	leapfrog_outer_partial \
	leapfrog_nway \
	leapfrog_types \
	leapfrog_security \
	leapfrog_cost \
	leapfrog_partition \
	leapfrog_sort_types \
	leapfrog_sort_icu \
	leapfrog_nulls \
	leapfrog_index_order \
	leapfrog_merge_order \
	leapfrog_planner \
	leapfrog_first_group \
	leapfrog_heap_prefetch \
	leapfrog_require

ISOLATION = \
	leapfrog_concurrent_update \
	leapfrog_predicate_flip \
	leapfrog_hot_update \
	leapfrog_delete \
	leapfrog_repeatable_read \
	leapfrog_btree_pair \
	leapfrog_outer_partial \
	leapfrog_insert_vacuum \
	leapfrog_overflow_epq \
	leapfrog_nway \
	leapfrog_types \
	leapfrog_partition \
	leapfrog_sort_types \
	leapfrog_nulls

ISOLATION_OPTS = --load-extension=leapfrog
REGRESS_OPTS = --load-extension=leapfrog --inputdir=tests/regress --outputdir=tests/regress

# Isolation specs live in tests/isolation/specs with their expected output in
# tests/isolation/expected, following the layout of src/test/isolation.
ISOLATION_OPTS += --inputdir=tests/isolation --outputdir=tests/isolation

# The planner hook is installed when the library is loaded.  "make check"
# starts a temporary server; preload the library there.
EXTRA_REGRESS_OPTS += --temp-config=$(CURDIR)/tests/scripts/temp.conf

# Warnings on top of the ones pg_config's CFLAGS already carry (the core
# set: -Wall -Wmissing-prototypes -Wdeclaration-after-statement ...).
PG_CFLAGS += -Wextra -Wno-unused-parameter -Wno-sign-compare \
	-Wpointer-arith -Wformat-security

ifdef WERROR
PG_CFLAGS += -Werror
endif

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# pg_config's CFLAGS and headers were chosen for the compiler PostgreSQL was
# built with (gcc in the PGDG packages); clang must not fail on options and
# attributes it does not know.
ifneq (,$(findstring clang,$(CC)))
override CFLAGS += -Wno-unknown-warning-option -Wno-ignored-attributes
endif

# Convenience targets --------------------------------------------------------

.PHONY: test test-regress test-isolation test-one installcheck-rerun installcheck-upgrade bench bench-smoke docker-test pgindent pgindent-fix check-tests check-version lint lint-fix docker-build

test: installcheck

test-regress:
	$(pg_regress_installcheck) $(REGRESS_OPTS) $(REGRESS)

test-isolation:
	$(pg_isolation_regress_installcheck) $(ISOLATION_OPTS) $(ISOLATION)

# One test, REPEATS times, in a scratch database of its own; KIND=isolation
# for a spec.  See tests/scripts/run-one.sh.
RUN_ONE_ENV = PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' \
	PG_ISOLATION_REGRESS='$(top_builddir)/src/test/isolation/pg_isolation_regress' \
	PG_BINDIR='$(bindir)'

test-one:
	@test -n '$(TEST)' || { echo 'usage: make test-one TEST=name [REPEATS=N] [KIND=isolation]' >&2; exit 2; }
	$(RUN_ONE_ENV) bash tests/scripts/run-one.sh '$(TEST)' -r '$(or $(REPEATS),1)' \
		$(if $(filter isolation,$(KIND)),--isolation)

# The tests "not ok" in the last regression.out files, once each (REPEATS=N
# for more); see tests/scripts/rerun-failed.sh.
installcheck-rerun:
	$(RUN_ONE_ENV) bash tests/scripts/rerun-failed.sh -r '$(or $(REPEATS),1)'
# Every test file is listed and has an expected file, every expected file has
# a test, and every alternative output is explained; see
# tests/scripts/check-tests.sh.
check-tests:
	bash tests/scripts/check-tests.sh

# EXTVERSION, the control file, the install and update scripts, DATA,
# leapfrog_setup's output and CHANGELOG.md agree; RELEASE=1 also checks the
# state of a release and its tag.  See tests/scripts/check-version.sh.
check-version:
	bash tests/scripts/check-version.sh $(if $(RELEASE),--release)

# A release renames the install script, so the earlier ones exist only at
# their tags; see tests/scripts/upgrade-check.sh.
installcheck-upgrade:
	EXTVERSION='$(EXTVERSION)' UPGRADE_FROM='$(UPGRADE_FROM)' \
		PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' \
		PG_BINDIR='$(bindir)' \
		bash tests/scripts/upgrade-check.sh

bench:
	SIZE=$${SIZE:-20000000} bash tests/performance/list_bench.sh

bench-smoke:
	bash tests/scripts/bench-smoke.sh

# Docker (compose.yaml): the images for PostgreSQL PG_MAJOR, the test image
# with a user of the caller's ids, since it writes into the mounted sources.
PG_MAJOR ?= 18
DOCKER_ENV = PG_MAJOR='$(PG_MAJOR)' LEAPFROG_UID="$$(id -u)" LEAPFROG_GID="$$(id -g)"

docker-build:
	$(DOCKER_ENV) docker compose --profile test build

docker-test:
	$(DOCKER_ENV) bash tests/run-in-docker.sh

pgindent:
	bash tests/scripts/pgindent.sh

pgindent-fix:
	bash tests/scripts/pgindent.sh --fix

# Static checks of the tree (tests/scripts/lint.sh, see CONTRIBUTING.md);
# lint-fix first fixes whitespace and long CHANGELOG.md lines.
lint:
	bash tests/scripts/lint.sh

lint-fix:
	bash tests/scripts/lint.sh --fix
