#!/usr/bin/env bash
# Smoke test of the benchmark harness, so that CI catches a broken one.  Tiny runs of
# run.sh and bitmap_bench.sh, checking that they:
#   - replace helper objects left in another shape by an older version;
#   - leave no lf_bitmap table behind, also on failure;
#   - refuse an output directory that exists;
#   - list_bench.sh: every mode runs, the node and the exact index are used;
#   - never touch a database that is not theirs (no benchmark mark), and refuse
#     one that another benchmark holds the lock of.
#
# Connection: PGHOST/PGPORT/PGUSER.  Scratch databases: leapfrog_bench_smoke and
# leapfrog_bench_smoke_foreign, recognised by their comment and dropped; one of those
# names without the comment is not touched, and the test fails.  One run per server.
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

# bitmap_bench.sh: stale helper objects are replaced
$PSQL -d "$BENCH_DB" <<-'SQL'
	CREATE TABLE lf_bitmap_runs (stale_column int);
	CREATE VIEW lf_bitmap_metrics AS SELECT stale_column FROM lf_bitmap_runs;
	CREATE FUNCTION lf_bitmap_run(stale bigint, a text, b text, c int, d text)
	RETURNS void LANGUAGE sql AS 'SELECT';
SQL
bitmap_out="$tmp/bitmap"
BENCH_DB=$BENCH_DB BENCH_OUT=$bitmap_out SIZES=20000 REPEATS=1 WARMUP=0 \
	WORK_MEM=64MB bash tests/performance/bitmap_bench.sh > /dev/null

no_bitmap_table() {
	[ -z "$($PSQL -d "$BENCH_DB" -tAc "SELECT to_regclass('lf_bitmap')")" ]
}

# 1 size x 2 kinds of deleted rows x 6 queries x 6 modes, 1 run each
bitmap_rows=$(($(wc -l < "$bitmap_out/summary.csv") - 1))
if [ "$bitmap_rows" -ne 72 ]; then
	echo "bench-smoke: bitmap_bench.sh: expected 72 summary rows, got $bitmap_rows" >&2
	exit 1
fi
if ! awk -F, '$4 == "node" && $5 == "Index Merge Intersect" { n++ }
	$4 == "bitmap" && $5 ~ /Bitmap Heap Scan/ { b++ }
	END { exit !(n == 12 && b == 12) }' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: bitmap_bench.sh: the node or bitmap mode did not use its plan" >&2
	exit 1
fi
if ! grep -q ',pair_limit,indexscan,Index Scan on ' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: bitmap_bench.sh: the indexscan mode did not use an Index Scan" >&2
	exit 1
fi
if ! grep -q ',pair_limit1,exact,Index Scan on lf_bitmap_exact_pair,' "$bitmap_out/summary.csv"; then
	echo "bench-smoke: bitmap_bench.sh: the exact mode did not use its index" >&2
	exit 1
fi
if [ "$(grep -c ',lf_bitmap_exact_pair,' "$bitmap_out/sizes.csv")" -ne 2 ]; then
	echo "bench-smoke: bitmap_bench.sh: no size of the exact index in sizes.csv" >&2
	exit 1
fi
if ! no_bitmap_table; then
	echo "bench-smoke: bitmap_bench.sh left its lf_bitmap table behind" >&2
	exit 1
fi

# a run failing after the table is created drops it too
if BENCH_DB=$BENCH_DB BENCH_OUT="$tmp/bitmap-failed" SIZES=not_a_number \
	bash tests/performance/bitmap_bench.sh > /dev/null 2>&1; then
	echo "bench-smoke: bitmap_bench.sh with SIZES=not_a_number succeeded" >&2
	exit 1
fi
if ! no_bitmap_table; then
	echo "bench-smoke: a failed bitmap_bench.sh left its lf_bitmap table behind" >&2
	exit 1
fi

# list_bench.sh: 3 queries x 6 modes, 1 run each, rows in random order
list_out="$tmp/list"
BENCH_DB=$BENCH_DB BENCH_OUT=$list_out SIZE=400000 REPEATS=1 WARMUP=0 \
	WORK_MEM=64MB bash tests/performance/list_bench.sh > /dev/null
list_rows=$(($(wc -l < "$list_out/summary.csv") - 1))
if [ "$list_rows" -ne 18 ]; then
	echo "bench-smoke: list_bench.sh: expected 18 summary rows, got $list_rows" >&2
	exit 1
fi
if [ "$(grep -c ',node,Index Merge Intersect,' "$list_out/summary.csv")" -ne 3 ]; then
	echo "bench-smoke: list_bench.sh: the node mode did not use the node" >&2
	exit 1
fi
if ! grep -q '^small,exact,Index Scan on lf_list_exact,' "$list_out/summary.csv"; then
	echo "bench-smoke: list_bench.sh: the exact mode did not use its index" >&2
	exit 1
fi
if ! grep -q 'Index Merge Intersect' "$list_out/explain-small-node.txt"; then
	echo "bench-smoke: list_bench.sh: no text plan of the node" >&2
	exit 1
fi
if [ -n "$($PSQL -d "$BENCH_DB" -tAc "SELECT to_regclass('lf_list')")" ]; then
	echo "bench-smoke: list_bench.sh left its lf_list table behind" >&2
	exit 1
fi

echo "bench-smoke: ok ($rows result rows, $bitmap_rows bitmap_bench rows, $list_rows list_bench rows)"
