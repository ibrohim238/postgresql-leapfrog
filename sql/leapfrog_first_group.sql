--
-- leapfrog_first_group
--
-- No row comes before the inner streams have read the group the merge reaches
-- first.  Costs are compared with each other: they are not stored here, as they
-- depend on the sample ANALYZE takes.
--
SET max_parallel_workers_per_gather = 0;

-- Cost of the node in a plan, NULL when the plan does not use it.
CREATE FUNCTION lf_fg_cost(query text, what text DEFAULT 'Startup Cost')
RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	RETURN (jsonb_path_query_first(plan,
		'$.** ? (@."Custom Plan Provider" == "Index Merge Intersect")')->>what)::float8;
END
$$;

-- Indexes the node merges, 0 when the plan does not use it.
CREATE FUNCTION lf_fg_streams(query text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
	line text;
	n integer := 0;
BEGIN
	FOR line IN EXECUTE 'EXPLAIN ' || query LOOP
		IF line ~ '->  (Outer|Inner) Stream on ' THEN
			n := n + 1;
		END IF;
	END LOOP;
	RETURN n;
END
$$;

-- At the newest end one value has most of the rows.
CREATE TABLE lf_fg (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL,
	c integer NOT NULL, d integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg
SELECT g, abs(hashint8(g)) % 50, abs(hashint8(g * 3)) % 4, abs(hashint8(g * 5)) % 4,
	abs(hashint8(g * 7)) % 4, CASE WHEN g <= 200000 THEN 1000000 ELSE g END
FROM generate_series(1, 240000) g;
CREATE INDEX lf_fg_a ON lf_fg (a, ts);
CREATE INDEX lf_fg_b ON lf_fg (b, ts);
CREATE INDEX lf_fg_c ON lf_fg (c, ts);
CREATE INDEX lf_fg_d ON lf_fg (d, ts);
-- the whole table in the sample: the choices below do not depend on it
SET default_statistics_target = 1000;
ANALYZE lf_fg;
RESET default_statistics_target;

SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_sort = off;

SELECT lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS first_group_is_charged;

-- Sorting the group counts as well.
SET cpu_operator_cost = 1;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	10 * lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS group_sort_is_charged;
RESET cpu_operator_cost;

-- A generic plan does not know the first value: the overlap is taken for the
-- whole column, as in the rest of its costing, and the column ends on the value.
PREPARE lf_fg_desc(integer, integer) AS
	SELECT id FROM lf_fg WHERE a = $1 AND b = $2 ORDER BY ts DESC LIMIT 100;
PREPARE lf_fg_asc(integer, integer) AS
	SELECT id FROM lf_fg WHERE a = $1 AND b = $2 ORDER BY ts LIMIT 100;
SET plan_cache_mode = force_generic_plan;
SELECT lf_fg_cost('EXECUTE lf_fg_desc(7, 2)') > 5 * lf_fg_cost('EXECUTE lf_fg_asc(7, 2)')
	AS generic_plan_is_charged;
RESET plan_cache_mode;
DEALLOCATE lf_fg_desc;
DEALLOCATE lf_fg_asc;

-- A set with one stream more can be cheaper in total and dearer to start:
-- without a LIMIT the node takes all three, a LIMIT is better served by two.
SET cpu_tuple_cost = 1;
SELECT lf_fg_streams($$ SELECT * FROM lf_fg WHERE b = 2 AND c = 1 AND d = 3 ORDER BY ts DESC $$) AS whole,
	lf_fg_streams($$ SELECT * FROM lf_fg WHERE b = 2 AND c = 1 AND d = 3 ORDER BY ts DESC LIMIT 100 $$) AS with_limit;
RESET cpu_tuple_cost;
SELECT lf_check($$ SELECT id FROM lf_fg WHERE b = 2 AND c = 1 AND d = 3 ORDER BY ts DESC, id LIMIT 100 $$);

-- A group that overflows work_mem: every outer entry of the value is fetched.  With
-- comparisons at no cost, the sort it saves does not hide that.
SET cpu_operator_cost = 0;
SET work_mem = '64kB';
SELECT lf_fg_cost($$ SELECT id FROM lf_fg WHERE b = 2 AND c = 1 ORDER BY ts DESC $$, 'Total Cost') AS small \gset
RESET work_mem;
SELECT :small > 100 + lf_fg_cost($$ SELECT id FROM lf_fg WHERE b = 2 AND c = 1 ORDER BY ts DESC $$, 'Total Cost')
	AS overflow_is_charged;
RESET cpu_operator_cost;
SET work_mem = '64kB';
SELECT value FROM lf_counters($$ SELECT id FROM lf_fg WHERE b = 2 AND c = 1 ORDER BY ts DESC LIMIT 10 $$)
	WHERE counter = 'Group Overflows';
SELECT lf_check($$ SELECT id FROM lf_fg WHERE b = 2 AND c = 1 ORDER BY ts DESC, id LIMIT 10 $$);
RESET work_mem;

-- One row ahead of the value hides it from a look at the first value only.  The
-- dead entry it leaves behind does so as well.
INSERT INTO lf_fg VALUES (240001, 7, 2, 1, 0, 2000000);
SELECT lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS behind_a_row;
-- The row hid the value from the planner as well: the Index Scan is the choice.
RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET enable_sort;
SELECT lf_fg_streams($$ SELECT * FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 15 $$) AS streams_chosen;
SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_sort = off;
DELETE FROM lf_fg WHERE id = 240001;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS behind_a_dead_entry;
SELECT lf_check($$ SELECT id FROM lf_fg WHERE a = 7 AND b = 2 ORDER BY ts DESC, id LIMIT 100 $$);
DROP TABLE lf_fg;

-- The value lies behind 1 % of the rows: a small LIMIT stops before it, and a
-- larger one has to read it.
CREATE TABLE lf_fg_limit (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_limit
SELECT g, abs(hashint8(g)) % 4, abs(hashint8(g * 3)) % 4,
	CASE WHEN g <= 1000 THEN 600000 + g WHEN g <= 51000 THEN 500000 ELSE g END
FROM generate_series(1, 100000) g;
CREATE INDEX lf_fg_limit_a ON lf_fg_limit (a, ts);
CREATE INDEX lf_fg_limit_b ON lf_fg_limit (b, ts);
ANALYZE lf_fg_limit;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_limit WHERE a = 1 AND b = 2 ORDER BY ts DESC LIMIT 200 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg_limit WHERE a = 1 AND b = 2 ORDER BY ts DESC LIMIT 10 $$)
	AS group_within_limit;
-- A group further on that overflows work_mem costs as much as the first.
SET cpu_operator_cost = 0;
SET work_mem = '64kB';
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_limit WHERE a = 1 AND b = 2 ORDER BY ts DESC $$, 'Total Cost') AS small \gset
RESET work_mem;
SELECT :small > 100 + lf_fg_cost($$ SELECT id FROM lf_fg_limit WHERE a = 1 AND b = 2 ORDER BY ts DESC $$, 'Total Cost')
	AS later_overflow_is_charged;
RESET cpu_operator_cost;
-- Sorting that group counts in the total, against the same table of even values.
CREATE TABLE lf_fg_even (LIKE lf_fg_limit) WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_even
SELECT id, a, b, id FROM lf_fg_limit;
CREATE INDEX lf_fg_even_a ON lf_fg_even (a, ts);
CREATE INDEX lf_fg_even_b ON lf_fg_even (b, ts);
ANALYZE lf_fg_even;
SET cpu_operator_cost = 1;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_limit WHERE a = 1 AND b = 2 ORDER BY ts DESC $$, 'Total Cost') >
	2 * lf_fg_cost($$ SELECT id FROM lf_fg_even WHERE a = 1 AND b = 2 ORDER BY ts DESC $$, 'Total Cost')
	AS later_sort_is_charged;
