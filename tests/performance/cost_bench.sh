#!/usr/bin/env bash
# Cost model check: estimated cost against measured time, on skewed and
# correlated data.
#
# Table of ROWS rows:
#   customer_id   200 values, hashed (independent of everything else)
#   region        10 values, region = id / (ROWS / 10): follows the heap order
#   deleted_at    set for 10 % of the oldest 20 % of ids only (skewed)
#   archived      1.6 % of the rows, hashed (uniform)
# Indexes: (customer_id, id), (region, id), (id) WHERE deleted_at IS NOT
# NULL, (id) WHERE archived.
#
# Every query runs three ways: leapfrog on (the planner's choice), forced
# (the stock scans disabled, so that the node keeps its real estimate) and
# off (stock).  For each the estimated total cost of
# the top node and the median execution time over REPEATS runs are recorded,
# with the forced node's entries read.  The summary marks
#   miss    the forced node is more than 15 % faster than the planner's
#           choice, and the planner did not choose it
#   wrong   the planner chose the node and the stock plan is more than
#           15 % faster
#   bias    (node cost / node ms) / (stock cost / stock ms): above 1 the
#           node is overcosted relative to the stock plan, below 1
#           undercosted
#
# Environment: PGHOST/PGPORT/PGUSER/PGDATABASE; ROWS (1000000),
# REPEATS (5), RANDOM_PAGE_COST (4).
# Output: tests/performance/results/cost-<timestamp>/cost.csv and a summary.
set -euo pipefail

cd "$(dirname "$0")"

ROWS=${ROWS:-1000000}
REPEATS=${REPEATS:-5}
RANDOM_PAGE_COST=${RANDOM_PAGE_COST:-4}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="results/cost-$stamp"
mkdir -p "$out"
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

$PSQL -tAc "SELECT version()" > "$out/server.txt"
echo "random_page_cost=$RANDOM_PAGE_COST" >> "$out/server.txt"

$PSQL <<SQL
DROP TABLE IF EXISTS lf_cost_bench;
CREATE TABLE lf_cost_bench (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	region bigint NOT NULL,
	deleted_at timestamptz,
	archived boolean NOT NULL,
	payload text
) WITH (autovacuum_enabled = false);
INSERT INTO lf_cost_bench
SELECT g, abs(hashint8(g * 4 + 1)) % 200, (g - 1) / ($ROWS / 10),
	CASE WHEN g <= $ROWS / 5 AND abs(hashint8(g * 4 + 2)) % 10 = 0
		THEN '2026-01-01'::timestamptz END,
	abs(hashint8(g * 4 + 3)) % 64 = 0,
	repeat('x', 40)
FROM generate_series(1, $ROWS) g;
CREATE INDEX lf_cost_bench_customer_id ON lf_cost_bench (customer_id, id);
CREATE INDEX lf_cost_bench_region_id ON lf_cost_bench (region, id);
CREATE INDEX lf_cost_bench_deleted ON lf_cost_bench (id) WHERE deleted_at IS NOT NULL;
CREATE INDEX lf_cost_bench_archived ON lf_cost_bench (id) WHERE archived;
VACUUM ANALYZE lf_cost_bench;

CREATE OR REPLACE FUNCTION lf_cost_bench_run(query text, repeats int)
RETURNS TABLE (node boolean, cost numeric, ms numeric, outer_read bigint,
			   inner_read bigint, rows bigint)
LANGUAGE plpgsql AS \$\$
DECLARE
	plan jsonb;
	custom jsonb;
	times numeric[] := '{}';
