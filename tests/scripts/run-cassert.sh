#!/usr/bin/env bash
# Entry point of docker/cassert.Dockerfile: start an assert-enabled server
# with the library preloaded, run the regression and isolation suites, and
# fail if the server log has an assertion failure or a crashed backend.
set -euo pipefail

cd "$(dirname "$0")/../.."

initdb -U postgres --no-sync >/dev/null
cat tests/scripts/temp.conf >>"$PGDATA/postgresql.conf"
pg_ctl -w -l /tmp/server.log -o "-k /tmp -c listen_addresses=''" start >/dev/null

if [ "$(psql -tAc 'SHOW debug_assertions')" != on ]; then
	echo "the server is not built with --enable-cassert" >&2
	exit 1
fi

status=0
bash tests/scripts/run-tests.sh || status=1

pg_ctl -w stop >/dev/null || status=1

if grep -E 'TRAP:|terminated by signal|server process .* was terminated' /tmp/server.log; then
	echo "assertion failure or crashed backend in the server log" >&2
	status=1
fi

exit $status
