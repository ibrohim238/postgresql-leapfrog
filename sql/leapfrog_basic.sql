--
-- leapfrog_basic
--
-- The index pair the extension is built for: (owner_id, id) plus a partial
-- (id) WHERE deleted_at IS NULL, and the mirror partial index for the
-- deleted rows.  Results are compared with the standard plans through
-- lf_check (EXCEPT ALL in both directions, plus the output order).
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_basic (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	kind_id bigint NOT NULL,
	deleted_at timestamptz,
	status integer NOT NULL,
	payload text
);

-- 20000 rows: 20 owners, every 7th row deleted, owner 19 never deleted,
-- owner 18 always deleted; rows are inserted out of id order so that the
-- heap order does not coincide with the sort order.
INSERT INTO lf_basic (id, owner_id, kind_id, deleted_at, status, payload)
SELECT g,
	g % 20,
	g % 3,
	CASE WHEN g % 20 = 18 OR (g % 7 = 0 AND g % 20 <> 19)
		THEN '2026-01-01'::timestamptz + g * interval '1 second' END,
	g % 13,
	'payload ' || g
FROM generate_series(1, 20000) g
ORDER BY (g * 7919) % 20000;

CREATE INDEX lf_basic_owner_id ON lf_basic (owner_id, id);
CREATE INDEX lf_basic_owner_kind_id ON lf_basic (owner_id, kind_id, id);
CREATE INDEX lf_basic_live_id ON lf_basic (id) WHERE deleted_at IS NULL;
CREATE INDEX lf_basic_deleted_id ON lf_basic (id) WHERE deleted_at IS NOT NULL;
CREATE INDEX lf_basic_live_low_status_id ON lf_basic (id)
	WHERE deleted_at IS NULL AND status < 10;
ANALYZE lf_basic;

-- On this small table the standard plan wins on cost (the cost-driven
-- choice is covered by leapfrog_explain) ...
SET leapfrog.force = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;

-- ... and the forced plan is the custom scan with both indexes named.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);

-- Disabled: the standard plan comes back, force has no effect.
SET leapfrog.enabled = off;
SET leapfrog.force = on;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;
RESET leapfrog.enabled;
RESET leapfrog.force;

-- ORDER BY ASC / DESC, with and without LIMIT
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id LIMIT 1 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 1 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);

-- LIMIT with OFFSET
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 OFFSET 50 $$);

-- Empty intersection: owner 19 has no deleted rows, owner 18 no live rows.
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 19 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 18 AND deleted_at IS NULL ORDER BY id DESC LIMIT 5 $$);

-- Full intersection: every row of owner 19 is live, of owner 18 deleted.
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 19 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 18 AND deleted_at IS NOT NULL ORDER BY id DESC $$);

-- No such owner
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 12345 AND deleted_at IS NULL ORDER BY id $$);

-- Early termination: LIMIT 1 reads a handful of entries, not the indexes.
SELECT * FROM lf_counters($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 1 $$);

-- Without LIMIT every entry of both sides is read, and only matches are
-- fetched from the heap.
SELECT * FROM lf_counters($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id $$);

-- Several equality columns: the three-column outer index.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NOT NULL ORDER BY id $$);

-- Equality with integer and smallint constants, and the column on the right
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5::integer AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5::smallint AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE 5 = owner_id AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);

-- Partial index with two conditions: the query implies the predicate
-- (status < 5 implies status < 10), the rows with status 5..9 that the
-- inner index holds are removed by the node's filter.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5 ORDER BY id DESC $$);
-- Predicate exactly equal to the query: no filter left.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 10
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 10 ORDER BY id LIMIT 20 $$);

-- Extra filter that neither index covers stays in the plan.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND payload LIKE '%45'
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND payload LIKE '%45' ORDER BY id LIMIT 20 $$);

-- Projection of a subset of columns and an expression
SELECT lf_check($$ SELECT id, upper(payload) FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- Aggregation over the scan
SELECT lf_check($$ SELECT count(*), sum(id) FROM (SELECT id FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id) s $$, false);

--
-- Cases that must NOT produce the custom scan, even when forced
--

-- No ORDER BY: no sort key to merge on.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL LIMIT 20 $$);

-- ORDER BY another column
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY status LIMIT 20 $$);

-- The predicate is not implied by the query.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND status < 20 ORDER BY id LIMIT 20 $$);

-- No equality on the outer index's leading column (range instead).
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id > 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- IN (...) is not an equality.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id IN (5, 6) AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- NULL constant: the clause is "owner_id = NULL", nothing can match; the
-- planner reduces it to a dummy result and the hook sees no base rel.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = NULL AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = NULL AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- Without the inner partial index there is no pair.
BEGIN;
DROP INDEX lf_basic_live_id;
DROP INDEX lf_basic_live_low_status_id;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
-- the mirror index still pairs for the deleted rows
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id LIMIT 20 $$);
ROLLBACK;

-- Without the outer index there is no pair either.
BEGIN;
DROP INDEX lf_basic_owner_id;
DROP INDEX lf_basic_owner_kind_id;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
ROLLBACK;

-- A DESC index column is rejected: the two streams would not agree.
BEGIN;
DROP INDEX lf_basic_owner_id;
DROP INDEX lf_basic_owner_kind_id;
CREATE INDEX lf_basic_owner_id_desc ON lf_basic (owner_id, id DESC);
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
ROLLBACK;

-- A nullable sort column is rejected, a non-bigint one as well.
CREATE TABLE lf_basic_nullable (id bigint, owner_id bigint NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_nullable (owner_id, id);
CREATE INDEX ON lf_basic_nullable (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_nullable WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
-- a NOT NULL constraint added NOT VALID does not count yet ...
ALTER TABLE lf_basic_nullable ADD CONSTRAINT lf_basic_nullable_id_notnull NOT NULL id NOT VALID;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_nullable WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
-- ... until it is validated.
ALTER TABLE lf_basic_nullable VALIDATE CONSTRAINT lf_basic_nullable_id_notnull;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_nullable WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_nullable;

CREATE TABLE lf_basic_int4 (id integer NOT NULL, owner_id bigint NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_int4 (owner_id, id);
CREATE INDEX ON lf_basic_int4 (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_int4 WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_int4;

-- A non-bigint equality column is rejected.
CREATE TABLE lf_basic_int4_owner (id bigint NOT NULL, owner_id integer NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_int4_owner (owner_id, id);
CREATE INDEX ON lf_basic_int4_owner (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_int4_owner WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_int4_owner;

-- A partitioned table and a view are left alone.
CREATE TABLE lf_basic_part (id bigint NOT NULL, owner_id bigint NOT NULL, deleted_at timestamptz)
	PARTITION BY HASH (id);
CREATE TABLE lf_basic_part_0 PARTITION OF lf_basic_part FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE lf_basic_part_1 PARTITION OF lf_basic_part FOR VALUES WITH (MODULUS 2, REMAINDER 1);
CREATE INDEX ON lf_basic_part (owner_id, id);
CREATE INDEX ON lf_basic_part (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_part WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_part;

CREATE VIEW lf_basic_view AS SELECT * FROM lf_basic WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_view WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic_view WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
DROP VIEW lf_basic_view;

DROP TABLE lf_basic;
