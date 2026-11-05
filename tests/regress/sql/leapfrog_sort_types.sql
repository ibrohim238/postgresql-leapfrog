--
-- leapfrog_sort_types
--
-- Sort columns of any B-tree type: the merge compares them with the pathkey's
-- own comparator, and a by-reference value survives the streams moving on.
-- Ties in the sort column are broken by id above the node, so that the order
-- is deterministic for lf_check.
--
SET max_parallel_workers_per_gather = 0;

CREATE TYPE lf_st_mood AS ENUM ('sad', 'ok', 'happy');
CREATE DOMAIN lf_st_code AS text;

CREATE TABLE lf_st (
	id bigint PRIMARY KEY,
	owner_id integer NOT NULL,
	kind integer NOT NULL,
	ts timestamptz NOT NULL,
	d date NOT NULL,
	num numeric NOT NULL,
	txt text NOT NULL,
	txt_c text COLLATE "C" NOT NULL,
	vc varchar(1200) NOT NULL,
	bp char(8) NOT NULL,
	u uuid NOT NULL,
	arr integer[] NOT NULL,
	mood lf_st_mood NOT NULL,
	code lf_st_code NOT NULL,
	r real NOT NULL
) WITH (autovacuum_enabled = false);

-- 3000 distinct values over 30000 rows, in hashed physical order; numeric
-- values equal in different scales, long text that needs many leaf pages.
INSERT INTO lf_st
SELECT g,
	abs(hashint8(g * 3)) % 20,
	abs(hashint8(g * 5)) % 20,
	'2024-01-01 00:00+00'::timestamptz + v * interval '1 minute',
	'2000-01-01'::date + v,
	CASE WHEN g % 2 = 0 THEN (v::numeric / 10)::numeric(10, 1) ELSE (v::numeric / 10)::numeric(10, 3) END,
	repeat(chr(97 + v % 26), 400) || lpad(v::text, 8, '0') || repeat(chr(65 + v % 26), 400),
	chr(97 + v % 26) || lpad(v::text, 8, '0'),
	repeat('v', 300) || lpad(v::text, 8, '0'),
	lpad((v % 1000)::text, 8, '0'),
	md5(v::text)::uuid,
	ARRAY[v / 10, v],
	(ARRAY['sad', 'ok', 'happy'])[v % 3 + 1]::lf_st_mood,
	lpad(v::text, 8, '0'),
	v / 8.0
FROM (SELECT g, abs(hashint8(g * 7)) % 3000 AS v FROM generate_series(1, 30000) g) s;

DO $$
DECLARE
	col text;
BEGIN
	FOREACH col IN ARRAY ARRAY['ts', 'd', 'num', 'txt', 'txt_c', 'vc', 'bp', 'u', 'arr', 'mood', 'code', 'r'] LOOP
		EXECUTE format('CREATE INDEX lf_st_owner_%1$s ON lf_st (owner_id, %1$s)', col);
		EXECUTE format('CREATE INDEX lf_st_kind_%1$s ON lf_st (kind, %1$s)', col);
	END LOOP;
END
$$;
ANALYZE lf_st;

-- Every type, both directions, with and without LIMIT: same rows as stock.
SELECT col, ord, lim, lf_check(format(
	'SELECT id, owner_id, kind FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY %s %s, id %s',
	col, ord, lim))
FROM unnest(ARRAY['ts', 'd', 'num', 'txt', 'txt_c', 'vc', 'bp', 'u', 'arr', 'mood', 'code', 'r']) col,
	unnest(ARRAY['ASC', 'DESC']) ord,
	unnest(ARRAY['', 'LIMIT 7']) lim
ORDER BY 1, 2, 3;

-- The shape: the node gives the sort column, ties are sorted above it.
SELECT * FROM lf_plan($$
SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY ts, id LIMIT 5 $$);
SELECT * FROM lf_plan($$
SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY ts LIMIT 5 $$);

-- Duplicates of the sort value across streams, big groups (three moods).
SELECT lf_check($$ SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY mood DESC, id $$);

