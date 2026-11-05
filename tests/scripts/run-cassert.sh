#!/usr/bin/env bash
# Entry point of docker/cassert.Dockerfile: start an assert-enabled server
# with the library preloaded (tests/scripts/start-cluster.sh), run the
# regression and isolation suites, and fail if the server log has an
# assertion failure or a crashed backend.
set -euo pipefail

cd "$(dirname "$0")/../.."

export PGLOG=/tmp/server.log
bash tests/scripts/start-cluster.sh

if [ "$(psql -tAc 'SHOW debug_assertions')" != on ]; then
	echo "the server is not built with --enable-cassert" >&2
	exit 1
fi

status=0
bash tests/scripts/run-tests.sh || status=1

pg_ctl -w stop >/dev/null || status=1

if grep -E 'TRAP:|terminated by signal|server process .* was terminated' "$PGLOG"; then
	echo "assertion failure or crashed backend in the server log" >&2
	status=1
fi

exit $status
