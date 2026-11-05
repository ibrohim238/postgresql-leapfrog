-- leapfrog_basic: the index pair the extension is built for, (owner_id, id) + partial (id)
-- alternative output leapfrog_basic_1.out: PostgreSQL 19 prints "Replaces:" under a dummy Result; remove when PostgreSQL 19 is the oldest supported version
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

-- Owner 19 is never deleted, owner 18 always; out of id order, so heap order is not sort order.
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

-- On this small table the standard plan wins on cost; forced, the custom scan.
SET leapfrog.force = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;

SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);

-- Disabled: force has no effect.
SET leapfrog.enabled = off;
SET leapfrog.force = on;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100;
RESET leapfrog.enabled;
RESET leapfrog.force;

SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id LIMIT 1 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 1 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);

SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 OFFSET 50 $$);

-- Empty intersections
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 19 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 18 AND deleted_at IS NULL ORDER BY id DESC LIMIT 5 $$);

-- Full intersections
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 19 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 18 AND deleted_at IS NOT NULL ORDER BY id DESC $$);

SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 12345 AND deleted_at IS NULL ORDER BY id $$);

-- LIMIT 1 reads a handful of entries, not the indexes.
SELECT * FROM lf_counters($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 1 $$);

-- Without LIMIT only the matches are fetched from the heap.
SELECT * FROM lf_counters($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NOT NULL
ORDER BY id $$);

-- The three-column outer index
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND kind_id = 2 AND deleted_at IS NOT NULL ORDER BY id $$);

SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5::integer AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5::smallint AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE 5 = owner_id AND deleted_at IS NULL ORDER BY id LIMIT 10 $$);

-- Predicate implied (status < 5 => status < 10): the node filters status 5..9.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 5 ORDER BY id DESC $$);
-- Predicate equal to the query: no filter left.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 10
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND status < 10 ORDER BY id LIMIT 20 $$);

SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND payload LIKE '%45'
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL AND payload LIKE '%45' ORDER BY id LIMIT 20 $$);

SELECT lf_check($$ SELECT id, upper(payload) FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

SELECT lf_check($$ SELECT count(*), sum(id) FROM (SELECT id FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id) s $$, false);

-- Cases that must NOT produce the custom scan, even when forced

SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL LIMIT 20 $$);

SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY status LIMIT 20 $$);

-- The predicate is not implied by the query.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id = 5 AND status < 20 ORDER BY id LIMIT 20 $$);

SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id > 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- IN (...) is not an equality.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic WHERE owner_id IN (5, 6) AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- owner_id = NULL: reduced to a dummy result, the hook sees no base rel.
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

-- A nullable sort column: NULLs are values of the merge (more in leapfrog_nulls).
CREATE TABLE lf_basic_nullable (id bigint, owner_id bigint NOT NULL, deleted_at timestamptz);
INSERT INTO lf_basic_nullable SELECT CASE WHEN g % 5 = 0 THEN NULL ELSE g END, g % 3, NULL
FROM generate_series(1, 300) g;
CREATE INDEX ON lf_basic_nullable (owner_id, id);
CREATE INDEX ON lf_basic_nullable (id) WHERE deleted_at IS NULL;
ANALYZE lf_basic_nullable;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_nullable WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT owner_id, id FROM lf_basic_nullable WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id $$);
-- a NOT NULL constraint added NOT VALID does not count: its NULLs are still rows
ALTER TABLE lf_basic_nullable ADD CONSTRAINT lf_basic_nullable_id_notnull NOT NULL id NOT VALID;
SELECT lf_check($$ SELECT owner_id, id FROM lf_basic_nullable WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id $$);
SELECT count(*) AS null_rows FROM lf_basic_nullable WHERE id IS NULL;
UPDATE lf_basic_nullable SET id = 1000 + owner_id WHERE id IS NULL;
ALTER TABLE lf_basic_nullable VALIDATE CONSTRAINT lf_basic_nullable_id_notnull;
SELECT lf_check($$ SELECT owner_id, id FROM lf_basic_nullable WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY id $$);
DROP TABLE lf_basic_nullable;

-- An integer sort column is accepted, a non-integer one is rejected.
CREATE TABLE lf_basic_int4 (id integer NOT NULL, owner_id bigint NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_int4 (owner_id, id);
CREATE INDEX ON lf_basic_int4 (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_int4 WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_int4;
CREATE TABLE lf_basic_numeric (id numeric NOT NULL, owner_id bigint NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_numeric (owner_id, id);
CREATE INDEX ON lf_basic_numeric (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_numeric WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_numeric;

-- An equality column of any type with a btree operator family is accepted.
CREATE TABLE lf_basic_int4_owner (id bigint NOT NULL, owner_id integer NOT NULL, deleted_at timestamptz);
CREATE INDEX ON lf_basic_int4_owner (owner_id, id);
CREATE INDEX ON lf_basic_int4_owner (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_int4_owner WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_int4_owner;

CREATE TABLE lf_basic_part (id bigint NOT NULL, owner_id bigint NOT NULL, deleted_at timestamptz)
	PARTITION BY HASH (id);
CREATE TABLE lf_basic_part_0 PARTITION OF lf_basic_part FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE lf_basic_part_1 PARTITION OF lf_basic_part FOR VALUES WITH (MODULUS 2, REMAINDER 1);
CREATE INDEX ON lf_basic_part (owner_id, id);
CREATE INDEX ON lf_basic_part (id) WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_part WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
DROP TABLE lf_basic_part;

-- A plain view is expanded into its query, so the node can serve it.
CREATE VIEW lf_basic_view AS SELECT * FROM lf_basic WHERE deleted_at IS NULL;
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic_view WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic_view WHERE owner_id = 5 ORDER BY id LIMIT 20 $$);
DROP VIEW lf_basic_view;

-- TABLESAMPLE: the sample decides the rows, so only a Sample Scan may read them.
SELECT * FROM lf_plan($$
SELECT * FROM lf_basic TABLESAMPLE SYSTEM (50) REPEATABLE (1)
WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_basic TABLESAMPLE SYSTEM (50) REPEATABLE (1)
WHERE owner_id = 5 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

DROP TABLE lf_basic;
