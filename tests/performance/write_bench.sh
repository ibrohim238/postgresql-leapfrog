#!/usr/bin/env bash
# Write and storage benchmark: what index composition saves on writes, and
# what it costs or gains on reads.
#
# A table with NFILTERS filter columns and soft deletes, served by
#
#   S    specialised indexes: per filter column (fK, id) WHERE deleted_at IS
#        NULL and (fK, id) WHERE deleted_at IS NOT NULL, plus composite
#        (fI, fJ, id), (fI, fJ, fK, id) and (fI, fJ, fK, fL, id) WHERE
#        deleted_at IS NULL for the frequent filter combinations
#        (2 * NFILTERS + combinations indexes);
#   G+L  general indexes with leapfrog: per filter column (fK, id), plus
#        (id) WHERE deleted_at IS NULL and (id) WHERE deleted_at IS NOT NULL
#        (NFILTERS + 2 indexes); leapfrog combines two or more of them;
#   G    the same general indexes, stock PostgreSQL (leapfrog.enabled = off).
#
# For S and G (G+L shares G's indexes and writes) the script loads BASE_ROWS
# rows, builds the indexes, then measures, each after a CHECKPOINT:
#   insert   BATCH_ROWS new rows
#   update   soft-delete BATCH_ROWS/4 rows (deleted_at changes)
#   update2  change one filter column of BATCH_ROWS/4 rows
#   delete   BATCH_ROWS/4 rows
# as rows per second and WAL bytes; and the total index size.  Then a query
# mix (single filter live/deleted; two, three and four filters, each with a
# composite index in S and without one) runs for S, G+L and G: median
# execution and planning time over REPEATS runs after a warm-up, the plan's
# top scan node and, for leapfrog, the number of indexes it combined.
#
# Environment: PGHOST/PGPORT/PGUSER/PGDATABASE; NFILTERS (12), BASE_ROWS
# (500000), BATCH_ROWS (100000), REPEATS (5).
# Output: tests/performance/results/<timestamp>/write.csv, read.csv and a
# summary on stdout.
set -euo pipefail

cd "$(dirname "$0")"

NFILTERS=${NFILTERS:-12}
BASE_ROWS=${BASE_ROWS:-500000}
BATCH_ROWS=${BATCH_ROWS:-100000}
REPEATS=${REPEATS:-5}
QUARTER=$((BATCH_ROWS / 4))

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="results/write-$stamp"
mkdir -p "$out"
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

$PSQL -tAc "SELECT version()" > "$out/server.txt"
$PSQL -tAc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('shared_buffers','work_mem','max_wal_size','checkpoint_timeout','wal_level','full_page_writes','synchronous_commit')" >> "$out/server.txt"

# value of filter column k for row g: 100 distinct values per column from a
# deterministic hash, independent of the other columns and of deleted_at
filter_expr() {
	local k=$1 g=$2
	echo "(abs(hashint8(($g)::bigint * 64 + $k)) % 100)"
}

columns="" ; values=""
for k in $(seq 1 "$NFILTERS"); do
	columns+=", f$k bigint NOT NULL"
done

insert_rows() {
	local from=$1 to=$2 vals=""
	for k in $(seq 1 "$NFILTERS"); do
		vals+=", $(filter_expr "$k" g)"
	done
	echo "INSERT INTO orders SELECT g$vals,
		CASE WHEN g <= $((BASE_ROWS * 4 / 10)) AND g % 5 = 0 THEN '2026-01-01'::timestamptz END,
		repeat('x', 60)
	FROM generate_series($from, $to) g;"
}

# frequent filter combinations that get a composite index in strategy S
combinations="1:2 1:3 2:3 4:5 6:7 8:9 1:2:3 4:5:6 1:2:3:4"

create_indexes() {
	local strategy=$1
	if [ "$strategy" = S ]; then
		for k in $(seq 1 "$NFILTERS"); do
			echo "CREATE INDEX ON orders (f$k, id) WHERE deleted_at IS NULL;"
			echo "CREATE INDEX ON orders (f$k, id) WHERE deleted_at IS NOT NULL;"
		done
		for c in $combinations; do
			echo "CREATE INDEX ON orders (f${c//:/, f}, id) WHERE deleted_at IS NULL;"
		done
	else
		for k in $(seq 1 "$NFILTERS"); do
			echo "CREATE INDEX ON orders (f$k, id);"
		done
		echo "CREATE INDEX ON orders (id) WHERE deleted_at IS NULL;"
		echo "CREATE INDEX ON orders (id) WHERE deleted_at IS NOT NULL;"
	fi
}

load() {
	local strategy=$1
	{
		echo "DROP TABLE IF EXISTS orders;"
		echo "CREATE TABLE orders (id bigint PRIMARY KEY$columns, deleted_at timestamptz, payload text) WITH (autovacuum_enabled = false);"
		insert_rows 1 "$BASE_ROWS"
		create_indexes "$strategy"
		echo "VACUUM ANALYZE orders;"
	} | $PSQL
}

# measure <strategy> <operation> <rows> <sql>
measure() {
	local strategy=$1 op=$2 rows=$3 sql=$4
	$PSQL -tA -F, <<-SQL >> "$out/write.csv"
		CHECKPOINT;
		SELECT pg_current_wal_insert_lsn() AS l0, clock_timestamp() AS t0 \gset
		$sql
		SELECT '$strategy', '$op', $rows,
			round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 3),
			round($rows / extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)),
			pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'l0'::pg_lsn);
	SQL
}

