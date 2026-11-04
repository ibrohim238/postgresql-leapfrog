#!/usr/bin/env bash
# The list query with rare, scattered matches, one scenario at a time, the way a test
# looks at one case: each has its query and its exact index, its results in a directory
# of its own, and runs without the exact index of another.
#
#   large_customer  a customer with 5 % of the rows, one live per 200,000 ids
#   small_customer  a customer with 1 % of the rows, one live per 200,000 ids
#   two_filters     that customer and a product with 2 % of the rows
#
# At 100M rows each customer has 500 live rows and the two filters share 20,012 rows, 11
# live. Below 20M rows the customers have fewer than the query's LIMIT 100 and it never
# stops early: another workload, which a warning says.
#
# Table: SIZE rows in random physical order (ORDER=id: in id order), 5 % of them live.
# Indexes (customer_id, id), (product_id, id), (id) WHERE deleted_at IS NULL. Loaded once.
#
# Modes, in ABBA order:
#   node    leapfrog on, stock scans disabled
#   bitmap  leapfrog off, a bitmap plan
#   indexscan  leapfrog off, an Index Scan with a Filter
#   stock   leapfrog off, the planner's choice
#   auto    leapfrog on, the planner's choice
#   exact   leapfrog off, with the scenario's exact index; runs last
# Text plans of node, stock and exact go to explain-<mode>.txt.
#
# Environment: PGHOST/PGPORT/PGUSER; BENCH_DB (see bench_db.sh); SCENARIOS (all three),
# SIZE (1000000), ORDER (random | id), REPEATS (3), WARMUP (1), WORK_MEM (server's),
# EXACT (1), BENCH_OUT (must not exist). Output in results/list-<timestamp>/: server.txt,
# sizes.csv, and <scenario>/ with runs.csv, summary.csv and explain-*.txt.
set -euo pipefail

cd "$(dirname "$0")"
. ./bench_db.sh

SIZE=${SIZE:-1000000}
ORDER=${ORDER:-random}
REPEATS=${REPEATS:-3}
WARMUP=${WARMUP:-1}
WORK_MEM=${WORK_MEM:-}
EXACT=${EXACT:-1}
MODES="node bitmap indexscan stock auto"
SCENARIOS=${SCENARIOS:-"large_customer small_customer two_filters"}

for name in $SCENARIOS; do
	case $name in
		large_customer|small_customer|two_filters) ;;
		*) echo "list_bench.sh: unknown scenario $name" >&2; exit 1 ;;
	esac
done
if [ "$SIZE" -lt 20000000 ]; then
	echo "list_bench.sh: at $SIZE rows the customers have fewer than 100 live rows: LIMIT 100 never stops early" >&2
fi

case $ORDER in
	random) order="ORDER BY hashint8(g * 4 + 7)" ;;
	id) order= ;;
	*) echo "list_bench.sh: ORDER must be random or id" >&2; exit 1 ;;
esac

bench_db_use
trap 'psql -X -q -c "DROP TABLE IF EXISTS lf_list" >/dev/null 2>&1 || true; bench_db_unlock' EXIT

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${BENCH_OUT:-"results/list-$stamp"}
mkdir -p "$(dirname "$out")"
if ! mkdir "$out"; then
	echo "list_bench.sh: output directory $out exists, refusing to mix two runs" >&2
	exit 1
fi
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

$PSQL -tAc "SELECT version()" > "$out/server.txt"
$PSQL -tAc "LOAD 'leapfrog'; SELECT 'leapfrog=' || leapfrog_version()" >> "$out/server.txt" 2>/dev/null || true
$PSQL -tAc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','random_page_cost','seq_page_cost','effective_cache_size','jit','max_parallel_workers_per_gather')" >> "$out/server.txt"
echo "size=$SIZE order=$ORDER; queries run with work_mem=${WORK_MEM:-server setting}" >> "$out/server.txt"
settings="LOAD 'leapfrog'; SET max_parallel_workers_per_gather = 0;"
[ -n "$WORK_MEM" ] && settings="$settings SELECT set_config('work_mem', :'work_mem', false);"
modes_reversed=$(echo $MODES | tr ' ' '\n' | tac | tr '\n' ' ')

