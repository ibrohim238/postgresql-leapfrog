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
