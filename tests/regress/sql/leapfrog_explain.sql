-- leapfrog_explain: EXPLAIN output in every format, the counters, the cost model components
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;
-- heap prefetch depends on it, in the counters below
SET effective_io_concurrency = 16;

CREATE TABLE lf_explain (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
INSERT INTO lf_explain (id, owner_id, deleted_at, payload)
SELECT g, g % 4, CASE WHEN g % 2 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
FROM generate_series(1, 8000) g;
CREATE INDEX lf_explain_owner_id ON lf_explain (owner_id, id);
CREATE INDEX lf_explain_live_id ON lf_explain (id) WHERE deleted_at IS NULL;
ANALYZE lf_explain;

SET leapfrog.force = on;

EXPLAIN (COSTS OFF)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

EXPLAIN (COSTS OFF, VERBOSE)
SELECT id FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

-- Every stream is a block of its own, like a child node.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;
-- In the structured formats the streams are an array
CREATE FUNCTION lf_plan_streams(query text) RETURNS SETOF jsonb
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('leapfrog.force', 'on', true);
	EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF, FORMAT JSON) ' ||
		query INTO plan;
	RETURN QUERY
		SELECT s FROM jsonb_path_query(plan, 'strict $[0].Plan.**') AS n,
			jsonb_array_elements(n -> 'Index Streams') AS s
		WHERE n ->> 'Custom Plan Provider' = 'Index Merge Intersect';
END
$$;
SELECT s ->> 'Role' AS role, s ->> 'Index Name' AS index, s ->> 'Index Cond' AS cond,
	s ->> 'Index Pred' AS pred, s ? 'Entries Read' AS counted
FROM lf_plan_streams($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$) s;
-- leapfrog.prefetch: leaf pages prefetched per stream; the result does not depend on it.
SHOW leapfrog.prefetch;
SELECT s ->> 'Role' AS role, (s ->> 'Prefetches')::int > 0 AS prefetched
FROM lf_plan_streams($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC $$) s;
SET leapfrog.prefetch = off;
SELECT s ->> 'Role' AS role, s ? 'Prefetches' AS prefetched
FROM lf_plan_streams($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC $$) s;
SELECT lf_check($$ SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);
RESET leapfrog.prefetch;
DROP FUNCTION lf_plan_streams(text);

