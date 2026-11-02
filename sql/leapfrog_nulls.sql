--
-- leapfrog_nulls
--
-- A nullable sort column: NULL is a value of the merge in B-tree order, and
-- the NULL group is intersected by TID like any other.  A bound on a value
-- excludes NULLs, so a stream that skipped goes back for them when they come
-- after the values.
--
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_null (
	id bigint PRIMARY KEY,
	a integer NOT NULL,
	b integer NOT NULL,
	val bigint,
	txt text,
	note text
) WITH (autovacuum_enabled = false);
INSERT INTO lf_null
SELECT g, abs(hashint8(g * 3)) % 20, abs(hashint8(g * 5)) % 20,
	CASE WHEN g % 4 = 0 THEN NULL ELSE abs(hashint8(g * 7)) % 3000 END,
	CASE WHEN g % 4 = 0 THEN NULL ELSE repeat('t', 200) || lpad((abs(hashint8(g * 7)) % 3000)::text, 8, '0') END,
	'n'
FROM generate_series(1, 30000) g;
-- both NULLS positions, so that all four query orders have their indexes
CREATE INDEX lf_null_a_last ON lf_null (a, val);
CREATE INDEX lf_null_b_last ON lf_null (b, val);
CREATE INDEX lf_null_a_first ON lf_null (a, val NULLS FIRST);
CREATE INDEX lf_null_b_first ON lf_null (b, val NULLS FIRST);
CREATE INDEX lf_null_a_txt ON lf_null (a, txt);
CREATE INDEX lf_null_b_txt ON lf_null (b, txt);
CREATE INDEX lf_null_a_txt_first ON lf_null (a, txt NULLS FIRST);
CREATE INDEX lf_null_b_txt_first ON lf_null (b, txt NULLS FIRST);
ANALYZE lf_null;

-- All four orders, with and without LIMIT, by-value and by-reference.
SELECT col, ord, lim, lf_check(format(
	'SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY %s %s, id %s', col, ord, lim))
FROM unnest(ARRAY['val', 'txt']) col,
	unnest(ARRAY['ASC NULLS LAST', 'ASC NULLS FIRST', 'DESC NULLS LAST', 'DESC NULLS FIRST']) ord,
	unnest(ARRAY['', 'LIMIT 3', 'LIMIT 60']) lim
ORDER BY 1, 2, 3;

-- Each order uses the indexes whose NULLs lie where the query wants them.
SELECT * FROM lf_plan($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val ASC NULLS LAST LIMIT 5 $$);
SELECT * FROM lf_plan($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val ASC NULLS FIRST LIMIT 5 $$);
SELECT * FROM lf_plan($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val DESC NULLS LAST LIMIT 5 $$);
SELECT * FROM lf_plan($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val DESC NULLS FIRST LIMIT 5 $$);

-- Indexes with their NULLs at the other end are no use for this order.
DROP INDEX lf_null_a_first, lf_null_b_first;
SELECT lf_check($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val ASC NULLS FIRST, id LIMIT 5 $$);
SELECT lf_check($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val DESC NULLS LAST, id LIMIT 5 $$);
-- nor is a mixed pair
CREATE INDEX lf_null_b_first ON lf_null (b, val NULLS FIRST);
DROP INDEX lf_null_b_last;
SELECT lf_check($$ SELECT id FROM lf_null WHERE a = 3 AND b = 2 ORDER BY val, id LIMIT 5 $$);

DROP TABLE lf_null;

-- Skip-ahead across the NULL boundary.  Stream "sparse" has a few values and
-- its NULLs; stream "dense" has many values and its NULLs: with NULLs after
-- the values the dense stream skips on values and must come back for them.
CREATE TABLE lf_null_skip (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint, note text)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_null_skip
SELECT g,
	CASE WHEN g % 1000 = 0 OR g > 49900 THEN 1 ELSE 2 END,
	CASE WHEN g % 2 = 0 OR g > 49900 THEN 1 ELSE 2 END,
	CASE WHEN g > 49900 THEN NULL ELSE g END,
	'n'
FROM generate_series(1, 50000) g;
CREATE INDEX lf_null_skip_a ON lf_null_skip (a, val);
CREATE INDEX lf_null_skip_b ON lf_null_skip (b, val);
CREATE INDEX lf_null_skip_a_first ON lf_null_skip (a, val NULLS FIRST);
CREATE INDEX lf_null_skip_b_first ON lf_null_skip (b, val NULLS FIRST);
ANALYZE lf_null_skip;
SELECT ord, lf_check(format('SELECT id FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val %s, id', ord))
FROM unnest(ARRAY['ASC NULLS LAST', 'ASC NULLS FIRST', 'DESC NULLS LAST', 'DESC NULLS FIRST']) ord ORDER BY 1;
SELECT ord, c.value::bigint > 0 AS skipped
FROM unnest(ARRAY['ASC NULLS LAST', 'DESC NULLS LAST']) ord,
	LATERAL lf_counters(format('SELECT id FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val %s', ord)) c
