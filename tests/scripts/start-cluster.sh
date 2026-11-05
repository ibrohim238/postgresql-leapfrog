#!/usr/bin/env bash
# Start a test server with tests/scripts/temp.conf and run the smoke check.
# Usage: start-cluster.sh [postgres options ...]
# Environment: PGDATA (required), PGHOST, PGPORT, PGUSER, PGLOG,
# LEAPFROG_SHARED_BUFFERS.  See docs/testing.md.
set -euo pipefail

cd "$(dirname "$0")/../.."

: "${PGDATA:?PGDATA must name the data directory to create}"
export PGHOST=${PGHOST:-/tmp}
export PGPORT=${PGPORT:-5432}
export PGUSER=${PGUSER:-postgres}
log=${PGLOG:-$PGDATA/server.log}

initdb -U "$PGUSER" -A trust --no-sync >/dev/null

{
	echo
	echo "# tests/scripts/temp.conf"
	cat tests/scripts/temp.conf
	echo
	echo "# tests/scripts/start-cluster.sh"
	echo "shared_buffers = '${LEAPFROG_SHARED_BUFFERS:-128MB}'"
	echo "port = $PGPORT"
	case "$PGHOST" in
		/*)
			echo "unix_socket_directories = '$PGHOST'"
			echo "listen_addresses = ''"
			;;
		*)
			echo "listen_addresses = '$PGHOST'"
			;;
	esac
} >>"$PGDATA/postgresql.conf"

opts=
if [ $# -gt 0 ]; then
	opts=$(printf '%q ' "$@")
fi
pg_ctl -w -t 120 -l "$log" -o "$opts" start >/dev/null || {
	cat "$log" >&2
	exit 1
}

if ! psql -X -q -v ON_ERROR_STOP=1 -d postgres -f tests/scripts/smoke.sql; then
	echo "start-cluster.sh: the smoke check failed" >&2
	exit 1
fi