$PSQL <<-'SQL'
	DROP VIEW IF EXISTS lf_list_metrics;
	DROP FUNCTION IF EXISTS lf_list_run(text, text, int, text);
	DROP TABLE IF EXISTS lf_list_runs;
	DROP TABLE IF EXISTS lf_list_sizes;
	CREATE TABLE lf_list_runs (query text, mode text, run int, plan jsonb);
	CREATE TABLE lf_list_sizes (relation text, bytes bigint);
	CREATE FUNCTION lf_list_run(name text, mode text, run int, query text)
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
			INSERT INTO lf_list_runs VALUES (name, mode, run, (plan -> 0)::jsonb);
		END IF;
	END
	$$;
SQL

# mode_settings <mode>: the SET lines of lf_list_run, for the text plans
mode_settings() {
	local lf=off ss=off is=off bs=off
	case $1 in
		node) lf=on ;;
		auto) lf=on; ss=on; is=on; bs=on ;;
		stock|exact) ss=on; is=on; bs=on ;;
		indexscan) is=on ;;
		bitmap) bs=on ;;
	esac
	echo "SET leapfrog.enabled = $lf; SET enable_seqscan = $ss; SET enable_indexscan = $is; SET enable_indexonlyscan = $is; SET enable_bitmapscan = $bs;"
}

$PSQL <<-'SQL'
	CREATE VIEW lf_list_metrics AS
	SELECT query, mode, run,
		coalesce(n ->> 'Custom Plan Provider',
				 (SELECT string_agg(DISTINCT (m ->> 'Node Type') || coalesce(' on ' || (m ->> 'Index Name'), ''), '+')
				  FROM jsonb_path_query(plan, 'strict $.Plan.**') m
				  WHERE m ->> 'Node Type' IN ('BitmapAnd', 'Bitmap Heap Scan', 'Index Scan', 'Seq Scan', 'Sort'))) AS node,
		(plan ->> 'Execution Time')::float8 AS exec_ms,
		(plan -> 'Plan' ->> 'Shared Hit Blocks')::bigint
			+ (plan -> 'Plan' ->> 'Shared Read Blocks')::bigint AS buffers,
		(plan -> 'Plan' ->> 'Shared Read Blocks')::bigint AS buffers_read,
		(SELECT sum((s ->> 'Entries Read')::bigint) FROM jsonb_array_elements(n -> 'Index Streams') s) AS index_entries,
		(n ->> 'Heap Fetches')::bigint AS heap_fetches,
		(plan -> 'Plan' ->> 'Actual Rows')::float8 AS rows
	FROM (SELECT *, jsonb_path_query_first(plan, '$.** ? (exists(@."Custom Plan Provider"))') AS n
		  FROM lf_list_runs) r;
SQL

# scenario <name>: its query and exact index
scenario() {
	local exact_two="CREATE INDEX lf_list_exact ON lf_list (customer_id, product_id, id) WHERE deleted_at IS NULL"
	local exact_one="CREATE INDEX lf_list_exact ON lf_list (customer_id, id) WHERE deleted_at IS NULL"
	case $1 in
		large_customer)
			case_query="SELECT * FROM lf_list WHERE customer_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100"
			case_exact=$exact_one ;;
		small_customer)
			case_query="SELECT * FROM lf_list WHERE customer_id = 4 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100"
			case_exact=$exact_one ;;
		two_filters)
			case_query="SELECT * FROM lf_list WHERE customer_id = 4 AND product_id = 120 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100"
			case_exact=$exact_two ;;
	esac
}

run_modes() {
	local modes=$1 run ms mode
	echo "   $name: $modes"
	{
		echo "$settings"
		for run in $(seq $((1 - WARMUP)) "$REPEATS"); do
			if [ $((run % 2)) -eq 0 ]; then ms=$modes; else ms=$(echo $modes | tr ' ' '\n' | tac | tr '\n' ' '); fi
			for mode in $ms; do
				echo "SELECT lf_list_run('$name', '$mode', $run, \$q\$$case_query\$q\$);"
			done
		done
	} | $PSQL -v work_mem="$WORK_MEM" >/dev/null
}

text_plans() {
	local mode
	for mode in "$@"; do
		{
			echo "$settings"
			mode_settings "$mode"
			echo "EXPLAIN (ANALYZE, BUFFERS, COSTS OFF) $case_query;"
		} | $PSQL -v work_mem="$WORK_MEM" > "$out/$name/explain-$mode.txt"
	done
}

