#!/usr/bin/env bash
# Uniform data: the node against BitmapAnd and an exact index as the table grows.
# Usage: [VAR=value ...] uniform_bench.sh
# Environment: PGHOST/PGPORT/PGUSER, BENCH_DB, SIZES, REPEATS, WARMUP, DELETED,
# WORK_MEM, EXACT, BENCH_OUT.  See docs/benchmarks.md.
set -euo pipefail

cd "$(dirname "$0")"
. ./bench_db.sh

SIZES=${SIZES:-"100000 1000000 10000000"}
REPEATS=${REPEATS:-11}
WARMUP=${WARMUP:-2}
WORK_MEM=${WORK_MEM:-}
DELETED=${DELETED:-"hashed batches"}
MODES="node bitmap indexscan stock auto"
EXACT=${EXACT:-1}

bench_db_use
trap 'psql -X -q -c "DROP TABLE IF EXISTS lf_bitmap" >/dev/null 2>&1 || true; bench_db_unlock' EXIT

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${BENCH_OUT:-"results/uniform-$stamp"}
mkdir -p "$(dirname "$out")"
if ! mkdir "$out"; then
	echo "uniform_bench.sh: output directory $out exists, refusing to mix two runs" >&2
	exit 1
fi
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

$PSQL -tAc "SELECT version()" > "$out/server.txt"
$PSQL -tAc "LOAD 'leapfrog'; SELECT 'leapfrog=' || leapfrog_version()" >> "$out/server.txt" 2>/dev/null || true
$PSQL -tAc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','random_page_cost','seq_page_cost','effective_cache_size','jit','max_parallel_workers_per_gather')" >> "$out/server.txt"
echo "queries run with work_mem=${WORK_MEM:-server setting}" >> "$out/server.txt"
settings="LOAD 'leapfrog'; SET max_parallel_workers_per_gather = 0;"
[ -n "$WORK_MEM" ] && settings="$settings SELECT set_config('work_mem', :'work_mem', false);"
modes_reversed=$(echo $MODES | tr ' ' '\n' | tac | tr '\n' ' ')

$PSQL <<-'SQL'
	DROP VIEW IF EXISTS lf_bitmap_metrics;
	DROP FUNCTION IF EXISTS lf_bitmap_run(bigint, text, text, int, text);
	DROP FUNCTION IF EXISTS lf_bitmap_run(bigint, text, text, text, int, text);
	DROP TABLE IF EXISTS lf_bitmap_runs;
	DROP TABLE IF EXISTS lf_bitmap_sizes;
	CREATE TABLE lf_bitmap_runs (
		size bigint, deleted text, query text, mode text, run int, plan jsonb);
	CREATE TABLE lf_bitmap_sizes (
		size bigint, deleted text, relation text, bytes bigint);
	CREATE FUNCTION lf_bitmap_run(size bigint, deleted text, name text,
		mode text, run int, query text)
	RETURNS void LANGUAGE plpgsql AS $$
	DECLARE
		plan json;
	BEGIN
		PERFORM set_config('leapfrog.enabled', (mode IN ('node', 'auto'))::text, true);
		PERFORM set_config('leapfrog.force', 'off', true);
		PERFORM set_config('enable_seqscan', (mode IN ('stock', 'auto', 'exact'))::text, true);
		PERFORM set_config('enable_indexscan', (mode IN ('stock', 'auto', 'exact', 'indexscan'))::text, true);
		PERFORM set_config('enable_indexonlyscan', (mode IN ('stock', 'auto', 'exact', 'indexscan'))::text, true);
		PERFORM set_config('enable_bitmapscan', (mode NOT IN ('node', 'indexscan'))::text, true);
		EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query INTO plan;
		IF run >= 1 THEN
			INSERT INTO lf_bitmap_runs VALUES (size, deleted, name, mode, run, (plan -> 0)::jsonb);
		END IF;
	END
	$$;
SQL

query() {
	case $1 in
		pair_limit1) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC LIMIT 1" ;;
		pair_limit) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC LIMIT 100" ;;
		pair_limit1000) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC LIMIT 1000" ;;
		triple_limit) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100" ;;
		deleted_limit) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100" ;;
		pair_all) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC" ;;
	esac
}
QUERIES="pair_limit1 pair_limit pair_limit1000 deleted_limit triple_limit pair_all"

record_sizes() {
	$PSQL -c "INSERT INTO lf_bitmap_sizes
		SELECT $1, '$2', c.relname, pg_relation_size(c.oid)
		FROM pg_class c
		WHERE c.oid = 'lf_bitmap'::regclass
			OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = 'lf_bitmap'::regclass)"
}

deleted_expr() {
	case $1 in
		hashed) echo "abs(hashint8(g * 4 + 3)) % 10 = 0" ;;
		batches) echo "((g - 1)::bigint * 64 / $2 + abs(hashint8(g * 4 + 1)) % 100) % 8 = 0" ;;
		*) echo "uniform_bench.sh: unknown DELETED value $1" >&2; return 1 ;;
	esac
}

