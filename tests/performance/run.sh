#!/usr/bin/env bash
# Reproducible benchmark of three index strategies for
#
#   SELECT * FROM orders
#   WHERE customer_id = :owner AND deleted_at IS [NOT] NULL
#   ORDER BY id DESC LIMIT :limit;
#
#   A  standard PostgreSQL:   (customer_id, id)
#   B  PostgreSQL + leapfrog: (customer_id, id) + (id) WHERE deleted_at IS NULL
#                                                + (id) WHERE deleted_at IS NOT NULL
#   C  specialised partial:   (customer_id, id) WHERE deleted_at IS NULL
#                             (customer_id, id) WHERE deleted_at IS NOT NULL
#
# For every data size, distribution and deleted share, the script loads the
# data once, builds the indexes of one strategy, warms the cache and runs
# every query of the mix BENCH_REPEATS times through EXPLAIN (ANALYZE,
# BUFFERS, FORMAT JSON).  Results are appended to
# tests/performance/results/<timestamp>/results.csv; the full plans go to
# plans.jsonl next to it.
#
# Environment (all optional):
#   PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE   connection
#   BENCH_SIZES      "100000 1000000"           row counts
#   BENCH_DISTS      "uniform skewed"           distributions
#   BENCH_DELETED    "1 10 50 90"               deleted share, percent
#   BENCH_LIMITS     "1 100 1000 0"             0 means no LIMIT
#   BENCH_REPEATS    5
#   BENCH_SEED       0.42
#   BENCH_FORCE      0|1   also run strategy B with leapfrog.force = on
#
# The 10M and 100M profiles are not run by default:
#   BENCH_SIZES="10000000" bash tests/performance/run.sh
#   BENCH_SIZES="100000000" BENCH_DELETED="10" bash tests/performance/run.sh
set -euo pipefail

cd "$(dirname "$0")"

SIZES=${BENCH_SIZES:-"100000 1000000"}
DISTS=${BENCH_DISTS:-"uniform skewed"}
DELETED=${BENCH_DELETED:-"1 10 50 90"}
LIMITS=${BENCH_LIMITS:-"1 100 1000 0"}
REPEATS=${BENCH_REPEATS:-5}
# random_page_cost for the queries; empty means the server's setting.
# 1.1 is the usual value for SSDs and data that fits in memory.
RPC=${BENCH_RANDOM_PAGE_COST:-}
SEED=${BENCH_SEED:-0.42}
FORCE=${BENCH_FORCE:-1}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="results/$stamp"
mkdir -p "$out"
csv="$out/results.csv"
plans="$out/plans.jsonl"

PSQL="psql -X -q -v ON_ERROR_STOP=1"
export PGOPTIONS="-c client_min_messages=warning"

$PSQL -tAc "SELECT version()" > "$out/server.txt"
$PSQL -tAc "LOAD 'leapfrog'; SELECT 'leapfrog=' || leapfrog_version()" >> "$out/server.txt" 2>/dev/null || true
$PSQL -tAc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','random_page_cost','seq_page_cost','effective_cache_size','shared_preload_libraries','jit','max_parallel_workers_per_gather')" >> "$out/server.txt"
echo "queries run with random_page_cost=${RPC:-server setting}" >> "$out/server.txt"

if ! $PSQL -tAc "SELECT 1 FROM pg_extension WHERE extname = 'leapfrog'" | grep -q 1; then
	$PSQL -c "CREATE EXTENSION leapfrog"
fi
$PSQL -f bench.sql

echo "size,distribution,deleted_pct,strategy,forced,owner_label,owner_id,owner_rows,owner_deleted,predicate,limit,run,plan_node,exec_ms,plan_ms,shared_hit,shared_read,rows_out,outer_read,inner_read,heap_fetches,rows_removed,index_bytes" > "$csv"

