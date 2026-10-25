#!/usr/bin/env bash
# Index Merge Intersect against BitmapAnd as the table grows.
#
# BitmapAnd reads every index entry of both conditions before it returns a
# row, so its work grows with the table; the node reads the streams in id
# order and stops at the LIMIT.  For each size in SIZES and each way of
# deleting rows in DELETED a table of that many rows is loaded:
#
#   customer_id   100 values, hashed            index (customer_id, id)
#   product_id     50 values, hashed            index (product_id, id)
#   deleted_at    see below                     index (id) WHERE deleted_at
#                                                     IS NOT NULL
#
#   hashed    10 % of the rows, spread evenly over id and the customers
#   batches   12.5 % of the rows, in batches: the id range is cut into 64
#             blocks, and a customer's rows in a block are deleted all or
#             none, in every 8th block, a different one for each customer
#             ((block + customer_id) % 8 = 0).  Customer 7, the one the
#             queries ask for, has no deleted rows in the 6 newest blocks
#             while the other customers have theirs there.  The rows are
#             loaded in random order, so the heap is not in id order either,
#             as in a table whose rows are updated in place.
#
# batches is the case that the stock plans get wrong: PostgreSQL takes the
# deleted rows as spread evenly over id and independent of the customer, so
# it expects the 100 newest deleted rows of customer 7 within its 800 newest
# rows and picks an Index Scan on (customer_id, id) with deleted_at as a
# filter, which fetches from the heap every row of the 6 blocks first;
# BitmapAnd reads the whole partial index.  The node reads only index
# entries until the matches.
#
# Every query of the mix runs in four modes, interleaved run by run in
# ABBA order (node bitmap stock auto, then auto stock bitmap node), so that
# no mode always runs right after the one that evicted the most pages:
#
#   node     leapfrog on, the stock scans disabled: the node, its cheapest
#            set by its own estimate (not leapfrog.force, whose scaled costs
#            hide that)
#   bitmap   leapfrog off, Index Scan and Seq Scan disabled: a bitmap plan
#   stock    leapfrog off: what PostgreSQL picks without the extension
#   auto     leapfrog on: what PostgreSQL picks with it
#
# recording, per run, execution time, shared buffers, index entries read
# (the node's counters, or the rows of the Bitmap Index Scans), shared
# buffers read from outside shared_buffers (OS cache or disk), heap rows
# and the plan's scan node.  The queries without LIMIT are the case where
# both plans have to read everything; they are in the mix on purpose.
#
# work_mem matters to BitmapAnd: a bitmap larger than work_mem turns lossy,
# keeps whole heap pages and rechecks every row on them (Lossy Heap Blocks,
# Rows Removed by Index Recheck).  At the server's default of 4MB that
# happens at 10M rows; WORK_MEM=64MB keeps the bitmaps exact at 10M rows and
# 256MB at 50M, for a comparison that does not rest on it.  The README's
# table is SIZES="1000000 10000000 50000000" WORK_MEM=256MB WARMUP=5, run
# several times.
#
# The helper objects (lf_bitmap_runs, lf_bitmap_run(), lf_bitmap_metrics)
# are dropped and recreated by every run, so that ones left in BENCH_DB by
# an older version of the script do not get in the way; the table
# lf_bitmap, up to 11 GB at 50M rows, is dropped when the script exits,
# however it exits.
#
# Environment: PGHOST/PGPORT/PGUSER; BENCH_DB (leapfrog_bench, see
# bench_db.sh); SIZES ("100000 1000000 10000000"), REPEATS (11), WARMUP (2),
# DELETED ("hashed batches"), WORK_MEM (empty: the server's setting),
# BENCH_OUT (a directory that must not exist yet).
# Output: tests/performance/results/bitmap-<timestamp>/runs.csv (one row
# per run), summary.csv (medians and p90 per size, deleted rows, query and
# mode) and server.txt.
set -euo pipefail

cd "$(dirname "$0")"
. ./bench_db.sh

SIZES=${SIZES:-"100000 1000000 10000000"}
REPEATS=${REPEATS:-11}
WARMUP=${WARMUP:-2}
WORK_MEM=${WORK_MEM:-}
DELETED=${DELETED:-"hashed batches"}
MODES="node bitmap stock auto"

bench_db_use
trap 'psql -X -q -c "DROP TABLE IF EXISTS lf_bitmap" >/dev/null 2>&1 || true; bench_db_unlock' EXIT

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${BENCH_OUT:-"results/bitmap-$stamp"}
mkdir -p "$(dirname "$out")"
if ! mkdir "$out"; then
	echo "bitmap_bench.sh: output directory $out exists, refusing to mix two runs" >&2
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
	CREATE TABLE lf_bitmap_runs (
		size bigint, deleted text, query text, mode text, run int, plan jsonb);
	CREATE FUNCTION lf_bitmap_run(size bigint, deleted text, name text,
		mode text, run int, query text)
	RETURNS void LANGUAGE plpgsql AS $$
	DECLARE
		plan json;
	BEGIN
		PERFORM set_config('leapfrog.enabled', (mode IN ('node', 'auto'))::text, true);
		PERFORM set_config('leapfrog.force', 'off', true);
		PERFORM set_config('enable_seqscan', (mode IN ('stock', 'auto'))::text, true);
		PERFORM set_config('enable_indexscan', (mode IN ('stock', 'auto'))::text, true);
		PERFORM set_config('enable_indexonlyscan', (mode IN ('stock', 'auto'))::text, true);
		PERFORM set_config('enable_bitmapscan', (mode <> 'node')::text, true);
		EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query INTO plan;
		IF run >= 1 THEN
			INSERT INTO lf_bitmap_runs VALUES (size, deleted, name, mode, run, (plan -> 0)::jsonb);
		END IF;
	END
	$$;
SQL

query() {
	case $1 in
		pair_limit) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC LIMIT 100" ;;
		deleted_limit) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100" ;;
		pair_all) echo "SELECT * FROM lf_bitmap WHERE customer_id = 7 AND product_id = 3 ORDER BY id DESC" ;;
	esac
}
QUERIES="pair_limit deleted_limit pair_all"

deleted_expr() {
	case $1 in
		hashed) echo "abs(hashint8(g * 4 + 3)) % 10 = 0" ;;
		batches) echo "((g - 1)::bigint * 64 / $2 + abs(hashint8(g * 4 + 1)) % 100) % 8 = 0" ;;
		*) echo "bitmap_bench.sh: unknown DELETED value $1" >&2; return 1 ;;
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
		coalesce((SELECT sum(value::bigint) FROM jsonb_each_text(n) WHERE key LIKE '%Entries Read%'),
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
	ORDER BY 2, 3, 1, array_position(ARRAY['node', 'bitmap', 'stock', 'auto'], mode)) TO '$out/summary.csv' CSV HEADER"

column -s, -t < "$out/summary.csv" 2>/dev/null || cat "$out/summary.csv"
echo "bitmap_bench: results in $out"