index_size() {
	$PSQL -tAc "SELECT pg_indexes_size('orders') - pg_relation_size('orders_pkey')"
}

index_count() {
	$PSQL -tAc "SELECT count(*) - 1 FROM pg_index WHERE indrelid = 'orders'::regclass"
}

query() {
	case $1 in
		single_live) echo "SELECT * FROM orders WHERE f5 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		single_deleted) echo "SELECT * FROM orders WHERE f5 = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100" ;;
		pair_composite) echo "SELECT * FROM orders WHERE f1 = 7 AND f2 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		pair_no_composite) echo "SELECT * FROM orders WHERE f10 = 7 AND f11 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		triple_composite) echo "SELECT * FROM orders WHERE f1 = 7 AND f2 = 7 AND f3 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		triple_no_composite) echo "SELECT * FROM orders WHERE f10 = 7 AND f11 = 7 AND f12 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		quad_composite) echo "SELECT * FROM orders WHERE f1 = 7 AND f2 = 7 AND f3 = 7 AND f4 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
		quad_no_composite) echo "SELECT * FROM orders WHERE f9 = 7 AND f10 = 7 AND f11 = 7 AND f12 = 7 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100" ;;
	esac
}

read_mix() {
	local label=$1 settings=$2 q
	for name in single_live single_deleted pair_composite pair_no_composite \
		triple_composite triple_no_composite quad_composite quad_no_composite; do
		q=$(query "$name")
		$PSQL -tA -F, <<-SQL >> "$out/read.csv"
			LOAD 'leapfrog';
			SET max_parallel_workers_per_gather = 0;
			$settings
			$q \g /dev/null
			$q \g /dev/null
			CREATE TEMP TABLE runs (exec_ms float8, plan_ms float8, node text, indexes int, rows float8);
			DO \$\$
			DECLARE j jsonb;
			BEGIN
				FOR i IN 1 .. $REPEATS LOOP
					EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) $q' INTO j;
					INSERT INTO runs SELECT (j->0->>'Execution Time')::float8,
						(j->0->>'Planning Time')::float8,
						(SELECT coalesce(n->>'Custom Plan Provider', n->>'Node Type')
						 FROM jsonb_path_query(j, 'strict \$[0].Plan.**') n
						 WHERE n ? 'Relation Name' LIMIT 1),
						(SELECT count(*) FROM jsonb_path_query(j, 'strict \$[0].Plan.**') n,
							jsonb_object_keys(n) k
						 WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect'
							AND k ~ '^(Outer|Inner) Index'),
						(j->0->'Plan'->>'Actual Rows')::float8;
				END LOOP;
			END \$\$;
			SELECT '$label', '$name',
				round(percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)::numeric, 3),
				round(percentile_cont(0.5) WITHIN GROUP (ORDER BY plan_ms)::numeric, 3),
				min(node), max(indexes), max(rows)
			FROM runs;
		SQL
	done
}

echo "strategy,operation,rows,seconds,rows_per_sec,wal_bytes" > "$out/write.csv"
echo "strategy,query,exec_ms,plan_ms,scan_node,indexes,rows" > "$out/read.csv"
echo "strategy,indexes,index_bytes" > "$out/size.csv"

next=$((BASE_ROWS + 1))
for strategy in S G; do
	echo "== strategy $strategy: load $BASE_ROWS rows"
	load "$strategy"
	echo "$strategy,$(index_count),$(index_size)" >> "$out/size.csv"

	# reads first, on the freshly loaded table, with the default page costs
	# and with random_page_cost = 1.1 (SSD or data in memory)
	for rpc in 4 1.1; do
		if [ "$strategy" = S ]; then
			read_mix "S rpc=$rpc" "SET leapfrog.enabled = off; SET random_page_cost = $rpc;"
		else
			read_mix "G+L rpc=$rpc" "SET leapfrog.enabled = on; SET random_page_cost = $rpc;"
			read_mix "G rpc=$rpc" "SET leapfrog.enabled = off; SET random_page_cost = $rpc;"
		fi
	done
	if [ "$strategy" = G ]; then
		read_mix "G+L forced" "SET leapfrog.force = on;"
	fi

	measure "$strategy" insert "$BATCH_ROWS" "$(insert_rows "$next" $((next + BATCH_ROWS - 1)))"
	measure "$strategy" update_deleted_at "$QUARTER" \
		"UPDATE orders SET deleted_at = now() WHERE id IN (SELECT id FROM orders WHERE deleted_at IS NULL ORDER BY id LIMIT $QUARTER);"
	measure "$strategy" update_filter "$QUARTER" \
		"UPDATE orders SET f3 = (f3 + 1) % 100 WHERE id IN (SELECT id FROM orders ORDER BY id DESC LIMIT $QUARTER);"
	measure "$strategy" delete "$QUARTER" \
		"DELETE FROM orders WHERE id IN (SELECT id FROM orders ORDER BY id LIMIT $QUARTER OFFSET $QUARTER);"
done
$PSQL -c "DROP TABLE IF EXISTS orders"

echo
echo "Index size (excluding the primary key):"
column -t -s, "$out/size.csv"
echo
echo "Writes:"
column -t -s, "$out/write.csv"
echo
echo "Reads (median of $REPEATS):"
column -t -s, "$out/read.csv"
echo
echo "results: $out"
