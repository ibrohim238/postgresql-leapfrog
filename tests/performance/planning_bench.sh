#!/usr/bin/env bash
# Planning time against the number of indexes.
#
# For each N in INDEX_COUNTS a table with 50 bigint filter columns gets N
# indexes (fK, id) plus (id) WHERE deleted_at IS NULL.  Queries with 1, 2
# and 6 equalities ORDER BY id LIMIT 10 are planned REPEATS times with the
# extension on and off; the median planning time (EXPLAIN SUMMARY) is
# printed, and whether the plan under leapfrog.force has the node.
#
# Environment: PGHOST/PGPORT/PGUSER/PGDATABASE; INDEX_COUNTS ("10 20 50"),
# REPEATS (200).  The library must be preloaded or loadable by LOAD.
set -euo pipefail

INDEX_COUNTS=${INDEX_COUNTS:-"10 20 50"}
REPEATS=${REPEATS:-200}
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

columns=""
for k in $(seq 1 50); do
	columns+=", f$k bigint NOT NULL"
done

$PSQL <<SQL
DROP TABLE IF EXISTS lf_plan_bench;
CREATE TABLE lf_plan_bench (id bigint PRIMARY KEY, deleted_at timestamptz $columns);
INSERT INTO lf_plan_bench
SELECT g, CASE WHEN g % 10 = 0 THEN now() END
	$(for k in $(seq 1 50); do printf ', abs(hashint8(g * 64 + %d)) %% 100' "$k"; done)
FROM generate_series(1, 20000) g;
CREATE INDEX lf_plan_bench_live ON lf_plan_bench (id) WHERE deleted_at IS NULL;
ANALYZE lf_plan_bench;

CREATE OR REPLACE FUNCTION lf_plan_bench_median(query text, repeats int)
RETURNS numeric LANGUAGE plpgsql AS \$\$
DECLARE
	plan json;
	times numeric[] := '{}';
BEGIN
	FOR i IN 1 .. repeats LOOP
		EXECUTE 'EXPLAIN (SUMMARY, FORMAT JSON) ' || query INTO plan;
		times := times || (plan -> 0 ->> 'Planning Time')::numeric;
	END LOOP;
	RETURN (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t)
			FROM unnest(times) t)::numeric(10, 3);
END
\$\$;
SQL

queries=(
	"SELECT id FROM lf_plan_bench WHERE f1 = 1 AND deleted_at IS NULL ORDER BY id LIMIT 10"
	"SELECT id FROM lf_plan_bench WHERE f1 = 1 AND f2 = 2 AND deleted_at IS NULL ORDER BY id LIMIT 10"
	"SELECT id FROM lf_plan_bench WHERE f1 = 1 AND f2 = 2 AND f3 = 3 AND f4 = 4 AND f5 = 5 AND f6 = 6 AND deleted_at IS NULL ORDER BY id LIMIT 10"
)

printf '%-8s %-12s %12s %12s %10s\n' indexes equalities 'off, ms' 'on, ms' node
built=0
for n in $INDEX_COUNTS; do
	for k in $(seq $((built + 1)) "$n"); do
		$PSQL -c "CREATE INDEX lf_plan_bench_f${k}_id ON lf_plan_bench (f$k, id)"
	done
	built=$n
	for q in "${queries[@]}"; do
		equalities=$(grep -o ' = ' <<<"$q" | wc -l)
		off=$($PSQL -tAc "LOAD 'leapfrog'; SET leapfrog.enabled = off; SELECT lf_plan_bench_median(\$q\$$q\$q\$, $REPEATS)")
		on=$($PSQL -tAc "LOAD 'leapfrog'; SELECT lf_plan_bench_median(\$q\$$q\$q\$, $REPEATS)")
		node=$($PSQL -tAc "LOAD 'leapfrog'; SET leapfrog.force = on; EXPLAIN (COSTS OFF) $q" | grep -c 'Index Merge Intersect' || true)
		printf '%-8s %-12s %12s %12s %10s\n' "$n" "$equalities" "$off" "$on" "$node"
	done
done

$PSQL -c "DROP TABLE lf_plan_bench; DROP FUNCTION lf_plan_bench_median(text, int)"