for size in $SIZES; do
for deleted in $DELETED; do
	cond=$(deleted_expr "$deleted" "$size")
	order=
	[ "$deleted" = batches ] && order="ORDER BY hashint8(g * 4)"
	echo "== $size rows, deleted $deleted: load"
	$PSQL <<-SQL
		DROP TABLE IF EXISTS lf_bitmap;
		CREATE TABLE lf_bitmap (
			id bigint NOT NULL,
			customer_id bigint NOT NULL,
			product_id bigint NOT NULL,
			deleted_at timestamptz,
			payload text
		) WITH (autovacuum_enabled = false);
		INSERT INTO lf_bitmap
		SELECT g, abs(hashint8(g * 4 + 1)) % 100, abs(hashint8(g * 4 + 2)) % 50,
			CASE WHEN $cond THEN '2026-01-01'::timestamptz END,
			repeat('x', 60)
		FROM generate_series(1, $size) g $order;
		ALTER TABLE lf_bitmap ADD PRIMARY KEY (id);
		CREATE INDEX ON lf_bitmap (customer_id, id);
		CREATE INDEX ON lf_bitmap (product_id, id);
		CREATE INDEX ON lf_bitmap (id) WHERE deleted_at IS NOT NULL;
		VACUUM ANALYZE lf_bitmap;
	SQL
	for name in $QUERIES; do
		q=$(query "$name")
		echo "   $name"
		{
			echo "$settings"
			for run in $(seq $((1 - WARMUP)) "$REPEATS"); do
				if [ $((run % 2)) -eq 0 ]; then modes=$MODES; else modes=$modes_reversed; fi
				for mode in $modes; do
					echo "SELECT lf_bitmap_run($size, '$deleted', '$name', '$mode', $run, \$q\$$q\$q\$);"
				done
			done
		} | $PSQL -v work_mem="$WORK_MEM" >/dev/null
	done
	if [ "$EXACT" = 1 ]; then
		echo "   exact: indexes"
		started=$(date +%s)
		$PSQL <<-SQL
			CREATE INDEX lf_bitmap_exact_pair ON lf_bitmap (customer_id, product_id, id);
			CREATE INDEX lf_bitmap_exact_deleted ON lf_bitmap (customer_id, id) WHERE deleted_at IS NOT NULL;
			CREATE INDEX lf_bitmap_exact_triple ON lf_bitmap (customer_id, product_id, id) WHERE deleted_at IS NOT NULL;
			ANALYZE lf_bitmap;
		SQL
		$PSQL -c "INSERT INTO lf_bitmap_sizes VALUES ($size, '$deleted', 'exact indexes, seconds to build', $(($(date +%s) - started)))"
		for name in $QUERIES; do
			q=$(query "$name")
			echo "   $name, exact"
			{
				echo "$settings"
				for run in $(seq $((1 - WARMUP)) "$REPEATS"); do
					echo "SELECT lf_bitmap_run($size, '$deleted', '$name', 'exact', $run, \$q\$$q\$q\$);"
				done
			} | $PSQL -v work_mem="$WORK_MEM" >/dev/null
		done
	fi
	record_sizes "$size" "$deleted"
done
done
$PSQL -c "DROP TABLE IF EXISTS lf_bitmap"

$PSQL <<-'SQL'
	CREATE VIEW lf_bitmap_metrics AS
	SELECT size, deleted, query, mode, run,
		coalesce(n ->> 'Custom Plan Provider',
				 (SELECT string_agg(DISTINCT (m ->> 'Node Type') || coalesce(' on ' || (m ->> 'Index Name'), ''), '+')
				  FROM jsonb_path_query(plan, 'strict $.Plan.**') m
				  WHERE m ->> 'Node Type' IN ('BitmapAnd', 'Bitmap Heap Scan', 'Index Scan', 'Seq Scan', 'Sort'))) AS node,
		(plan ->> 'Execution Time')::float8 AS exec_ms,
		(plan -> 'Plan' ->> 'Shared Hit Blocks')::bigint
			+ (plan -> 'Plan' ->> 'Shared Read Blocks')::bigint AS buffers,
		(plan -> 'Plan' ->> 'Shared Read Blocks')::bigint AS buffers_read,
		coalesce((SELECT sum((s ->> 'Entries Read')::bigint) FROM jsonb_array_elements(n -> 'Index Streams') s),
				 (SELECT sum((m ->> 'Actual Rows')::numeric)::bigint
				  FROM jsonb_path_query(plan, 'strict $.Plan.**') m
				  WHERE m ->> 'Node Type' = 'Bitmap Index Scan')) AS index_entries,
		(plan -> 'Plan' ->> 'Actual Rows')::float8 AS rows,
		(SELECT sum((m ->> 'Lossy Heap Blocks')::bigint)
		 FROM jsonb_path_query(plan, 'strict $.Plan.**') m) AS lossy_blocks
	FROM (SELECT *, jsonb_path_query_first(plan, '$.** ? (exists(@."Custom Plan Provider"))') AS n
		  FROM lf_bitmap_runs) r;
SQL

$PSQL -c "\\copy (SELECT * FROM lf_bitmap_metrics ORDER BY size, deleted, query, mode, run) TO '$out/runs.csv' CSV HEADER"
$PSQL -c "\\copy (SELECT size, deleted, query, mode, mode() WITHIN GROUP (ORDER BY node) AS node, count(*) AS runs,
	round(percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)::numeric, 3) AS exec_median,
	round(percentile_cont(0.9) WITHIN GROUP (ORDER BY exec_ms)::numeric, 3) AS exec_p90,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY buffers) AS buffers,
	max(buffers_read) AS max_buffers_read,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY index_entries) AS index_entries,
	max(rows) AS rows, max(lossy_blocks) AS lossy_blocks
	FROM lf_bitmap_metrics GROUP BY 1, 2, 3, 4
	ORDER BY 2, 3, 1, array_position(ARRAY['node', 'bitmap', 'indexscan', 'stock', 'auto', 'exact'], mode)) TO '$out/summary.csv' CSV HEADER"
$PSQL -c "\\copy (SELECT * FROM lf_bitmap_sizes ORDER BY 1, 2, 3) TO '$out/sizes.csv' CSV HEADER"

column -s, -t < "$out/summary.csv" 2>/dev/null || cat "$out/summary.csv"
echo "uniform_bench: results in $out"
