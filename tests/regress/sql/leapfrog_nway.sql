-- leapfrog_nway: more than two streams; leapfrog.min_indexes forces a set size to test larger sets.
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_nway (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	region bigint NOT NULL,
	deleted_at timestamptz,
	archived boolean NOT NULL,
	flagged boolean NOT NULL,
	payload text
);
-- Hashed, independent values; ANALYZE samples every row, so the chosen sets do not vary.
SET default_statistics_target = 200;
INSERT INTO lf_nway
SELECT g, abs(hashint8(g * 8 + 1)) % 30, abs(hashint8(g * 8 + 2)) % 20,
	abs(hashint8(g * 8 + 3)) % 5,
	CASE WHEN abs(hashint8(g * 8 + 4)) % 10 = 0 THEN '2026-01-01'::timestamptz END,
	abs(hashint8(g * 8 + 5)) % 8 = 0,
	abs(hashint8(g * 8 + 6)) % 200 = 0,
	'p' || g
FROM generate_series(1, 60000) g;
CREATE INDEX lf_nway_customer_id ON lf_nway (customer_id, id);
CREATE INDEX lf_nway_product_id ON lf_nway (product_id, id);
CREATE INDEX lf_nway_region_id ON lf_nway (region, id);
CREATE INDEX lf_nway_live_id ON lf_nway (id) WHERE deleted_at IS NULL;
CREATE INDEX lf_nway_deleted_id ON lf_nway (id) WHERE deleted_at IS NOT NULL;
CREATE INDEX lf_nway_archived_id ON lf_nway (id) WHERE archived;
CREATE INDEX lf_nway_flagged_id ON lf_nway (id) WHERE flagged;
ANALYZE lf_nway;

-- Three streams fetch only the rows all agree on; with two the third condition filters.
SET leapfrog.min_indexes = 3;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Outer Index', 'Inner Index', 'Inner Index 2', 'Matched TIDs', 'Heap Fetches', 'Rows Removed by Filter');
RESET leapfrog.min_indexes;
SET leapfrog.max_indexes = 2;
SELECT * FROM lf_counters($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Outer Index', 'Inner Index', 'Inner Index 2', 'Matched TIDs', 'Heap Fetches', 'Rows Removed by Filter');
RESET leapfrog.max_indexes;

SET leapfrog.min_indexes = 4;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived
ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived ORDER BY id DESC LIMIT 3 $$);
SET leapfrog.max_indexes = 5;
SET leapfrog.min_indexes = 5;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived AND deleted_at IS NULL
ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived AND deleted_at IS NULL ORDER BY id DESC $$);
-- the other partial index is implied by the one already in the set
SELECT count(*) FROM lf_plan($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND archived AND deleted_at IS NULL
ORDER BY id $$) WHERE lf_plan ~ 'Index';
RESET leapfrog.max_indexes;
RESET leapfrog.min_indexes;

-- A bigger set only when cheaper; stock scans disabled so the sets compete by real costs.
CREATE FUNCTION lf_plan_node(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
BEGIN
	PERFORM set_config('enable_seqscan', 'off', true);
	PERFORM set_config('enable_indexscan', 'off', true);
	PERFORM set_config('enable_indexonlyscan', 'off', true);
	PERFORM set_config('enable_bitmapscan', 'off', true);
	FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
		RETURN NEXT line;
	END LOOP;
END
$$;
-- customer + archived leave 250 rows, region cuts them to 50: the third stream pays.
SELECT * FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$);
-- customer + product leave 100 rows, 9 in 10 live: a third stream would not pay.
SELECT * FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
SET leapfrog.max_indexes = 2;
SELECT count(*) FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$)
WHERE lf_plan_node ~ 'Stream on';
RESET leapfrog.max_indexes;
-- Under leapfrog.force the sets are still compared by their own costs: the same three streams.
SET leapfrog.force = on;
SELECT * FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$);
RESET leapfrog.force;
DROP FUNCTION lf_plan_node(text);

SET leapfrog.min_indexes = 3;
SET plan_cache_mode = force_generic_plan;
PREPARE lf_nway_q (bigint, bigint) AS
	SELECT id FROM lf_nway WHERE customer_id = $1 AND product_id = $2 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 5;
EXPLAIN (COSTS OFF) EXECUTE lf_nway_q(7, 3);
EXECUTE lf_nway_q(7, 3);
EXECUTE lf_nway_q(8, 4);
EXECUTE lf_nway_q(7, 3);
SET leapfrog.enabled = off;
EXECUTE lf_nway_q(7, 3);
EXECUTE lf_nway_q(8, 4);
RESET leapfrog.enabled;
DEALLOCATE lf_nway_q;
RESET plan_cache_mode;
SELECT lf_check($$
SELECT v.c, v.p, s.id
FROM (VALUES (7::bigint, 3::bigint), (8, 4), (7, 3), (9, 19)) v (c, p),
	LATERAL (SELECT id FROM lf_nway
			 WHERE customer_id = v.c AND product_id = v.p AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 4) s $$);
