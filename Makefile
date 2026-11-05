# postgresql-leapfrog, built with PGXS: make, make install, make installcheck
# (against PGHOST/PGPORT/PGUSER).  The other targets: docs/testing.md,
# docs/tooling.md, docs/docker.md, docs/benchmarks.md.

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

ISOLATION_OPTS += --inputdir=tests/isolation --outputdir=tests/isolation

# make check's temporary server preloads the library
EXTRA_REGRESS_OPTS += --temp-config=$(CURDIR)/tests/scripts/temp.conf

# on top of pg_config's CFLAGS (-Wall -Wmissing-prototypes ...)
PG_CFLAGS += -Wextra -Wno-unused-parameter -Wno-sign-compare \
	-Wpointer-arith -Wformat-security

ifdef WERROR
PG_CFLAGS += -Werror
endif

PG_CONFIG ?= pg_config
# a failing regress suite stops installcheck before isolation: no stale results
REGRESS_PREP = clean-results

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# clang on pg_config's CFLAGS and headers, which are gcc's (PGDG packages)
ifneq (,$(findstring clang,$(CC)))
override CFLAGS += -Wno-unknown-warning-option -Wno-ignored-attributes
endif

# Convenience targets --------------------------------------------------------

.PHONY: clean-results test test-regress test-isolation test-one installcheck-rerun installcheck-upgrade bench bench-smoke docker-test pgindent pgindent-fix check-tests check-version lint lint-fix docker-build

clean-results:
	rm -f tests/regress/regression.out tests/regress/regression.diffs \
		tests/isolation/regression.out tests/isolation/regression.diffs

test: installcheck

test-regress:
	$(pg_regress_installcheck) $(REGRESS_OPTS) $(REGRESS)

test-isolation:
	$(pg_isolation_regress_installcheck) $(ISOLATION_OPTS) $(ISOLATION)

RUN_ONE_ENV = PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' \
	PG_ISOLATION_REGRESS='$(top_builddir)/src/test/isolation/pg_isolation_regress' \
	PG_BINDIR='$(bindir)'

test-one:
	@test -n '$(TEST)' || { echo 'usage: make test-one TEST=name [REPEATS=N] [KIND=isolation]' >&2; exit 2; }
	$(RUN_ONE_ENV) bash tests/scripts/run-one.sh '$(TEST)' -r '$(or $(REPEATS),1)' \
		$(if $(filter isolation,$(KIND)),--isolation)

installcheck-rerun:
	$(RUN_ONE_ENV) bash tests/scripts/rerun-failed.sh -r '$(or $(REPEATS),1)'
check-tests:
	bash tests/scripts/check-tests.sh

check-version:
	bash tests/scripts/check-version.sh $(if $(RELEASE),--release)

installcheck-upgrade:
	EXTVERSION='$(EXTVERSION)' UPGRADE_FROM='$(UPGRADE_FROM)' \
		PG_REGRESS='$(top_builddir)/src/test/regress/pg_regress' \
		PG_BINDIR='$(bindir)' \
		bash tests/scripts/upgrade-check.sh

bench:
	SIZE=$${SIZE:-20000000} bash tests/performance/list_bench.sh

bench-smoke:
	bash tests/scripts/bench-smoke.sh

# the test image writes into the mounted tree as the caller
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

lint:
	bash tests/scripts/lint.sh

lint-fix:
	bash tests/scripts/lint.sh --fix
