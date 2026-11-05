#!/usr/bin/env bash
# Run the regression and isolation suites against the server described by
# PGHOST/PGPORT/PGUSER/PGDATABASE.  Used as the entrypoint of the "test"
# compose service and by the cassert image; works against any reachable
# PostgreSQL 18 that has the extension installed and preloaded.
#
#   bash tests/scripts/run-tests.sh           run the suites
#   bash tests/scripts/run-tests.sh --build   first make clean, build with
#                                             warnings as errors and install
#                                             (the test image, whose sources
#                                             are mounted)
#
# Exits non-zero when any test fails; the diffs are printed.
set -euo pipefail

cd "$(dirname "$0")/../.."

build=0
for arg in "$@"; do
	case "$arg" in
		--build) build=1 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

if [ "$build" -eq 1 ]; then
	if [ ! -f Makefile ] || [ ! -d src ]; then
		echo "run-tests: no sources in $PWD: mount the repository there (-v \"\$PWD:/src/leapfrog\")" >&2
		exit 2
	fi
	echo "== build"
	# The sources are mounted: objects of another build (the host's, another
	# server's) must not be linked into this one.
	make clean >/dev/null
	make with_llvm=no WERROR=1
	make with_llvm=no install
fi

wait_for_server() {
	local tries=60
	until pg_isready -q; do
		tries=$((tries - 1))
		if [ "$tries" -le 0 ]; then
			echo "server at ${PGHOST:-localhost}:${PGPORT:-5432} is not ready" >&2
			exit 1
		fi
		sleep 1
	done
}

wait_for_server

# The planner hook must be installed; LOAD in the tests covers a session,
# but the isolation sessions and the plan cache are simpler to reason about
# when the server preloads the library.
preload=$(psql -tAc "SHOW shared_preload_libraries")
case ",$preload," in
	*,leapfrog,*|*leapfrog*) ;;
	*) echo "warning: shared_preload_libraries does not list leapfrog ($preload); the tests LOAD it per session" >&2 ;;
esac

status=0

echo "== regression tests"
if ! make test-regress; then
	status=1
	[ -f tests/regress/regression.diffs ] && cat tests/regress/regression.diffs
fi

echo "== isolation tests"
if ! make test-isolation; then
	status=1
	[ -f tests/isolation/regression.diffs ] && cat tests/isolation/regression.diffs
fi

exit $status