RESET leapfrog.min_indexes;

-- A non-unique sort column: matched by TID across three groups.
CREATE TABLE lf_nway_dup (
	id bigint PRIMARY KEY,
	grp bigint NOT NULL,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_nway_dup
SELECT g, g / 4, abs(hashint8(g * 8 + 1)) % 10, abs(hashint8(g * 8 + 2)) % 5,
	CASE WHEN abs(hashint8(g * 8 + 4)) % 3 = 0 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 40000) g;
CREATE INDEX lf_nway_dup_customer_grp ON lf_nway_dup (customer_id, grp);
CREATE INDEX lf_nway_dup_product_grp ON lf_nway_dup (product_id, grp);
CREATE INDEX lf_nway_dup_live_grp ON lf_nway_dup (grp) WHERE deleted_at IS NULL;
ANALYZE lf_nway_dup;
SET leapfrog.min_indexes = 3;
SELECT lf_check($$ SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp $$, false);
SELECT lf_check($$ SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp DESC $$, false);
SELECT lf_check($$ SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp $$)
WHERE counter IN ('Inner Index 2', 'Matched TIDs', 'Heap Fetches', 'Peak Group Memory');

-- Both inner groups overflow work_mem: the inner conditions are checked on the fetched rows.
UPDATE lf_nway_dup SET grp = 1;
ANALYZE lf_nway_dup;
SET work_mem = '64kB';
SET leapfrog.force = on;
SELECT lf_check($$ SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_nway_dup WHERE customer_id = 3 AND product_id = 1 AND deleted_at IS NULL ORDER BY grp, id $$)
WHERE counter IN ('Inner Index 2', 'Matched TIDs', 'Group Overflows', 'Rows Checked by Predicate', 'Actual Rows');
RESET leapfrog.force;
RESET work_mem;
RESET leapfrog.min_indexes;
DROP TABLE lf_nway_dup;

-- Rows moving between the streams
SET leapfrog.min_indexes = 3;
UPDATE lf_nway SET deleted_at = now() WHERE customer_id = 7 AND id % 3 = 0;
UPDATE lf_nway SET deleted_at = NULL WHERE product_id = 3 AND id % 7 = 0;
UPDATE lf_nway SET product_id = 4 WHERE customer_id = 7 AND product_id = 3 AND id % 5 = 0;
UPDATE lf_nway SET payload = payload || '!' WHERE customer_id = 7 AND id % 2 = 0;
DELETE FROM lf_nway WHERE customer_id = 7 AND id % 11 = 0;
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 10 $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 4 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND region = 2 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id LIMIT 10 FOR UPDATE $$);
RESET leapfrog.min_indexes;

DROP TABLE lf_nway;

-- Every stream must add a restriction the others do not enforce; force shows any set formed.
CREATE TABLE lf_nway_red (
	id bigint PRIMARY KEY,
	membership_id bigint NOT NULL,
	campaign_id bigint NOT NULL,
	kind bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_nway_red
SELECT g, g % 50, g % 7, g % 3, CASE WHEN g % 5 = 0 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 20000) g;
CREATE INDEX lf_nway_red_membership ON lf_nway_red (membership_id, id);
CREATE INDEX lf_nway_red_campaign ON lf_nway_red (campaign_id, id);
CREATE INDEX lf_nway_red_kind ON lf_nway_red (kind, id);
CREATE INDEX lf_nway_red_membership_live ON lf_nway_red (membership_id, id) WHERE deleted_at IS NULL;
CREATE INDEX lf_nway_red_live ON lf_nway_red (id) WHERE deleted_at IS NULL;
CREATE INDEX lf_nway_red_kind2 ON lf_nway_red (id) WHERE kind = 2;
ANALYZE lf_nway_red;
-- Nothing narrows (membership_id, id) down.
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 ORDER BY id DESC LIMIT 100 $$);
-- The partial (membership_id, id) enforces both conditions alone: no set forms.
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
BEGIN;
DROP INDEX lf_nway_red_live;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
ROLLBACK;
-- (id) WHERE kind = 2 adds nothing to (kind, id) with kind = 2, at any set size.
SET leapfrog.max_indexes = 4;
SET leapfrog.min_indexes = 3;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND kind = 2 ORDER BY id DESC LIMIT 100 $$);
RESET leapfrog.min_indexes;
RESET leapfrog.max_indexes;
SELECT lf_check($$ SELECT * FROM lf_nway_red WHERE membership_id = 3 AND kind = 2 ORDER BY id DESC LIMIT 100 $$);
DROP TABLE lf_nway_red;