-- VERBOSE with costs: the entries the cost model expects each side to read.
CREATE FUNCTION lf_plan_verbose(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
BEGIN
	PERFORM set_config('leapfrog.force', 'on', true);
	FOR line IN EXECUTE 'EXPLAIN (VERBOSE) ' || query LOOP
		RETURN NEXT regexp_replace(line, '\d+(\.\d+)?', 'N', 'g');
	END LOOP;
END
$$;
SELECT * FROM lf_plan_verbose($$
SELECT id FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$)
WHERE lf_plan_verbose ~ 'Entries Estimated';
-- not without VERBOSE, not with COSTS OFF
SELECT count(*) FROM lf_plan_costs($$
SELECT id FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$)
WHERE lf_plan_costs ~ 'Estimated';
DROP FUNCTION lf_plan_verbose(text);

-- Costs without force; the standard plan is cheaper here (a match every few rows).
SELECT * FROM lf_plan_costs($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);

-- The node and the stock plan are estimated within 1 %: the planner's pick is not checked.
CREATE TABLE lf_explain_cost (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
INSERT INTO lf_explain_cost (id, owner_id, deleted_at, payload)
SELECT g, g % 50, CASE WHEN g % 2500 < 50 THEN '2026-01-01'::timestamptz END, repeat('x', 400)
FROM generate_series(1, 50000) g;
CREATE INDEX lf_explain_cost_owner_id ON lf_explain_cost (owner_id, id);
CREATE INDEX lf_explain_cost_deleted_id ON lf_explain_cost (id) WHERE deleted_at IS NOT NULL;
VACUUM ANALYZE lf_explain_cost;
SET leapfrog.force = off;
SELECT lf_check($$ SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10 $$);
-- Without LIMIT BitmapAnd is competitive; the result is the same either way.
SELECT lf_check($$ SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id $$);
SET leapfrog.enabled = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10;
RESET leapfrog.enabled;
DROP TABLE lf_explain_cost;

-- Cost model components: two estimates that differ in one input; only the direction is checked.
-- lf_node_cost: competing scans disabled instead of leapfrog.force, which zeroes the cost.
CREATE FUNCTION lf_node_cost(query text) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('leapfrog.enabled', 'on', true);
	PERFORM set_config('leapfrog.force', 'off', true);
	PERFORM set_config('enable_seqscan', 'off', true);
	PERFORM set_config('enable_indexscan', 'off', true);
	PERFORM set_config('enable_indexonlyscan', 'off', true);
	PERFORM set_config('enable_bitmapscan', 'off', true);
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	RETURN (SELECT (n->>'Total Cost')::float8
			FROM jsonb_path_query(plan, 'strict $[0].Plan.**') AS n
			WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect');
END
$$;

CREATE TABLE lf_cost_sorted (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
INSERT INTO lf_cost_sorted
SELECT g, g % 50, CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, repeat('x', 200)
FROM generate_series(1, 50000) g;
CREATE INDEX ON lf_cost_sorted (owner_id, id);
CREATE INDEX ON lf_cost_sorted (id) WHERE deleted_at IS NULL;
-- the same rows in shuffled heap order
CREATE TABLE lf_cost_shuffled (LIKE lf_cost_sorted INCLUDING ALL);
INSERT INTO lf_cost_shuffled SELECT * FROM lf_cost_sorted ORDER BY (id * 7919) % 50000;
VACUUM ANALYZE lf_cost_sorted;
VACUUM ANALYZE lf_cost_shuffled;

-- Heap fetches are charged by the correlation of owner_id; only that statistic
-- changes (pg_restore_attribute_stats), so sizes and row estimates are identical.
SELECT pg_restore_attribute_stats('schemaname', 'public', 'relname', 'lf_cost_sorted',
	'attname', 'owner_id', 'inherited', false, 'correlation', 1.0::real);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	AS correlated_cost \gset
SELECT pg_restore_attribute_stats('schemaname', 'public', 'relname', 'lf_cost_sorted',
	'attname', 'owner_id', 'inherited', false, 'correlation', 0.0::real);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	> :correlated_cost AS correlated_heap_is_cheaper;
ANALYZE lf_cost_sorted;

-- The node's filter is costed per row.
CREATE FUNCTION lf_costly(text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE COST 10000 AS $$ BEGIN RETURN true; END $$;
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL AND lf_costly(payload) ORDER BY id $$)
	 > lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$) + 1000
	AS filter_cost_is_counted;

-- Page costs come from the tablespace: one of the test's own, named after the database.
-- One left by an interrupted run (owner and comment) is dropped; any other stops the test.
SELECT s.name AS lf_space,
	coalesce(t.mine, false) AS lf_space_left,
	NOT coalesce(t.mine, true) AS lf_space_taken
FROM (SELECT left('lf_space_' || current_database(), 63) AS name) s
LEFT JOIN LATERAL (SELECT pg_get_userbyid(spcowner) = current_user
		AND shobj_description(oid, 'pg_tablespace') IS NOT DISTINCT FROM
			'leapfrog regression test' AS mine
	FROM pg_tablespace WHERE spcname = s.name) t ON true \gset
\if :lf_space_taken
\echo tablespace :lf_space is not owned and marked by this test, stopping
\quit
\elif :lf_space_left
DROP TABLE IF EXISTS lf_cost_spaced;
DROP TABLESPACE :"lf_space";
\endif
SET allow_in_place_tablespaces = on;
CREATE TABLESPACE :"lf_space" LOCATION '';
RESET allow_in_place_tablespaces;
COMMENT ON TABLESPACE :"lf_space" IS 'leapfrog regression test';
SET default_tablespace = :"lf_space";
CREATE TABLE lf_cost_spaced (LIKE lf_cost_shuffled INCLUDING ALL);
RESET default_tablespace;
INSERT INTO lf_cost_spaced SELECT * FROM lf_cost_shuffled;
VACUUM ANALYZE lf_cost_spaced;
SELECT lf_node_cost($$ SELECT * FROM lf_cost_spaced WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	AS default_cost \gset
ALTER TABLESPACE :"lf_space" SET (random_page_cost = 40);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_spaced WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	 > :default_cost * 2 AS tablespace_page_cost_is_used;
DROP TABLE lf_cost_spaced;
DROP TABLESPACE :"lf_space";

-- A parameterized rescan rereads cached pages: cheaper per loop.
-- OFFSET 0 makes the outer row estimate the loop count.
SELECT lf_node_cost($$
SELECT v.o, s.id
FROM (SELECT g::bigint AS o FROM generate_series(1, 5000) g OFFSET 0) v
	JOIN lf_cost_shuffled s ON s.owner_id = v.o AND s.deleted_at IS NULL
ORDER BY s.id $$)
	 < lf_node_cost($$
SELECT v.o, s.id
FROM (SELECT 7::bigint AS o OFFSET 0) v
	JOIN lf_cost_shuffled s ON s.owner_id = v.o AND s.deleted_at IS NULL
ORDER BY s.id $$)
	AS repeated_scans_are_cheaper_per_loop;

-- Stream ranges probed at plan time: owner 3 (ids <= 50,000) cannot meet the
-- archived ids (> 60,000). A generic plan cannot probe.
CREATE TABLE lf_cost_range (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	archived boolean NOT NULL
);
INSERT INTO lf_cost_range
SELECT g, CASE WHEN g <= 50000 THEN g % 10 ELSE 10 + g % 10 END, g > 60000 AND g % 3 = 0
FROM generate_series(1, 100000) g;
CREATE INDEX lf_cost_range_owner_id ON lf_cost_range (owner_id, id);
CREATE INDEX lf_cost_range_archived_id ON lf_cost_range (id) WHERE archived;
ANALYZE lf_cost_range;
PREPARE lf_range(bigint) AS
	SELECT * FROM lf_cost_range WHERE owner_id = $1 AND archived ORDER BY id;
SET plan_cache_mode = force_generic_plan;
SELECT lf_node_cost($$ SELECT * FROM lf_cost_range WHERE owner_id = 3 AND archived ORDER BY id $$) * 10
	 < lf_node_cost($$ EXECUTE lf_range(3) $$)
	AS disjoint_ranges_are_cheap;
-- An owner without rows: the stream is empty.
SELECT lf_node_cost($$ SELECT * FROM lf_cost_range WHERE owner_id = 99 AND archived ORDER BY id $$) * 10
	 < lf_node_cost($$ EXECUTE lf_range(99) $$)
	AS empty_stream_is_cheap;
-- Owner 13 (ids above 50,000) meets the archived rows: no discount.
SELECT lf_node_cost($$ SELECT * FROM lf_cost_range WHERE owner_id = 13 AND archived ORDER BY id $$)
	 > lf_node_cost($$ SELECT * FROM lf_cost_range WHERE owner_id = 3 AND archived ORDER BY id $$) * 10
	AS overlapping_ranges_are_not_discounted;
-- The node's rows are the matches inside the overlap (1,334), twice the relation's estimate.
CREATE FUNCTION lf_node_rows(query text) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('enable_seqscan', 'off', true);
	PERFORM set_config('enable_indexscan', 'off', true);
	PERFORM set_config('enable_indexonlyscan', 'off', true);
	PERFORM set_config('enable_bitmapscan', 'off', true);
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	RETURN (SELECT (n->>'Plan Rows')::float8
			FROM jsonb_path_query(plan, 'strict $[0].Plan.**') AS n
			WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect');
END
$$;
SELECT lf_node_rows($$ SELECT * FROM lf_cost_range WHERE owner_id = 13 AND archived ORDER BY id $$)
	BETWEEN 1200 AND 1500 AS rows_are_the_matches,
	lf_node_rows($$ EXECUTE lf_range(13) $$) < 1000 AS generic_plan_keeps_the_estimate;
DROP FUNCTION lf_node_rows(text);
RESET plan_cache_mode;
DEALLOCATE lf_range;

-- Two ordinary indexes against BitmapAnd: TID comparisons are charged at the bitmap's
-- per-TID rate. 25,000 rows: ANALYZE samples every row.
CREATE FUNCTION lf_stock_cost(query text) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('leapfrog.enabled', 'off', true);
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	RETURN (plan -> 0 -> 'Plan' ->> 'Total Cost')::float8;
END
$$;
CREATE TABLE lf_cost_pair (
	id bigint PRIMARY KEY,
	a bigint NOT NULL,
	b bigint NOT NULL,
	payload text
);
INSERT INTO lf_cost_pair
SELECT g, abs(hashint8(g * 8 + 1)) % 20, abs(hashint8(g * 8 + 2)) % 20, repeat('x', 40)
FROM generate_series(1, 25000) g;
CREATE INDEX lf_cost_pair_a ON lf_cost_pair (a, id);
CREATE INDEX lf_cost_pair_b ON lf_cost_pair (b, id);
VACUUM ANALYZE lf_cost_pair;
SET random_page_cost = 1.1;
SET leapfrog.enabled = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_cost_pair WHERE a = 7 AND b = 12 ORDER BY id;
RESET leapfrog.enabled;
SELECT lf_node_cost($$ SELECT * FROM lf_cost_pair WHERE a = 7 AND b = 12 ORDER BY id $$)
	 < lf_stock_cost($$ SELECT * FROM lf_cost_pair WHERE a = 7 AND b = 12 ORDER BY id $$)
	AS pair_cheaper_than_bitmapand;
SELECT lf_check($$ SELECT * FROM lf_cost_pair WHERE a = 7 AND b = 12 ORDER BY id $$);
RESET random_page_cost;
DROP TABLE lf_cost_pair;
DROP FUNCTION lf_stock_cost(text);
SELECT lf_check($$ SELECT * FROM lf_cost_range WHERE owner_id = 3 AND archived ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_cost_range WHERE owner_id = 13 AND archived ORDER BY id DESC $$);
DROP TABLE lf_cost_range;

DROP FUNCTION lf_costly(text);
DROP TABLE lf_cost_sorted;
DROP TABLE lf_cost_shuffled;
DROP FUNCTION lf_node_cost(text);

SET leapfrog.force = on;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

-- Owner 1: odd ids, all live.
SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);

-- Owner 0: even ids, none live: nothing matches.
SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 0 AND deleted_at IS NULL ORDER BY id $$);

SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL AND payload LIKE '%5' ORDER BY id LIMIT 10 $$);

EXPLAIN (COSTS OFF, FORMAT JSON)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;
EXPLAIN (COSTS OFF, FORMAT YAML)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF, FORMAT XML)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

-- Without ANALYZE the scans do not start: no counters.
EXPLAIN (COSTS OFF, FORMAT JSON)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM lf_explain WHERE owner_id = 9 AND deleted_at IS NULL ORDER BY id LIMIT 1;

RESET leapfrog.force;
DROP TABLE lf_explain;
