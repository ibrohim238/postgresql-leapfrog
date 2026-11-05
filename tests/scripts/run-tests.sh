#!/usr/bin/env bash
# Run the regression and isolation suites against PGHOST/PGPORT/PGUSER.
# Usage: run-tests.sh [--build]   (--build: build and install first)
# See docs/testing.md and docs/docker.md.
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
	# the mounted tree may hold objects of another build
	make clean >/dev/null
	make with_llvm=no WERROR=1
	make with_llvm=no install

	if [ -z "${PGHOST:-}" ]; then
		echo "== no PGHOST: a server of our own"
		PGDATA=$(mktemp -d)/data
		export PGDATA PGHOST=/tmp PGUSER=postgres
		bash tests/scripts/start-cluster.sh
		trap 'pg_ctl -w stop >/dev/null' EXIT
	fi
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

preload=$(psql -tAc "SHOW shared_preload_libraries")
case ",$preload," in
	*,leapfrog,*|*leapfrog*) ;;
	*) echo "warning: shared_preload_libraries does not list leapfrog ($preload); the tests LOAD it per session" >&2 ;;
esac

# the settings of temp.conf that pg_regress does not set per session
for name in jit max_parallel_workers_per_gather extra_float_digits; do
	want=$(sed -nE "s/^$name *= *'?([^'#]*[^'# ])'? *(#.*)?$/\1/p" tests/scripts/temp.conf)
	have=$(env -u PGTZ -u PGDATESTYLE -u PGOPTIONS psql -tAc "SHOW $name")
	if [ "$have" != "$want" ]; then
		echo "run-tests: $name is '$have', tests/scripts/temp.conf wants '$want':" \
			"start the server with temp.conf (start-cluster.sh, compose.yaml)" >&2
		exit 1
	fi
done

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
