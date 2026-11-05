#!/usr/bin/env bash
# Smoke test of the benchmark harness: tiny runs of list_bench.sh and uniform_bench.sh.
# Usage: bench-smoke.sh
# Environment: PGHOST/PGPORT/PGUSER.  See docs/tooling.md.
set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck source=tests/performance/bench_db.sh
. tests/performance/bench_db.sh

BENCH_DB=leapfrog_bench_smoke
foreign=leapfrog_bench_smoke_foreign
foreign_mark='leapfrog bench-smoke stand-in for a database with real data'
PSQL="psql -X -q -v ON_ERROR_STOP=1"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-bench-smoke.XXXXXX")

smoke_lock_key='1818650210, 2'

cleanup() {
	PGDATABASE=$BENCH_DB bench_db_unlock
	bench_db_drop >/dev/null 2>&1 || true
	scratch_db_drop "$foreign" "$foreign_mark" >/dev/null 2>&1 || true
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

status=0
scratch_db_drop "$foreign" "$foreign_mark" || status=$?
if [ "$status" -eq "$SCRATCH_DB_FOREIGN" ]; then
	echo "bench-smoke: database $foreign exists and is not this script's" \
		"(no comment '$foreign_mark')" >&2
	exit 1
fi
if [ "$status" -ne 0 ] || ! bench_db_drop; then
	echo "bench-smoke: could not drop $BENCH_DB or $foreign left by an" \
		"earlier run; is a benchmark from it still running?" >&2
	exit 1
fi

# a database with data of its own, as PGDATABASE often names
scratch_db_create "$foreign" "$foreign_mark"
$PSQL -d "$foreign" -c "CREATE TABLE orders (id bigint)" -c "INSERT INTO orders VALUES (1), (2), (3)"
export PGDATABASE=$foreign

bench_db_prepare
export PGDATABASE=$foreign

foreign_intact() {
	[ "$($PSQL -d "$foreign" -tAc "SELECT count(*) FROM orders")" = 3 ]
}

# BENCH_DB naming a database that is not a benchmark database is refused
if BENCH_DB=$foreign BENCH_OUT="$tmp/refused" bash tests/performance/list_bench.sh >/dev/null 2>&1; then
	echo "bench-smoke: list_bench.sh ran in $foreign, which is not a benchmark database" >&2
	exit 1
fi
if ! foreign_intact || [ -e "$tmp/refused" ]; then
	echo "bench-smoke: a refused list_bench.sh changed $foreign or wrote results" >&2
	exit 1
fi

# a second benchmark in a database where one is running is refused
PGDATABASE=$BENCH_DB bench_db_lock
if BENCH_DB=$BENCH_DB BENCH_OUT="$tmp/locked" bash tests/performance/list_bench.sh >/dev/null 2>&1; then
	echo "bench-smoke: list_bench.sh ran while another benchmark held the lock" >&2
	exit 1
fi
if [ -e "$tmp/locked" ]; then
	echo "bench-smoke: a list_bench.sh refused for the lock wrote results" >&2
	exit 1
fi
PGDATABASE=$BENCH_DB bench_db_unlock

# uniform_bench.sh: stale helper objects are replaced
$PSQL -d "$BENCH_DB" <<-'SQL'
	CREATE TABLE lf_bitmap_runs (stale_column int);
	CREATE VIEW lf_bitmap_metrics AS SELECT stale_column FROM lf_bitmap_runs;
	CREATE FUNCTION lf_bitmap_run(stale bigint, a text, b text, c int, d text)
	RETURNS void LANGUAGE sql AS 'SELECT';
SQL
bitmap_out="$tmp/bitmap"
BENCH_DB=$BENCH_DB BENCH_OUT=$bitmap_out SIZES=20000 REPEATS=1 WARMUP=0 \
	WORK_MEM=64MB bash tests/performance/uniform_bench.sh > /dev/null

no_bitmap_table() {
	[ -z "$($PSQL -d "$BENCH_DB" -tAc "SELECT to_regclass('lf_bitmap')")" ]
}

# 1 size x 2 kinds of deleted rows x 6 queries x 6 modes, 1 run each
bitmap_rows=$(($(wc -l < "$bitmap_out/summary.csv") - 1))
if [ "$bitmap_rows" -ne 72 ]; then
	echo "bench-smoke: uniform_bench.sh: expected 72 summary rows, got $bitmap_rows" >&2
	exit 1
fi
if ! awk -F, '$4 == "node" && $5 == "Index Merge Intersect" { n++ }
	$4 == "bitmap" && $5 ~ /Bitmap Heap Scan/ { b++ }
	END { exit !(n == 12 && b == 12) }' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: uniform_bench.sh: the node or bitmap mode did not use its plan" >&2
	exit 1
fi
if ! grep -q ',pair_limit,indexscan,Index Scan on ' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: uniform_bench.sh: the indexscan mode did not use an Index Scan" >&2
	exit 1
fi
if ! grep -q ',pair_limit1,exact,Index Scan on lf_bitmap_exact_pair,' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: uniform_bench.sh: the exact mode did not use its index" >&2
	exit 1
fi
if [ "$(grep -c ',lf_bitmap_exact_pair,' "$bitmap_out/sizes.csv")" -ne 2 ]; then
	echo "bench-smoke: uniform_bench.sh: no size of the exact index in sizes.csv" >&2
	exit 1
fi
if ! no_bitmap_table; then
	echo "bench-smoke: uniform_bench.sh left its lf_bitmap table behind" >&2
	exit 1
fi

# a run failing after the table is created drops it too
if BENCH_DB=$BENCH_DB BENCH_OUT="$tmp/bitmap-failed" SIZES=not_a_number \
	bash tests/performance/uniform_bench.sh > /dev/null 2>&1; then
	echo "bench-smoke: uniform_bench.sh with SIZES=not_a_number succeeded" >&2
	exit 1
fi
if ! no_bitmap_table; then
	echo "bench-smoke: a failed uniform_bench.sh left its lf_bitmap table behind" >&2
	exit 1
fi

# list_bench.sh: 3 scenarios x 6 modes, 1 run each, rows in random order
list_out="$tmp/list"
list_run() {
	BENCH_DB=$BENCH_DB BENCH_OUT=$list_out SIZE=400000 REPEATS=1 WARMUP=0 \
		WORK_MEM=64MB bash tests/performance/list_bench.sh > /dev/null
}
list_run
if ! foreign_intact; then
	echo "bench-smoke: list_bench.sh changed the orders table of PGDATABASE ($foreign)" >&2
	exit 1
fi
for scenario in large_customer small_customer two_filters; do
	scenario_out="$list_out/$scenario"
	scenario_rows=$(($(wc -l < "$scenario_out/summary.csv") - 1))
	if [ "$scenario_rows" -ne 6 ]; then
		echo "bench-smoke: list_bench.sh: $scenario: expected 6 summary rows, got $scenario_rows" >&2
		exit 1
	fi
	if ! grep -q ",node,Index Merge Intersect," "$scenario_out/summary.csv"; then
		echo "bench-smoke: list_bench.sh: $scenario: the node mode did not use the node" >&2
		exit 1
	fi
	if ! grep -q 'lf_list_exact' "$scenario_out/explain-exact.txt"; then
		echo "bench-smoke: list_bench.sh: $scenario: the exact mode did not use its index" >&2
		exit 1
	fi
	if ! grep -q 'Index Merge Intersect' "$scenario_out/explain-node.txt"; then
		echo "bench-smoke: list_bench.sh: $scenario: no text plan of the node" >&2
		exit 1
	fi
done
if [ -n "$($PSQL -d "$BENCH_DB" -tAc "SELECT to_regclass('lf_list')")" ]; then
	echo "bench-smoke: list_bench.sh left its lf_list table behind" >&2
	exit 1
fi

# a second run into the same directory is refused and leaves it as it was
before=$(md5sum < "$list_out/two_filters/summary.csv")
if list_run 2>/dev/null; then
	echo "bench-smoke: list_bench.sh wrote into an existing output directory" >&2
	exit 1
fi
if [ "$(md5sum < "$list_out/two_filters/summary.csv")" != "$before" ]; then
	echo "bench-smoke: a refused run changed the existing results" >&2
	exit 1
fi

echo "bench-smoke: ok ($bitmap_rows uniform_bench rows, 3 list_bench scenarios)"
