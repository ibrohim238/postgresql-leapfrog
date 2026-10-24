--
-- leapfrog_explain
--
-- EXPLAIN output of the node in every format and the instrumentation of
-- EXPLAIN ANALYZE.
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

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

-- Costs are present without force (numbers masked).  Here the standard
-- plan is cheaper: half of the rows are live and every fourth belongs to
-- the owner, a plain index scan finds a match every few rows.
SELECT * FROM lf_plan_costs($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);

-- The case the node is built for: the owner holds 2% of the rows and 2%
-- of the rows are deleted, independently, and the rows are wide enough
-- that every fetched row costs a heap page.  Either standard index scan
-- discards 49 of 50 fetched rows, BitmapAnd has to read both indexes
-- completely and sort; the intersection wins on cost without force.
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
EXPLAIN (COSTS OFF)
SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10;
SELECT * FROM lf_plan_costs($$
SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10 $$);
-- Without LIMIT the whole result is needed and BitmapAnd is competitive;
-- whichever wins, the result is the same.
SELECT lf_check($$ SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id $$);
-- With leapfrog disabled the standard plan is back.
SET leapfrog.enabled = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_explain_cost WHERE owner_id = 7 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 10;
RESET leapfrog.enabled;
DROP TABLE lf_explain_cost;

--
-- Cost model components.  Each check compares the node's estimated total
-- cost in two situations that differ in one input of the model only; the
-- numbers themselves are not pinned, only the direction.
--
-- lf_node_cost(query): total cost of the Index Merge Intersect node in the
-- plan, with every competing scan disabled so that the node is planned
-- without leapfrog.force (which would zero its cost).
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

-- Heap fetches follow the sort column: a heap in that order is cheaper.
-- Only the correlation statistic changes between the two estimates, on the
-- same table (pg_restore_attribute_stats), so that the index sizes and row
-- estimates are identical.
SELECT pg_restore_attribute_stats('schemaname', 'public', 'relname', 'lf_cost_sorted',
	'attname', 'id', 'inherited', false, 'correlation', 1.0::real);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	AS correlated_cost \gset
SELECT pg_restore_attribute_stats('schemaname', 'public', 'relname', 'lf_cost_sorted',
	'attname', 'id', 'inherited', false, 'correlation', 0.0::real);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	> :correlated_cost AS correlated_heap_is_cheaper;
ANALYZE lf_cost_sorted;

-- The node's filter is costed per row.
CREATE FUNCTION lf_costly(text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE COST 10000 AS $$ BEGIN RETURN true; END $$;
SELECT lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL AND lf_costly(payload) ORDER BY id $$)
	 > lf_node_cost($$ SELECT * FROM lf_cost_sorted WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$) + 1000
	AS filter_cost_is_counted;

-- Page costs come from the tablespace of the table and the indexes.
SELECT lf_node_cost($$ SELECT * FROM lf_cost_shuffled WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	AS default_cost \gset
ALTER TABLESPACE pg_default SET (random_page_cost = 40);
SELECT lf_node_cost($$ SELECT * FROM lf_cost_shuffled WHERE owner_id = 7 AND deleted_at IS NULL ORDER BY id $$)
	 > :default_cost * 2 AS tablespace_page_cost_is_used;
ALTER TABLESPACE pg_default RESET (random_page_cost);

-- A path parameterized by a join column is rescanned once per outer row;
-- the same index and heap pages are read again and stay cached, so the
-- per-loop cost falls with the loop count.  (A LATERAL subquery with its
-- own LIMIT gets an outer-level Param instead and is not parameterized.)
-- OFFSET 0 keeps the outer side a subquery, so its row estimate is the
-- loop count.
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

DROP FUNCTION lf_costly(text);
DROP TABLE lf_cost_sorted;
DROP TABLE lf_cost_shuffled;
DROP FUNCTION lf_node_cost(text);

SET leapfrog.force = on;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

-- Owner 1 has odd ids only, all of them live: LIMIT 10 reads 10 outer
-- entries and about 20 inner ones, matches and fetches 10.
SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);

-- Owner 0 has even ids only, none of them live: the whole owner is read,
-- nothing matches, nothing is fetched.
SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 0 AND deleted_at IS NULL ORDER BY id $$);

-- A filter removes rows after the fetch.
SELECT * FROM lf_counters($$
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL AND payload LIKE '%5' ORDER BY id LIMIT 10 $$);

-- JSON, YAML and XML formats carry the same properties.
EXPLAIN (COSTS OFF, FORMAT JSON)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;
EXPLAIN (COSTS OFF, FORMAT YAML)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF, FORMAT XML)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10;

-- EXPLAIN without ANALYZE does not start the scans (EXEC_FLAG_EXPLAIN_ONLY)
-- and reports no counters.
EXPLAIN (COSTS OFF, FORMAT JSON)
SELECT * FROM lf_explain WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1;

-- EXPLAIN ANALYZE of a query that returns nothing
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
SELECT * FROM lf_explain WHERE owner_id = 9 AND deleted_at IS NULL ORDER BY id LIMIT 1;

RESET leapfrog.force;
DROP TABLE lf_explain;
