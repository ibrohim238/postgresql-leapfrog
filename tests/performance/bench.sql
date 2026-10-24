-- Helper that runs one query several times with EXPLAIN (ANALYZE, BUFFERS,
-- FORMAT JSON) and returns one row per repetition with the metrics the
-- benchmark records.  Lives in the benchmark database only.
\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION bench_run(
	query text,
	repeats integer,
	warmup integer DEFAULT 1,
	OUT run integer,
	OUT plan_node text,
	OUT exec_ms numeric,
	OUT plan_ms numeric,
	OUT shared_hit bigint,
	OUT shared_read bigint,
	OUT rows_out numeric,
	OUT outer_read bigint,
	OUT inner_read bigint,
	OUT heap_fetches bigint,
	OUT rows_removed bigint,
	OUT plan_json jsonb)
RETURNS SETOF record
LANGUAGE plpgsql AS $$
DECLARE
	i integer;
	j jsonb;
	scan jsonb;
BEGIN
	FOR i IN 1 .. warmup LOOP
		EXECUTE query;
	END LOOP;

	FOR i IN 1 .. repeats LOOP
		EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) ' || query INTO j;
		j := j->0;

		-- the scan node on orders: the deepest node naming the table
		SELECT n INTO scan
		FROM jsonb_path_query(j, 'strict $.Plan.**') AS n
		WHERE n->>'Relation Name' = 'orders'
		ORDER BY (n->>'Node Type' = 'Custom Scan') DESC
		LIMIT 1;

		run := i;
		plan_node := coalesce(scan->>'Custom Plan Provider',
			scan->>'Node Type' || coalesce(' ' || (scan->>'Index Name'), ''));
		exec_ms := (j->>'Execution Time')::numeric;
		plan_ms := (j->>'Planning Time')::numeric;
		shared_hit := (j->'Plan'->>'Shared Hit Blocks')::bigint;
		shared_read := (j->'Plan'->>'Shared Read Blocks')::bigint;
		rows_out := (j->'Plan'->>'Actual Rows')::numeric;
		outer_read := (scan->>'Outer Entries Read')::bigint;
		inner_read := (scan->>'Inner Entries Read')::bigint;
		heap_fetches := (scan->>'Heap Fetches')::bigint;
		rows_removed := (scan->>'Rows Removed by Filter')::bigint;
		plan_json := j;
		RETURN NEXT;
	END LOOP;
END
$$;

-- Picks owners for the query mix: the biggest, a median one, a small one.
-- plpgsql, so that the function can be created before the table exists.
-- Dropped first: CREATE OR REPLACE cannot change the result columns of a
-- version left over from an older run.
DROP FUNCTION IF EXISTS bench_owners();
CREATE FUNCTION bench_owners()
RETURNS TABLE (label text, customer_id bigint, total bigint, deleted bigint)
LANGUAGE plpgsql AS $$
BEGIN
	RETURN QUERY
	WITH per_owner AS (
		SELECT s.customer_id, count(*) AS total,
			count(*) FILTER (WHERE s.deleted_at IS NOT NULL) AS deleted
		FROM orders s GROUP BY s.customer_id
	), ranked AS (
		SELECT *, row_number() OVER (ORDER BY per_owner.total DESC) AS rn, count(*) OVER () AS n
		FROM per_owner
	)
	SELECT 'large'::text, ranked.customer_id, ranked.total, ranked.deleted FROM ranked WHERE rn = 1
	UNION ALL
	SELECT 'median'::text, ranked.customer_id, ranked.total, ranked.deleted FROM ranked WHERE rn = (n + 1) / 2
	UNION ALL
	SELECT 'small'::text, ranked.customer_id, ranked.total, ranked.deleted FROM ranked WHERE rn = n;
END
$$;
