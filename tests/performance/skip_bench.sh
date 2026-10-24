#!/usr/bin/env bash
# Skip-ahead threshold benchmark.
#
# One table of ROWS rows with two filter columns, a (2 values, 50 %) and
# b (100 values, 1 %), and four partial indexes on id: deleted rows spread
# uniformly (1 %), and deleted rows in clusters of 20 ids every 2,000,
# 20,000 and 200,000 ids (gaps short, medium and long).  Each query
# intersects (a, id) or (b, id) with one of them under leapfrog.force, at
# every starting threshold in THRESHOLDS (leapfrog.skip_after; 0 = no
# skipping; the executor adapts it per side from there), and records the shared
# buffers the plan touched (and of them read from outside shared buffers),
# the index entries read, the skips and the median execution time over
# REPEATS runs after a warm-up.
#
# Cold cache: with COLD_CMD set, that command runs before every measurement
# and the query runs once, without a warm-up.  It must empty both caches:
# restart the server (shared buffers) and drop the OS page cache, which needs
# root on the machine the data lives on, for example
#
#   COLD_CMD='docker compose restart postgres &&
#             sudo sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"' \
#     bash tests/performance/skip_bench.sh
#
# The script waits for the server (pg_isready) after the command.
#
# Environment: PGHOST/PGPORT/PGUSER/PGDATABASE; ROWS (1000000), THRESHOLDS
# ("0 128 256 512 1024 2048"), REPEATS (5), COLD_CMD (unset).
# Output: tests/performance/results/skip-<timestamp>/skip.csv and a summary
# on stdout.
set -euo pipefail

cd "$(dirname "$0")"

ROWS=${ROWS:-1000000}
THRESHOLDS=${THRESHOLDS:-"0 128 256 512 1024 2048"}
REPEATS=${REPEATS:-5}
COLD_CMD=${COLD_CMD:-}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="results/skip-$stamp"
mkdir -p "$out"
export PGOPTIONS="-c client_min_messages=warning"
PSQL="psql -X -q -v ON_ERROR_STOP=1"

$PSQL -tAc "SELECT version()" > "$out/server.txt"

$PSQL <<SQL
DROP TABLE IF EXISTS lf_skip_bench;
CREATE TABLE lf_skip_bench (
	id bigint PRIMARY KEY,
	a bigint NOT NULL,
	b bigint NOT NULL,
	del_u boolean NOT NULL,
	del_s boolean NOT NULL,
	del_m boolean NOT NULL,
	del_l boolean NOT NULL
) WITH (autovacuum_enabled = false);
INSERT INTO lf_skip_bench
SELECT g, abs(hashint8(g * 4 + 1)) % 2, abs(hashint8(g * 4 + 2)) % 100,
	abs(hashint8(g * 4 + 3)) % 100 = 0,
	g % 2000 < 20, g % 20000 < 20, g % 200000 < 20
FROM generate_series(1, $ROWS) g;
CREATE INDEX lf_skip_bench_a_id ON lf_skip_bench (a, id);
CREATE INDEX lf_skip_bench_b_id ON lf_skip_bench (b, id);
CREATE INDEX lf_skip_bench_u ON lf_skip_bench (id) WHERE del_u;
CREATE INDEX lf_skip_bench_s ON lf_skip_bench (id) WHERE del_s;
CREATE INDEX lf_skip_bench_m ON lf_skip_bench (id) WHERE del_m;
CREATE INDEX lf_skip_bench_l ON lf_skip_bench (id) WHERE del_l;
VACUUM ANALYZE lf_skip_bench;

CREATE OR REPLACE FUNCTION lf_skip_bench_run(query text, repeats int, warm boolean)
RETURNS TABLE (buffers bigint, read bigint, outer_read bigint,
			   inner_read bigint, skips bigint, rows bigint, ms numeric)
LANGUAGE plpgsql AS \$\$
DECLARE
	plan jsonb;
	node jsonb;
	times numeric[] := '{}';
BEGIN
	IF warm THEN
		EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query INTO plan;
	END IF;
	FOR i IN 1 .. repeats LOOP
		EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || query INTO plan;
		times := times || (plan -> 0 ->> 'Execution Time')::numeric;
	END LOOP;
	SELECT n INTO node FROM jsonb_path_query(plan, 'strict \$[0].Plan.**') AS n
	WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect';
	IF node IS NULL THEN
		RAISE EXCEPTION 'no Index Merge Intersect in the plan of %', query;
	END IF;
	buffers := (plan -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint +
		(plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
	read := (plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint;
	outer_read := (node ->> 'Outer Entries Read')::bigint;
	inner_read := (node ->> 'Inner Entries Read')::bigint;
	skips := coalesce((node ->> 'Skips')::bigint, 0);
	rows := (plan -> 0 -> 'Plan' ->> 'Actual Rows')::numeric::bigint;
	ms := (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t)
		   FROM unnest(times) t)::numeric(10, 3);
	RETURN NEXT;
END
\$\$;
SQL

# name|query
queries=(
	"a+uniform|SELECT id FROM lf_skip_bench WHERE a = 1 AND del_u ORDER BY id"
	"a+short|SELECT id FROM lf_skip_bench WHERE a = 1 AND del_s ORDER BY id"
	"a+medium|SELECT id FROM lf_skip_bench WHERE a = 1 AND del_m ORDER BY id"
	"a+long|SELECT id FROM lf_skip_bench WHERE a = 1 AND del_l ORDER BY id"
	"a+medium limit|SELECT id FROM lf_skip_bench WHERE a = 1 AND del_m ORDER BY id DESC LIMIT 100"
	"b+uniform|SELECT id FROM lf_skip_bench WHERE b = 1 AND del_u ORDER BY id"
	"b+short|SELECT id FROM lf_skip_bench WHERE b = 1 AND del_s ORDER BY id"
	"b+medium|SELECT id FROM lf_skip_bench WHERE b = 1 AND del_m ORDER BY id"
	"b+long|SELECT id FROM lf_skip_bench WHERE b = 1 AND del_l ORDER BY id"
)

repeats=$REPEATS
warm=true
if [ -n "$COLD_CMD" ]; then
	repeats=1
	warm=false
	echo "cold cache: $COLD_CMD" >> "$out/server.txt"
fi

# empty the caches and wait until the server accepts connections again
make_cold() {
	bash -c "$COLD_CMD"
	until pg_isready -q; do
		sleep 1
	done
}

echo "query,threshold,buffers,read,outer_read,inner_read,skips,rows,ms" > "$out/skip.csv"
for entry in "${queries[@]}"; do
	name=${entry%%|*}
	query=${entry#*|}
	for t in $THRESHOLDS; do
		if [ -n "$COLD_CMD" ]; then
			make_cold
		fi
		row=$($PSQL -tA -F, -c "LOAD 'leapfrog'; SET max_parallel_workers_per_gather = 0; SET leapfrog.force = on; SET leapfrog.skip_after = $t; SELECT * FROM lf_skip_bench_run(\$q\$$query\$q\$, $repeats, $warm)")
		echo "$name,$t,$row" >> "$out/skip.csv"
	done
done

$PSQL -c "DROP TABLE lf_skip_bench; DROP FUNCTION lf_skip_bench_run(text, int, boolean)"

column -s, -t "$out/skip.csv"
echo "results: $out"
