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
# Connection: PGHOST/PGPORT/PGUSER as usual; the scratch database is
# BENCH_SMOKE_DB (default leapfrog_bench_smoke) and is dropped afterwards.
set -euo pipefail

cd "$(dirname "$0")/../.."

db=${BENCH_SMOKE_DB:-leapfrog_bench_smoke}
PSQL="psql -X -q -v ON_ERROR_STOP=1"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-bench-smoke.XXXXXX")
out="$tmp/run"

cleanup() {
	$PSQL -d postgres -c "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

$PSQL -d postgres -c "DROP DATABASE IF EXISTS $db"
$PSQL -d postgres -c "CREATE DATABASE $db"

$PSQL -d "$db" -c "CREATE FUNCTION bench_owners() RETURNS TABLE (stale_column int) LANGUAGE sql AS 'SELECT 1'"

run() {
	PGDATABASE=$db BENCH_OUT=$out BENCH_SIZES=2000 BENCH_DISTS="uniform skewed" \
		BENCH_DELETED=10 BENCH_LIMITS="10 0" BENCH_REPEATS=1 \
		bash tests/performance/run.sh > /dev/null
}

run

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