-- Skip-ahead with long text: the bound must outlive the stream it came from.
-- One stream is dense, one holds only the upper half of the values.
CREATE TABLE lf_st_skip (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val text NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_st_skip
SELECT g, CASE WHEN g % 200 = 0 THEN 1 ELSE 2 END, CASE WHEN g % 3 = 0 THEN 1 ELSE 2 END,
	repeat('p', 300) || lpad(g::text, 8, '0')
FROM generate_series(1, 20000) g;
CREATE INDEX lf_st_skip_a ON lf_st_skip (a, val);
CREATE INDEX lf_st_skip_b ON lf_st_skip (b, val);
ANALYZE lf_st_skip;
SELECT lf_check($$ SELECT id FROM lf_st_skip WHERE a = 1 AND b = 1 ORDER BY val $$);
SELECT lf_check($$ SELECT id FROM lf_st_skip WHERE a = 1 AND b = 1 ORDER BY val DESC $$);
SELECT lf_check($$ SELECT id FROM lf_st_skip WHERE a = 1 AND b = 2 ORDER BY val LIMIT 9 $$);
SELECT value::bigint > 0 AS skipped FROM lf_counters($$
SELECT id FROM lf_st_skip WHERE a = 1 AND b = 1 ORDER BY val $$) WHERE counter = 'Skips';
DROP TABLE lf_st_skip;

-- Parameters: a generic plan and LATERAL, rescanned with a new position.
SET plan_cache_mode = force_generic_plan;
SET leapfrog.force = on;
PREPARE lf_st_q(integer, integer) AS
	SELECT id FROM lf_st WHERE owner_id = $1 AND kind = $2 ORDER BY txt, id LIMIT 5;
EXPLAIN (COSTS OFF) EXECUTE lf_st_q(3, 2);
CREATE TEMP TABLE lf_st_generic AS EXECUTE lf_st_q(3, 2);
RESET leapfrog.force;
SET leapfrog.enabled = off;
CREATE TEMP TABLE lf_st_stock AS EXECUTE lf_st_q(3, 2);
RESET leapfrog.enabled;
SELECT count(*) AS rows, count(*) FILTER (WHERE s.id IS NULL) AS differ
FROM lf_st_generic g LEFT JOIN lf_st_stock s USING (id);
DEALLOCATE lf_st_q;
DROP TABLE lf_st_generic, lf_st_stock;
RESET plan_cache_mode;

SELECT lf_check($$ SELECT p.o, q.id FROM (VALUES (3), (4), (5)) p(o)
	CROSS JOIN LATERAL (SELECT id FROM lf_st t WHERE t.owner_id = p.o AND t.kind = 2 ORDER BY txt_c, id LIMIT 3) q
	ORDER BY 1, 2 $$);

-- Overflow: a by-reference group larger than work_mem, checked on the rows.
SET work_mem = 64;
SELECT lf_check($$ SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY mood, id $$);
CREATE TABLE lf_st_big (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val text NOT NULL);
INSERT INTO lf_st_big SELECT g, g % 2, g % 3, CASE WHEN g % 100 = 0 THEN 'x' ELSE 'y' END FROM generate_series(1, 60000) g;
CREATE INDEX lf_st_big_a ON lf_st_big (a, val);
CREATE INDEX lf_st_big_b ON lf_st_big (b, val);
ANALYZE lf_st_big;
SELECT lf_check($$ SELECT id FROM lf_st_big WHERE a = 1 AND b = 1 ORDER BY val, id $$);
SELECT value::bigint > 0 AS overflowed FROM lf_counters($$
SELECT id FROM lf_st_big WHERE a = 1 AND b = 1 ORDER BY val $$) WHERE counter = 'Group Overflows';
DROP TABLE lf_st_big;
RESET work_mem;

-- Collations: an index sorted in another collation than the query's is no
-- stream of its order, alone or paired.
SELECT lf_check($$ SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY txt COLLATE "C", id LIMIT 5 $$);
CREATE INDEX lf_st_owner_txt_c2 ON lf_st (owner_id, txt COLLATE "C");
CREATE INDEX lf_st_kind_txt_c2 ON lf_st (kind, txt COLLATE "C");
SELECT lf_check($$ SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY txt COLLATE "C", id LIMIT 5 $$);
DROP INDEX lf_st_kind_txt_c2;
SELECT lf_check($$ SELECT id FROM lf_st WHERE owner_id = 3 AND kind = 2 ORDER BY txt COLLATE "C", id LIMIT 5 $$);
DROP INDEX lf_st_owner_txt_c2;

-- Another operator family sorts differently: not used for the query's order.
CREATE TABLE lf_st_ops (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val text NOT NULL);
INSERT INTO lf_st_ops SELECT g, g % 7, g % 5, md5(g::text) FROM generate_series(1, 5000) g;
CREATE INDEX lf_st_ops_a ON lf_st_ops (a, val text_pattern_ops);
CREATE INDEX lf_st_ops_b ON lf_st_ops (b, val text_pattern_ops);
ANALYZE lf_st_ops;
SELECT lf_check($$ SELECT id FROM lf_st_ops WHERE a = 1 AND b = 1 ORDER BY val, id LIMIT 5 $$);
SELECT lf_check($$ SELECT id FROM lf_st_ops WHERE a = 1 AND b = 1 ORDER BY val USING ~<~, id LIMIT 5 $$);
DROP TABLE lf_st_ops;

-- Different input types in one family: an index on another type is no partner.
CREATE TABLE lf_st_int (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, i4 integer NOT NULL);
INSERT INTO lf_st_int SELECT g, g % 7, g % 5, g FROM generate_series(1, 5000) g;
CREATE INDEX lf_st_int_a ON lf_st_int (a, i4);
CREATE INDEX lf_st_int_b ON lf_st_int (b, (i4::bigint));
ANALYZE lf_st_int;
SELECT lf_check($$ SELECT id FROM lf_st_int WHERE a = 1 AND b = 1 ORDER BY i4, id LIMIT 5 $$);
DROP TABLE lf_st_int;

DROP TABLE lf_st;
DROP DOMAIN lf_st_code;
DROP TYPE lf_st_mood;