RESET cpu_operator_cost;
DROP TABLE lf_fg_even;
DROP TABLE lf_fg_limit;

-- The merge passes a value one stream does not hold: a = 7 has no rows on the common
-- value, a = 8 has its rows there, as many.  One row at the newest end for both.
CREATE TABLE lf_fg_absent (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_absent
SELECT g, CASE WHEN g <= 80000 THEN CASE WHEN g % 20 = 0 THEN 8 ELSE 100 END
		WHEN g % 5 = 0 THEN 7 ELSE 100 END,
	abs(hashint8(g)) % 2,
	CASE WHEN g <= 80000 THEN 500000 ELSE g END
FROM generate_series(1, 100000) g;
INSERT INTO lf_fg_absent VALUES (100001, 7, 1, 2000000), (100002, 8, 1, 2000000);
CREATE INDEX lf_fg_absent_a ON lf_fg_absent (a, ts);
CREATE INDEX lf_fg_absent_b ON lf_fg_absent (b, ts);
ANALYZE lf_fg_absent;
SELECT 3 * lf_fg_cost($$ SELECT id FROM lf_fg_absent WHERE a = 7 AND b = 1 ORDER BY ts DESC LIMIT 100 $$) <
	lf_fg_cost($$ SELECT id FROM lf_fg_absent WHERE a = 8 AND b = 1 ORDER BY ts DESC LIMIT 100 $$)
	AS absent_value_is_passed;
SELECT lf_check($$ SELECT id FROM lf_fg_absent WHERE a = 7 AND b = 1 ORDER BY ts DESC, id LIMIT 100 $$);
-- The same for the NULLs: a = 8 has them, a = 7 not.
UPDATE lf_fg_absent SET ts = NULL WHERE ts = 500000;
VACUUM ANALYZE lf_fg_absent;
SELECT 3 * lf_fg_cost($$ SELECT id FROM lf_fg_absent WHERE a = 7 AND b = 1 ORDER BY ts DESC LIMIT 100 $$) <
	lf_fg_cost($$ SELECT id FROM lf_fg_absent WHERE a = 8 AND b = 1 ORDER BY ts DESC LIMIT 100 $$)
	AS absent_nulls_are_passed;
SELECT lf_check($$ SELECT id FROM lf_fg_absent WHERE a = 7 AND b = 1 ORDER BY ts DESC, id LIMIT 100 $$);
DROP TABLE lf_fg_absent;

-- A stream with a narrow range: the value has 5 % of the table and most of the
-- rows of a = 7, which lie at that end, and a few of those of a = 8, spread out.
CREATE TABLE lf_fg_narrow (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_narrow
SELECT g, CASE WHEN g > 188000 THEN CASE WHEN g % 2 = 0 THEN 7 ELSE 100 + g % 40 END
		WHEN g % 32 = 0 THEN 8 ELSE 100 + g % 40 END,
	abs(hashint8(g)) % 2,
	CASE WHEN g > 190000 THEN 1000000 ELSE g END
FROM generate_series(1, 200000) g;
INSERT INTO lf_fg_narrow
SELECT 200000 + g, 8, abs(hashint8(g)) % 2, 1000000 FROM generate_series(1, 300) g;
CREATE INDEX lf_fg_narrow_a ON lf_fg_narrow (a, ts);
CREATE INDEX lf_fg_narrow_b ON lf_fg_narrow (b, ts);
ANALYZE lf_fg_narrow;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_narrow WHERE a = 7 AND b = 1 ORDER BY ts DESC LIMIT 10 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg_narrow WHERE a = 8 AND b = 1 ORDER BY ts DESC LIMIT 10 $$)
	AS narrow_stream_is_charged;
DROP TABLE lf_fg_narrow;

-- The NULLs of the sort column come first in DESC: a group every stream reads.
CREATE TABLE lf_fg_null (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, c integer NOT NULL, ts integer)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_null
SELECT g, abs(hashint8(g)) % 50, abs(hashint8(g * 3)) % 4, abs(hashint8(g * 5)) % 4,
	CASE WHEN g % 10 = 0 THEN g END
FROM generate_series(1, 200000) g;
CREATE INDEX lf_fg_null_a ON lf_fg_null (a, ts);
CREATE INDEX lf_fg_null_b ON lf_fg_null (b, ts);
CREATE INDEX lf_fg_null_ap ON lf_fg_null (c, a, ts) WHERE ts IS NOT NULL;
CREATE INDEX lf_fg_null_bp ON lf_fg_null (c, b, ts) WHERE ts IS NOT NULL;
ANALYZE lf_fg_null;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS null_group_is_charged;

-- Ranges that do not meet, in NULLS LAST as well: the group of the NULLs is all
-- that can match, and comes first.
UPDATE lf_fg_null SET ts = CASE WHEN a = 7 AND b = 2 THEN NULL WHEN a = 7 THEN id ELSE id + 1000000 END
	WHERE ts IS NOT NULL AND (a = 7 OR b = 2);
VACUUM ANALYZE lf_fg_null;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$) >
	5 * lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE a = 8 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS disjoint_ranges_null_group;

