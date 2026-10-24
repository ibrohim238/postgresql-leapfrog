#!/usr/bin/env bash
# Run the regression and isolation suites against the server described by
# PGHOST/PGPORT/PGUSER/PGDATABASE.  Used as the entrypoint of the "test"
# compose service and by CI; works against any reachable PostgreSQL 18 that
# has the extension installed and preloaded.
#
# Exits non-zero when any test fails; the diffs are printed.
set -euo pipefail

cd "$(dirname "$0")/../.."

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
	[ -f regression.diffs ] && cat regression.diffs
fi

echo "== isolation tests"
if ! make test-isolation; then
	status=1
	[ -f tests/isolation/regression.diffs ] && cat tests/isolation/regression.diffs
fi

exit $status