WHERE c.counter = 'Skips' ORDER BY 1;

-- The target of a skip is the NULL group: one stream has values far behind
-- and the other only NULLs.
UPDATE lf_null_skip SET a = 2 WHERE a = 1 AND val IS NOT NULL;
UPDATE lf_null_skip SET a = 1 WHERE val IS NULL;
VACUUM ANALYZE lf_null_skip;
SELECT ord, lf_check(format('SELECT id FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val %s, id', ord))
FROM unnest(ARRAY['ASC NULLS LAST', 'ASC NULLS FIRST', 'DESC NULLS LAST', 'DESC NULLS FIRST']) ord ORDER BY 1;
SELECT c.value::bigint > 0 AS skipped_to_null FROM lf_counters(
	$$ SELECT id FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val $$) c
WHERE c.counter = 'Skips';

-- NULLs in one stream only: with NULLs first the other stream, already on a
-- value, is ahead and waits; with NULLs last the one still on values leads.
CREATE TABLE lf_null_one (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint);
INSERT INTO lf_null_one
SELECT g, CASE WHEN g % 10 = 0 THEN 2 ELSE 1 END, g % 2,
	CASE WHEN g % 10 = 0 THEN NULL ELSE g END
FROM generate_series(1, 3000) g;
CREATE INDEX lf_null_one_a ON lf_null_one (a, val NULLS FIRST);
CREATE INDEX lf_null_one_b ON lf_null_one (b, val NULLS FIRST);
CREATE INDEX lf_null_one_a2 ON lf_null_one (a, val);
CREATE INDEX lf_null_one_b2 ON lf_null_one (b, val);
ANALYZE lf_null_one;
SELECT cond, ord, lf_check(format('SELECT id FROM lf_null_one WHERE %s ORDER BY %s, id', cond, ord))
FROM unnest(ARRAY['a = 1 AND b = 0', 'a = 2 AND b = 0']) cond,
	unnest(ARRAY['val ASC NULLS LAST', 'val ASC NULLS FIRST', 'val DESC NULLS LAST', 'val DESC NULLS FIRST']) ord
ORDER BY 1, 2;
DROP TABLE lf_null_one;

-- The planner's estimate: the values of the streams do not overlap, the NULLs
-- do, so the node expects rows.
CREATE TABLE lf_null_range (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint);
INSERT INTO lf_null_range
SELECT g, CASE WHEN g <= 5000 THEN 1 ELSE 2 END, CASE WHEN g <= 5000 THEN 2 ELSE 1 END,
	g FROM generate_series(1, 10000) g;
INSERT INTO lf_null_range SELECT g, 1, 1, NULL FROM generate_series(10001, 12000) g;
CREATE INDEX lf_null_range_a ON lf_null_range (a, val);
CREATE INDEX lf_null_range_b ON lf_null_range (b, val);
ANALYZE lf_null_range;
CREATE FUNCTION lf_null_plan_rows(query text) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('leapfrog.force', 'on', true);
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	PERFORM set_config('leapfrog.force', 'off', true);
	RETURN (jsonb_path_query_first(plan,
		'$.** ? (@."Custom Plan Provider" == "Index Merge Intersect")')->>'Plan Rows')::float8;
END
$$;
SELECT lf_null_plan_rows($$ SELECT id FROM lf_null_range WHERE a = 1 AND b = 1 ORDER BY val $$) > 1
	AS expects_null_group;
DROP FUNCTION lf_null_plan_rows(text);
SELECT lf_check($$ SELECT id FROM lf_null_range WHERE a = 1 AND b = 1 ORDER BY val, id $$);
DROP TABLE lf_null_range;

-- Row versions: a value that becomes NULL and back, HOT updates in the NULL
-- group.
SELECT lf_check($$ SELECT id FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val, id LIMIT 20 $$);
UPDATE lf_null_skip SET note = 'hot' WHERE val IS NULL AND id % 3 = 0;
SELECT lf_check($$ SELECT id, note FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val, id $$);
UPDATE lf_null_skip SET val = 7 WHERE id = 49902;
SELECT lf_check($$ SELECT id, val FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val, id $$);
UPDATE lf_null_skip SET val = NULL WHERE id = 49902;
SELECT lf_check($$ SELECT id, val FROM lf_null_skip WHERE a = 1 AND b = 1 ORDER BY val, id $$);
DROP TABLE lf_null_skip;
