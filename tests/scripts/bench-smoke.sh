#!/usr/bin/env bash
# Smoke test of the benchmark harness: a tiny run of tests/performance/run.sh
# in a scratch database, so that a broken harness is caught by CI rather
# than at the next real measurement.
#
# The database is seeded with a bench_owners() whose result columns differ
# from the current one, as a database left over from an older version of the
# harness would have; run.sh must replace it.
#
# The run writes into a temporary directory of its own (BENCH_OUT), not into
# tests/performance/results, so earlier results there, of any benchmark,
# neither confuse the checks nor get touched; the temporary directory is
# removed afterwards.  A second run into the same directory must be refused.
#
# The benchmarks must never touch a database that is not theirs.  A
# database without the benchmark mark, with an orders table, is set up as
# PGDATABASE: run.sh must leave it alone, and run.sh with BENCH_DB naming it
# must refuse to start.  Neither may run.sh while another benchmark holds
# the lock of its database.
#
# Connection: PGHOST/PGPORT/PGUSER as usual.  The scratch databases are
# leapfrog_bench_smoke and leapfrog_bench_smoke_foreign, each with a comment
# of its own; one left over by an earlier run is recognised by it and
# dropped, before and after the run.  An existing database of either name
# without that comment is not touched, and the smoke test fails.  One
# bench-smoke at a time per server: a run holds the benchmark lock, under
# a key of its own, in BENCH_ADMIN_DB, and touches the databases only once
# it has it.
set -euo pipefail

cd "$(dirname "$0")/../.."
. tests/performance/bench_db.sh

BENCH_DB=leapfrog_bench_smoke
foreign=leapfrog_bench_smoke_foreign
foreign_mark='leapfrog bench-smoke stand-in for a database with real data'
PSQL="psql -X -q -v ON_ERROR_STOP=1"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-bench-smoke.XXXXXX")
out="$tmp/run"

# drop the stand-in database if it carries its comment
drop_foreign() {
	local state
	state=$($PSQL -tA -d "${BENCH_ADMIN_DB:-postgres}" -v db="$foreign" \
		-v mark="$foreign_mark" <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
	)
	if [ "$state" = t ]; then
		$PSQL -d "${BENCH_ADMIN_DB:-postgres}" -v db="$foreign" \
			<<< 'DROP DATABASE :"db"'
	fi
}

smoke_lock_key='1818650210, 2'

cleanup() {
	PGDATABASE=$BENCH_DB bench_db_unlock
	bench_db_drop >/dev/null 2>&1 || true
	drop_foreign >/dev/null 2>&1 || true
	BENCH_DB_LOCK_FD=$smoke_lock_fd BENCH_DB_LOCK_PID=$smoke_lock_pid \
		BENCH_DB_LOCK_APP=$smoke_lock_app BENCH_DB_LOCK_KEY=$smoke_lock_key \
		PGDATABASE=${BENCH_ADMIN_DB:-postgres} bench_db_unlock
	rm -rf "$tmp"
}

# one bench-smoke at a time; exits here if another one runs
BENCH_DB_LOCK_KEY=$smoke_lock_key PGDATABASE=${BENCH_ADMIN_DB:-postgres} \
	bench_db_lock
smoke_lock_fd=$BENCH_DB_LOCK_FD
smoke_lock_pid=$BENCH_DB_LOCK_PID
smoke_lock_app=$BENCH_DB_LOCK_APP
BENCH_DB_LOCK_FD=
trap cleanup EXIT

if ! bench_db_drop || ! drop_foreign; then
	echo "bench-smoke: could not drop $BENCH_DB or $foreign left by an" \
		"earlier run; is a benchmark from it still running?" >&2
	exit 1
fi
if [ -n "$($PSQL -tA -d "${BENCH_ADMIN_DB:-postgres}" -v db="$foreign" \
	<<< "SELECT 1 FROM pg_database WHERE datname = :'db'")" ]; then
	echo "bench-smoke: database $foreign exists and is not this script's" \
		"(no comment '$foreign_mark')" >&2
	exit 1