build_indexes() {
	local strategy=$1
	$PSQL <<-SQL
		DROP INDEX IF EXISTS idx_outer, idx_inner_live, idx_inner_deleted,
			idx_optimal_live, idx_optimal_deleted;
	SQL
	case $strategy in
		A)
			$PSQL -c "CREATE INDEX idx_outer ON orders (customer_id, id)" ;;
		B)
			$PSQL -c "CREATE INDEX idx_outer ON orders (customer_id, id)" \
				  -c "CREATE INDEX idx_inner_live ON orders (id) WHERE deleted_at IS NULL" \
				  -c "CREATE INDEX idx_inner_deleted ON orders (id) WHERE deleted_at IS NOT NULL" ;;
		C)
			$PSQL -c "CREATE INDEX idx_optimal_live ON orders (customer_id, id) WHERE deleted_at IS NULL" \
				  -c "CREATE INDEX idx_optimal_deleted ON orders (customer_id, id) WHERE deleted_at IS NOT NULL" ;;
	esac
	$PSQL -c "VACUUM ANALYZE orders"
}

index_bytes() {
	$PSQL -tAc "SELECT coalesce(sum(pg_relation_size(indexrelid)), 0) FROM pg_index WHERE indrelid = 'orders'::regclass AND indexrelid::regclass::text <> 'orders_pkey'"
}

run_query() {
	local size=$1 dist=$2 del=$3 strategy=$4 forced=$5 label=$6 owner=$7 owner_rows=$8 owner_deleted=$9 pred=${10} limit=${11} ibytes=${12}
	local where limit_clause settings q
	case $pred in
		live) where="deleted_at IS NULL" ;;
		deleted) where="deleted_at IS NOT NULL" ;;
	esac
	limit_clause=""
	[ "$limit" != "0" ] && limit_clause="LIMIT $limit"
	q="SELECT * FROM orders WHERE customer_id = $owner AND $where ORDER BY id DESC $limit_clause"

	# every psql call is a new session: load the library explicitly, so the
	# benchmark does not depend on shared_preload_libraries
	settings="LOAD 'leapfrog'; SET leapfrog.enabled = $([ "$strategy" = B ] && echo on || echo off); SET leapfrog.force = $([ "$forced" = 1 ] && echo on || echo off);"
	[ -n "$RPC" ] && settings="$settings SET random_page_cost = $RPC;"

	$PSQL -tA -F',' <<-SQL >> "$csv"
		$settings
		SELECT '$size','$dist','$del','$strategy','$forced','$label','$owner','$owner_rows','$owner_deleted','$pred','$limit',
			run, plan_node, exec_ms, plan_ms, shared_hit, shared_read, rows_out,
			coalesce(outer_read::text, ''), coalesce(inner_read::text, ''),
			coalesce(heap_fetches::text, ''), coalesce(rows_removed::text, ''), '$ibytes'
		FROM bench_run(\$q\$ $q \$q\$, $REPEATS);
	SQL
	$PSQL -tA <<-SQL >> "$plans"
		$settings
		SELECT jsonb_build_object('size', $size, 'distribution', '$dist', 'deleted_pct', $del,
			'strategy', '$strategy', 'forced', $forced, 'owner', $owner, 'predicate', '$pred',
			'limit', $limit, 'plan', plan_json)
		FROM bench_run(\$q\$ $q \$q\$, 1, 0);
	SQL
}

for size in $SIZES; do
	for dist in $DISTS; do
		for del in $DELETED; do
			echo "== rows=$size distribution=$dist deleted=$del%"
			$PSQL -v rows="$size" -v seed="$SEED" -v distribution="$dist" -v deleted_pct="$del" -f schema.sql

			owners=$($PSQL -tA -F' ' -c "SELECT label, customer_id, total, deleted FROM bench_owners()")

			for strategy in A B C; do
				build_indexes "$strategy"
				ibytes=$(index_bytes)
				forced_list="0"
				[ "$strategy" = B ] && [ "$FORCE" = 1 ] && forced_list="0 1"
				for forced in $forced_list; do
					echo "   strategy $strategy forced=$forced index_bytes=$ibytes"
					while read -r label owner owner_rows owner_deleted; do
						for pred in live deleted; do
							for limit in $LIMITS; do
								run_query "$size" "$dist" "$del" "$strategy" "$forced" "$label" "$owner" "$owner_rows" "$owner_deleted" "$pred" "$limit" "$ibytes"
							done
						done
					done <<< "$owners"
				done
			done
		done
	done
done

$PSQL -c "DROP TABLE IF EXISTS orders"

echo "results: $csv"
bash summarize.sh "$csv" | tee "$out/summary.txt"