-- Partial indexes that hold no NULLs: the merge never reaches their group.
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE c = 1 AND a = 7 AND b = 2 AND ts IS NOT NULL ORDER BY ts DESC LIMIT 100 $$) <
	2 * lf_fg_cost($$ SELECT id FROM lf_fg_null WHERE c = 1 AND a = 7 AND b = 2 AND ts IS NOT NULL ORDER BY ts LIMIT 100 $$)
	AS no_null_group_in_partial;
DROP TABLE lf_fg_null;

-- A few values: most common values and no histogram.
CREATE TABLE lf_fg_few (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_few
SELECT g, abs(hashint8(g)) % 10, abs(hashint8(g * 3)) % 4,
	CASE WHEN g % 10 = 0 THEN g % 9 ELSE 9 END
FROM generate_series(1, 100000) g;
CREATE INDEX lf_fg_few_a ON lf_fg_few (a, ts);
CREATE INDEX lf_fg_few_b ON lf_fg_few (b, ts);
ANALYZE lf_fg_few;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_few WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 1 $$) >
	3 * lf_fg_cost($$ SELECT id FROM lf_fg_few WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 1 $$)
	AS few_values_charged;
DROP TABLE lf_fg_few;

-- A value out of the most common ones holds its share of what they leave.
CREATE TABLE lf_fg_rare (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_rare
SELECT g, abs(hashint8(g)) % 2, abs(hashint8(g * 3)) % 2,
	CASE WHEN g % 10 <> 0 THEN 1000 + g % 50 ELSE abs(hashint8(g * 5)) % 150 + (CASE WHEN g % 20 = 0 THEN 0 ELSE 2000 END) END
FROM generate_series(1, 400000) g;
CREATE INDEX lf_fg_rare_a ON lf_fg_rare (a, ts);
CREATE INDEX lf_fg_rare_b ON lf_fg_rare (b, ts);
ALTER TABLE lf_fg_rare ALTER COLUMN ts SET STATISTICS 50;
ANALYZE lf_fg_rare;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_rare WHERE a = 1 AND b = 1 ORDER BY ts LIMIT 1 $$) <
	lf_fg_cost($$ SELECT id FROM lf_fg_rare WHERE a = 1 AND b = 1 ORDER BY ts LIMIT 1 $$, 'Total Cost') / 3000
	AS rare_value_share;