echo "== $SIZE rows, order $ORDER: load"
$PSQL <<-SQL
	DROP TABLE IF EXISTS lf_list;
	CREATE TABLE lf_list (
		id bigint NOT NULL,
		customer_id bigint NOT NULL,
		product_id bigint NOT NULL,
		deleted_at timestamptz,
		payload text
	) WITH (autovacuum_enabled = false);
	INSERT INTO lf_list
	SELECT g, c0, 100 + abs(hashint8(g * 4 + 2)) % 50,
		CASE WHEN c0 = 4 THEN CASE WHEN g % 200000 = 0 THEN NULL ELSE '2026-01-01'::timestamptz END
			 WHEN c0 = 5 THEN CASE WHEN g % 200000 = 100000 THEN NULL ELSE '2026-01-01'::timestamptz END
			 WHEN h3 = 0 THEN NULL ELSE '2026-01-01'::timestamptz END,
		repeat('x', 60)
	FROM (SELECT g,
			CASE WHEN g % 200000 = 0 THEN 4 WHEN g % 200000 = 100000 THEN 5
				 WHEN h1 = 4 THEN 4 WHEN h1 BETWEEN 5 AND 9 THEN 5 ELSE 100 + h1 END AS c0,
			h3
		  FROM (SELECT g, abs(hashint8(g * 4 + 1)) % 100 AS h1, abs(hashint8(g * 4 + 3)) % 20 AS h3
				FROM generate_series(1, $SIZE) g) s) t
	$order;
	ALTER TABLE lf_list ADD PRIMARY KEY (id);
	CREATE INDEX ON lf_list (customer_id, id);
	CREATE INDEX ON lf_list (product_id, id);
	CREATE INDEX ON lf_list (id) WHERE deleted_at IS NULL;
	VACUUM ANALYZE lf_list;
SQL
$PSQL -tAc "SELECT 'customer ' || customer_id || ': ' || count(*) || ' rows, ' || count(*) FILTER (WHERE deleted_at IS NULL) || ' live'
	FROM lf_list WHERE customer_id IN (4, 5) GROUP BY customer_id
	UNION ALL SELECT 'live rows: ' || count(*) FROM lf_list WHERE deleted_at IS NULL" >> "$out/server.txt"

for name in $SCENARIOS; do
	scenario "$name"
	mkdir "$out/$name"
	echo "== $name"
	run_modes "$MODES"
	text_plans node stock
	if [ "$EXACT" = 1 ]; then
		$PSQL -c "$case_exact" -c "ANALYZE lf_list"
		run_modes exact
		text_plans exact
		$PSQL -c "INSERT INTO lf_list_sizes
			SELECT '$name: lf_list_exact', pg_relation_size('lf_list_exact')"
		$PSQL -c "DROP INDEX lf_list_exact" -c "ANALYZE lf_list"
	fi
	$PSQL -c "\\copy (SELECT * FROM lf_list_metrics WHERE query = '$name' ORDER BY mode, run) TO '$out/$name/runs.csv' CSV HEADER"
	$PSQL -c "\\copy (SELECT query, mode, mode() WITHIN GROUP (ORDER BY node) AS node, count(*) AS runs,
		round(percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)::numeric, 3) AS exec_median,
		round(min(exec_ms)::numeric, 3) AS exec_min, round(max(exec_ms)::numeric, 3) AS exec_max,
		percentile_disc(0.5) WITHIN GROUP (ORDER BY buffers) AS buffers,
		max(buffers_read) AS max_buffers_read,
		percentile_disc(0.5) WITHIN GROUP (ORDER BY index_entries) AS index_entries,
		max(heap_fetches) AS heap_fetches, max(rows) AS rows
		FROM lf_list_metrics WHERE query = '$name' GROUP BY 1, 2
		ORDER BY array_position(ARRAY['exact', 'node', 'auto', 'stock', 'indexscan', 'bitmap'], mode)) TO '$out/$name/summary.csv' CSV HEADER"
	echo "== $name"
	column -s, -t < "$out/$name/summary.csv" 2>/dev/null || cat "$out/$name/summary.csv"
done
$PSQL -c "INSERT INTO lf_list_sizes
	SELECT c.relname, pg_relation_size(c.oid) FROM pg_class c
	WHERE c.oid = 'lf_list'::regclass
		OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = 'lf_list'::regclass)"
$PSQL -c "DROP TABLE IF EXISTS lf_list"

$PSQL -c "\\copy (SELECT * FROM lf_list_sizes ORDER BY 1) TO '$out/sizes.csv' CSV HEADER"

echo "list_bench: results in $out"
