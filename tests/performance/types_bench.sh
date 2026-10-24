#!/usr/bin/env bash
# Equality columns of different types, for one build of the extension:
#
#   SELECT * FROM bench_types
#   WHERE <key column> = <value> AND f = 3
#   ORDER BY id DESC LIMIT :limit;
#
# The key has the same 200 values in every column, stored as bigint, integer,
# smallint, uuid, text and varchar, each with an index (<column>, id); the
# filter f has 20 values and an index (f, id).  So every case reads the same
# rows and only the type of the equality differs:
#
#   int8_int8        bigint   = bigint
#   int4_int8        integer  = bigint
#   int2_int8        smallint = bigint
#   uuid_uuid        uuid     = uuid
#   text_text        text     = text
#   varchar_text     varchar  = text
#
# Every query runs in three modes: auto (leapfrog enabled, the planner
# chooses), force (leapfrog.force) and stock (leapfrog disabled), with
# LIMIT 1, 10, 100 and 1000, WARMUP runs and then REPEATS runs through
# EXPLAIN (ANALYZE, BUFFERS, MEMORY, FORMAT JSON) in one session per block.
# A build that does not support a type falls back to a stock plan in every
# mode; the summary shows the node that ran.
#
# Run it once per build (make install of that build in between; the library
# is loaded per session) into separate output directories, then compare:
#
#   BENCH_LABEL=old BENCH_OUT=results/types-old bash types_bench.sh
#   BENCH_LABEL=new BENCH_OUT=results/types-new bash types_bench.sh
#   bash types_compare.sh results/types-old results/types-new
#
# The table is loaded when missing or with BENCH_RELOAD=1, so both builds
# read the same data and the same physical layout.
#
# Environment: PGHOST/PGPORT/PGUSER/PGDATABASE; ROWS (1000000), REPEATS (15),
# WARMUP (2), LIMITS ("1 10 100 1000"), MODES ("auto force stock"), CASES
# (all), BENCH_LABEL (leapfrog_version()), BENCH_RELOAD (0), BENCH_OUT (a
# directory that must not exist yet).
# Output: tests/performance/results/types-<timestamp>/runs.csv (one row per
# run), summary.csv and server.txt.
set -euo pipefail

cd "$(dirname "$0")"

ROWS=${ROWS:-1000000}
REPEATS=${REPEATS:-15}
WARMUP=${WARMUP:-2}
LIMITS=${LIMITS:-"1 10 100 1000"}
MODES=${MODES:-"auto force stock"}
CASES=${CASES:-"int8_int8 int4_int8 int2_int8 uuid_uuid text_text varchar_text"}
RELOAD=${BENCH_RELOAD:-0}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${BENCH_OUT:-"results/types-$stamp"}
mkdir -p "$(dirname "$out")"
if ! mkdir "$out"; then
	echo "types_bench.sh: output directory $out exists, refusing to mix two runs" >&2
	exit 1
fi
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

label=${BENCH_LABEL:-$($PSQL -tAc "LOAD 'leapfrog'; SELECT leapfrog_version()" 2>/dev/null || echo unknown)}

$PSQL -tAc "SELECT version()" > "$out/server.txt"
echo "label=$label" >> "$out/server.txt"
$PSQL -tAc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','random_page_cost','seq_page_cost','effective_cache_size','jit','max_parallel_workers_per_gather')" >> "$out/server.txt"

loaded=$($PSQL -tAc "SELECT to_regclass('bench_types') IS NOT NULL")
if [ "$RELOAD" = 1 ] || [ "$loaded" != t ]; then
	$PSQL <<-SQL
		DROP TABLE IF EXISTS bench_types;
		CREATE TABLE bench_types (
			id bigint PRIMARY KEY,
			k8 bigint NOT NULL,
			k4 integer NOT NULL,
			k2 smallint NOT NULL,
			ku uuid NOT NULL,
			kt text NOT NULL,
			kv varchar(32) NOT NULL,
			f bigint NOT NULL,
			payload text
		) WITH (autovacuum_enabled = false);
		INSERT INTO bench_types
		SELECT g, k, k, k,
			('00000000-0000-0000-0000-' || lpad(to_hex(k), 12, '0'))::uuid,
			'owner-' || k, 'owner-' || k, f, repeat('x', 40)
		FROM (SELECT g, abs(hashint8(g * 2)) % 200 AS k,
					 abs(hashint8(g * 2 + 1)) % 20 AS f
			  FROM generate_series(1, $ROWS) g) s;
		CREATE INDEX ON bench_types (k8, id);
		CREATE INDEX ON bench_types (k4, id);
		CREATE INDEX ON bench_types (k2, id);
		CREATE INDEX ON bench_types (ku, id);
		CREATE INDEX ON bench_types (kt, id);
		CREATE INDEX ON bench_types (kv, id);
		CREATE INDEX ON bench_types (f, id);
		VACUUM ANALYZE bench_types;
	SQL
fi

