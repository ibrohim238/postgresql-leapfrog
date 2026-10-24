--
-- leapfrog_nway
--
-- Intersection of more than two indexes: every stream after the first is an
-- inner one with its own TID group, the merge advances every lagging stream
-- to the frontmost value and matches an outer entry only when every inner
-- group holds its TID.  The planner adds a stream only while it lowers the
-- estimated cost; leapfrog.min_indexes (a developer setting) requires a set
-- size so that larger sets can be run against the stock plans.  Results are
-- compared with the standard plans throughout.
--
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
-- 60,000 rows; hashed values, independent of each other and of id.  The
-- statistics target makes ANALYZE sample every row, so the estimates and
-- with them the chosen sets do not vary between runs.
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

-- Three streams: two ordinary indexes and a partial one.  The node fetches
-- only the rows every stream agrees on; with two streams the third
-- condition filters the fetched rows.
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
SELECT * FROM lf_counters($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Outer Index', 'Inner Index', 'Inner Index 2', 'Matched TIDs', 'Heap Fetches', 'Rows Removed by Filter');

-- Four and five streams.
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

-- A bigger set is used only when it is estimated cheaper.  The stock scans
-- are disabled so that the sets compete among themselves by their real
-- costs, without leapfrog.force.
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
-- The pair customer + archived leaves 250 rows to fetch and region cuts them
-- to 50: a third stream of 12,000 entries saves 200 heap fetches.
SELECT * FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$);
-- The pair customer + product leaves 100 rows and the live rows are 9 in 10
-- of them: a third stream of 54,000 entries would save 10 heap fetches.
SELECT * FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id $$);
-- With leapfrog.max_indexes = 2 the third stream is never added.
SET leapfrog.max_indexes = 2;
SELECT count(*) FROM lf_plan_node($$
SELECT * FROM lf_nway WHERE customer_id = 7 AND region = 2 AND archived ORDER BY id $$)
WHERE lf_plan_node ~ 'Inner Index 2';
RESET leapfrog.max_indexes;
DROP FUNCTION lf_plan_node(text);

-- Parameters: a prepared statement with a generic plan, and a LATERAL
-- subquery rescanned for every outer row.
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

-- A non-unique sort column: every value has several entries in every
-- stream, matched by TID across three groups.
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

-- Groups larger than work_mem in more than one stream: with every row in
-- one grp value both inner groups overflow and the inner conditions are
-- checked on the fetched rows.
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

-- Rows moving between the streams: updates and deletes leave dead entries
-- in some indexes and new ones in others.
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
-- FOR UPDATE: the row marks and the recheck path with three streams
SELECT lf_check($$ SELECT * FROM lf_nway WHERE customer_id = 7 AND product_id = 3 AND deleted_at IS NULL ORDER BY id LIMIT 10 FOR UPDATE $$);
RESET leapfrog.min_indexes;

DROP TABLE lf_nway;

-- Every stream of a set must add a restriction the others do not enforce:
-- an equality column no other stream has, or a predicate the other streams'
-- equalities and predicates do not imply.  Under leapfrog.force any set the
-- planner may form shows up, so a redundant one would be visible here.
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
-- One condition: neither the primary key (id) nor (campaign_id, id), which
-- has no equality, nor anything else narrows (membership_id, id) down.
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 ORDER BY id DESC LIMIT 100 $$);
-- (membership_id, id) WHERE deleted_at IS NULL alone enforces both
-- conditions: (membership_id, id) adds nothing to it, nor does
-- (id) WHERE deleted_at IS NULL, whose predicate it implies.  The pair that
-- remains is (membership_id, id) and (id) WHERE deleted_at IS NULL, each
-- adding one condition.
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
-- The same with the pair gone: the partial index on both columns is the plan.
BEGIN;
DROP INDEX lf_nway_red_live;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100 $$);
ROLLBACK;
-- A predicate implied by an equality: (id) WHERE kind = 2 adds nothing to
-- (kind, id) with kind = 2, so the two are never in one set, at any size.
SET leapfrog.max_indexes = 4;
SET leapfrog.min_indexes = 3;
SELECT * FROM lf_plan($$
SELECT * FROM lf_nway_red WHERE membership_id = 3 AND kind = 2 ORDER BY id DESC LIMIT 100 $$);
RESET leapfrog.min_indexes;
RESET leapfrog.max_indexes;
SELECT lf_check($$ SELECT * FROM lf_nway_red WHERE membership_id = 3 AND kind = 2 ORDER BY id DESC LIMIT 100 $$);
DROP TABLE lf_nway_red;