BEGIN
	EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || query INTO plan;
	FOR i IN 1 .. repeats LOOP
		EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || query INTO plan;
		times := times || (plan -> 0 ->> 'Execution Time')::numeric;
	END LOOP;
	SELECT n INTO custom FROM jsonb_path_query(plan, 'strict \$[0].Plan.**') AS n
	WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect';
	node := custom IS NOT NULL;
	cost := (plan -> 0 -> 'Plan' ->> 'Total Cost')::numeric;
	ms := (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t)
		   FROM unnest(times) t)::numeric(10, 3);
	outer_read := (custom ->> 'Outer Entries Read')::bigint;
	inner_read := (custom ->> 'Inner Entries Read')::bigint;
	rows := (plan -> 0 -> 'Plan' ->> 'Actual Rows')::numeric::bigint;
	RETURN NEXT;
END
\$\$;
SQL

conditions=(
	"customer+deleted|customer_id = 7 AND deleted_at IS NOT NULL"
	"customer+archived|customer_id = 7 AND archived"
	"region0+deleted|region = 0 AND deleted_at IS NOT NULL"
	"region9+deleted|region = 9 AND deleted_at IS NOT NULL"
	"region9+customer|region = 9 AND customer_id = 7"
	"region5+archived|region = 5 AND archived"
)
orders=(
	"desc 10|ORDER BY id DESC LIMIT 10"
	"desc 100|ORDER BY id DESC LIMIT 100"
	"asc 100|ORDER BY id LIMIT 100"
	"all|ORDER BY id"
)

settings="LOAD 'leapfrog'; SET max_parallel_workers_per_gather = 0; SET random_page_cost = $RANDOM_PAGE_COST;"
echo "query,order,mode,node,cost,ms,outer_read,inner_read,rows" > "$out/cost.csv"
for c in "${conditions[@]}"; do
	for o in "${orders[@]}"; do
		query="SELECT * FROM lf_cost_bench WHERE ${c#*|} ${o#*|}"
		for mode in on force off; do
			case $mode in
				on) set_mode="" ;;
				# leapfrog.force scales the node's cost down; with the stock
				# scans disabled the node wins on disabled_nodes and keeps
				# its estimated cost
				force) set_mode="SET enable_seqscan = off; SET enable_indexscan = off; SET enable_indexonlyscan = off; SET enable_bitmapscan = off;" ;;
				off) set_mode="SET leapfrog.enabled = off;" ;;
			esac
			row=$($PSQL -tA -F, -c "$settings $set_mode SELECT * FROM lf_cost_bench_run(\$q\$$query\$q\$, $REPEATS)")
			echo "${c%%|*},${o%%|*},$mode,$row" >> "$out/cost.csv"
		done
	done
done

$PSQL -c "DROP TABLE lf_cost_bench; DROP FUNCTION lf_cost_bench_run(text, int)"

# summary: one line per query and order
$PSQL -P footer=off <<SQL
CREATE TEMP TABLE r (query text, ord text, mode text, node boolean, cost numeric,
	ms numeric, outer_read bigint, inner_read bigint, rows bigint);
\copy r FROM '$out/cost.csv' WITH (FORMAT csv, HEADER)
SELECT q.query, q.ord,
	o.node AS chosen,
	f.ms AS node_ms, s.ms AS stock_ms, o.ms AS chosen_ms,
	f.outer_read + f.inner_read AS node_entries,
	round(f.cost) AS node_cost, round(s.cost) AS stock_cost,
	round((f.cost / greatest(f.ms, 0.001)) / (s.cost / greatest(s.ms, 0.001)), 2) AS bias,
	CASE WHEN NOT o.node AND f.ms < o.ms / 1.15 THEN 'miss'
		 WHEN o.node AND s.ms < o.ms / 1.15 THEN 'wrong' ELSE '' END AS verdict
FROM (SELECT DISTINCT query, ord FROM r) q
JOIN r o ON o.query = q.query AND o.ord = q.ord AND o.mode = 'on'
JOIN r f ON f.query = q.query AND f.ord = q.ord AND f.mode = 'force'
JOIN r s ON s.query = q.query AND s.ord = q.ord AND s.mode = 'off'
ORDER BY q.query, q.ord;
SQL
echo "results: $out"