$PSQL <<-'SQL'
	CREATE TABLE IF NOT EXISTS bench_types_runs (
		label text, case_name text, lim int, mode text, run int, plan jsonb);
	TRUNCATE bench_types_runs;
	CREATE OR REPLACE FUNCTION bench_types_run(label text, case_name text,
		lim int, mode text, query text, warmup int, repeats int)
	RETURNS void LANGUAGE plpgsql AS $$
	DECLARE
		plan json;
	BEGIN
		PERFORM set_config('leapfrog.enabled', (mode <> 'stock')::text, true);
		PERFORM set_config('leapfrog.force', (mode = 'force')::text, true);
		FOR i IN 1 - warmup .. repeats LOOP
			EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, MEMORY, FORMAT JSON) ' || query
				INTO plan;
			IF i >= 1 THEN
				INSERT INTO bench_types_runs
				VALUES (label, case_name, lim, mode, i, (plan -> 0)::jsonb);
			END IF;
		END LOOP;
	END
	$$;
SQL

condition() {
	case $1 in
		int8_int8) echo "k8 = 17::bigint" ;;
		int4_int8) echo "k4 = 17::bigint" ;;
		int2_int8) echo "k2 = 17::bigint" ;;
		uuid_uuid) echo "ku = '00000000-0000-0000-0000-000000000011'::uuid" ;;
		text_text) echo "kt = 'owner-17'::text" ;;
		varchar_text) echo "kv = 'owner-17'::text" ;;
	esac
}

for c in $CASES; do
	for l in $LIMITS; do
		for m in $MODES; do
			q="SELECT * FROM bench_types WHERE $(condition "$c") AND f = 3 ORDER BY id DESC LIMIT $l"
			$PSQL -c "LOAD 'leapfrog'; SET max_parallel_workers_per_gather = 0;" \
				-c "SELECT bench_types_run('$label', '$c', $l, '$m', \$q\$$q\$q\$, $WARMUP, $REPEATS)" >/dev/null
		done
	done
done

$PSQL <<-SQL
	CREATE OR REPLACE VIEW bench_types_metrics AS
	SELECT label, case_name, lim, mode, run,
		coalesce(n ->> 'Custom Plan Provider',
				 jsonb_path_query_first(plan, '\$.Plan.** ? (@."Node Type" like_regex "Scan\$")."Node Type"') #>> '{}') AS node,
		(plan ->> 'Planning Time')::float8 AS planning_ms,
		(plan ->> 'Execution Time')::float8 AS execution_ms,
		(plan -> 'Plan' ->> 'Shared Hit Blocks')::bigint AS shared_hit,
		(plan -> 'Plan' ->> 'Shared Read Blocks')::bigint AS shared_read,
		(SELECT sum(value::bigint) FROM jsonb_each_text(n) WHERE key LIKE '%Entries Read%') AS entries_read,
		(n ->> 'Heap Fetches')::bigint AS heap_fetches,
		(n ->> 'Peak Group Memory')::bigint AS peak_group_bytes,
		(plan -> 'Planning' ->> 'Memory Used')::float8 AS planning_memory_kb,
		(plan -> 'Plan' ->> 'Actual Rows')::float8 AS rows
	FROM (SELECT *, jsonb_path_query_first(plan, '\$.** ? (exists(@."Custom Plan Provider"))') AS n
		  FROM bench_types_runs) r;
SQL

$PSQL -c "\\copy (SELECT * FROM bench_types_metrics ORDER BY case_name, lim, mode, run) TO '$out/runs.csv' CSV HEADER"
$PSQL -c "\\copy (SELECT label, case_name, lim, mode, mode() WITHIN GROUP (ORDER BY node) AS node, count(*) AS runs,
	round(percentile_cont(0.5) WITHIN GROUP (ORDER BY planning_ms)::numeric, 3) AS planning_median,
	round(percentile_cont(0.9) WITHIN GROUP (ORDER BY planning_ms)::numeric, 3) AS planning_p90,
	round(percentile_cont(0.5) WITHIN GROUP (ORDER BY execution_ms)::numeric, 3) AS execution_median,
	round(percentile_cont(0.9) WITHIN GROUP (ORDER BY execution_ms)::numeric, 3) AS execution_p90,
	round(max(execution_ms)::numeric, 3) AS execution_max,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY shared_hit) AS shared_hit,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY shared_read) AS shared_read,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY entries_read) AS entries_read,
	percentile_disc(0.5) WITHIN GROUP (ORDER BY heap_fetches) AS heap_fetches,
	max(peak_group_bytes) AS peak_group_bytes,
	round(percentile_cont(0.5) WITHIN GROUP (ORDER BY planning_memory_kb)::numeric, 1) AS planning_memory_kb,
	max(rows) AS rows
	FROM bench_types_metrics GROUP BY 1, 2, 3, 4 ORDER BY 2, 3, 4) TO '$out/summary.csv' CSV HEADER"

column -s, -t < "$out/summary.csv"
echo "types_bench: results in $out"