DROP TABLE lf_fg_rare;

-- A unique sort column: the group of one row is no reason for a page per stream.
CREATE TABLE lf_fg_uniq (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, c integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_fg_uniq
SELECT g, 1, abs(hashint8(g * 3)) % 2, abs(hashint8(g * 5)) % 2
FROM generate_series(1, 200000) g;
CREATE INDEX lf_fg_uniq_a ON lf_fg_uniq (a, id);
CREATE INDEX lf_fg_uniq_b ON lf_fg_uniq (b, id);
CREATE INDEX lf_fg_uniq_c ON lf_fg_uniq (c, id);
ANALYZE lf_fg_uniq;
SET random_page_cost = 100;
SELECT lf_fg_cost($$ SELECT id FROM lf_fg_uniq WHERE b = 1 AND c = 1 ORDER BY id LIMIT 1 $$) <
	lf_fg_cost($$ SELECT id FROM lf_fg_uniq WHERE b = 1 AND c = 1 ORDER BY id LIMIT 1 $$, 'Total Cost') / 5000
	AS no_page_floor;
RESET random_page_cost;
DROP TABLE lf_fg_uniq;
RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET enable_sort;
DROP FUNCTION lf_fg_cost(text, text);
DROP FUNCTION lf_fg_streams(text);
