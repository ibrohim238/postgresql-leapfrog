# postgresql-leapfrog — Index Merge Intersect custom scan for PostgreSQL 18
#
# Build with PGXS:
#   make            build the shared library
#   make install    install library, control file and SQL script
#   make installcheck   run regression and isolation tests against a
#                       running server (PGHOST/PGPORT/PGUSER are honoured)
#   make check      run the same tests against a temporary installation
#                   (requires a source-tree build of PostgreSQL)

MODULE_big = leapfrog
OBJS = \
	$(WIN32RES) \
	src/leapfrog.o

EXTENSION = leapfrog
EXTVERSION = 0.0.1
DATA = leapfrog--$(EXTVERSION).sql
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
	leapfrog_btree_pair

ISOLATION = \
	leapfrog_concurrent_update \
	leapfrog_predicate_flip \
	leapfrog_hot_update \
	leapfrog_delete \
	leapfrog_repeatable_read \
	leapfrog_btree_pair

ISOLATION_OPTS = --load-extension=leapfrog
REGRESS_OPTS = --load-extension=leapfrog

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

.PHONY: test test-regress test-isolation bench bench-smoke docker-test pgindent pgindent-fix

test: installcheck

test-regress:
	$(pg_regress_installcheck) $(REGRESS_OPTS) $(REGRESS)

test-isolation:
	$(pg_isolation_regress_installcheck) $(ISOLATION_OPTS) $(ISOLATION)

bench:
	bash tests/performance/run.sh

bench-smoke:
	bash tests/scripts/bench-smoke.sh

docker-test:
	bash tests/run-in-docker.sh

pgindent:
	bash tests/scripts/pgindent.sh

pgindent-fix:
	bash tests/scripts/pgindent.sh --fix