fi

# a database with data of its own, as PGDATABASE often names
$PSQL -d "${BENCH_ADMIN_DB:-postgres}" -v db="$foreign" -v mark="$foreign_mark" <<-'SQL'
	CREATE DATABASE :"db";
	COMMENT ON DATABASE :"db" IS :'mark';
SQL
$PSQL -d "$foreign" -c "CREATE TABLE orders (id bigint)" -c "INSERT INTO orders VALUES (1), (2), (3)"
export PGDATABASE=$foreign

bench_db_prepare
$PSQL -c "CREATE FUNCTION bench_owners() RETURNS TABLE (stale_column int) LANGUAGE sql AS 'SELECT 1'"
export PGDATABASE=$foreign

foreign_intact() {
	[ "$($PSQL -d "$foreign" -tAc "SELECT count(*) FROM orders")" = 3 ]
}

# BENCH_DB naming a database that is not a benchmark database is refused
if BENCH_DB=$foreign BENCH_OUT="$tmp/refused" bash tests/performance/run.sh >/dev/null 2>&1; then
	echo "bench-smoke: run.sh ran in $foreign, which is not a benchmark database" >&2
	exit 1
fi
if ! foreign_intact || [ -e "$tmp/refused" ]; then
	echo "bench-smoke: a refused run.sh changed $foreign or wrote results" >&2
	exit 1
fi

# a second benchmark in a database where one is running is refused
PGDATABASE=$BENCH_DB bench_db_lock
if BENCH_DB=$BENCH_DB BENCH_OUT="$tmp/locked" bash tests/performance/run.sh >/dev/null 2>&1; then
	echo "bench-smoke: run.sh ran while another benchmark held the lock" >&2
	exit 1
fi
if [ -e "$tmp/locked" ]; then
	echo "bench-smoke: a run.sh refused for the lock wrote results" >&2
	exit 1
fi
PGDATABASE=$BENCH_DB bench_db_unlock

run() {
	BENCH_DB=$BENCH_DB BENCH_OUT=$out BENCH_SIZES=2000 BENCH_DISTS="uniform skewed" \
		BENCH_DELETED=10 BENCH_LIMITS="10 0" BENCH_REPEATS=1 \
		bash tests/performance/run.sh > /dev/null
}

run

if ! foreign_intact; then
	echo "bench-smoke: run.sh changed the orders table of PGDATABASE ($foreign)" >&2
	exit 1
fi

if [ ! -f "$out/results.csv" ]; then
	echo "bench-smoke: run.sh wrote no $out/results.csv" >&2
	exit 1
fi

# 2 distributions x 1 deleted share x 3 owners x 2 predicates x 2 limits
# = 24 queries per strategy run, 4 strategy runs (A, B, B*, C), 1 repeat
rows=$(($(wc -l < "$out/results.csv") - 1))
expected=$((24 * 4))
if [ "$rows" -ne "$expected" ]; then
	echo "bench-smoke: expected $expected result rows, got $rows" >&2
	exit 1
fi

# the forced strategy must actually have used the node
if ! awk -F, '$4 == "B" && $5 == "1" && $13 == "Index Merge Intersect" { found = 1 } END { exit !found }' "$out/results.csv"; then
	echo "bench-smoke: no Index Merge Intersect plan under leapfrog.force" >&2
	exit 1
fi

# a second run into the same directory is refused and leaves it as it was
before=$(md5sum < "$out/results.csv")
if run 2>/dev/null; then
	echo "bench-smoke: run.sh wrote into an existing output directory" >&2
	exit 1
fi
if [ "$(md5sum < "$out/results.csv")" != "$before" ]; then
	echo "bench-smoke: a refused run changed the existing results" >&2
	exit 1
fi

echo "bench-smoke: ok ($rows result rows)"
