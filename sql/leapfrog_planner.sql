--
-- leapfrog_planner
--
-- The work planning does, by the counts of leapfrog.trace_planner: time is not
-- something a test can check.  One pass over the candidates; statistics, range
-- and correlation read once however many sets ask; no costing for a stream that
-- cannot pay for itself.
--
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_pl (id bigint PRIMARY KEY, f1 integer NOT NULL, f2 integer NOT NULL,
	f3 integer NOT NULL, f4 integer NOT NULL, f5 integer NOT NULL, f6 integer NOT NULL,
	val text NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_pl
SELECT g, abs(hashint8(g * 64 + 1)) % 100, abs(hashint8(g * 64 + 2)) % 100,
	abs(hashint8(g * 64 + 3)) % 100, abs(hashint8(g * 64 + 4)) % 100,
	abs(hashint8(g * 64 + 5)) % 100, abs(hashint8(g * 64 + 6)) % 100,
	md5(g::text)
FROM generate_series(1, 20000) g;
CREATE INDEX lf_pl_f1 ON lf_pl (f1, id);
CREATE INDEX lf_pl_f2 ON lf_pl (f2, id);
CREATE INDEX lf_pl_f3 ON lf_pl (f3, id);
CREATE INDEX lf_pl_f4 ON lf_pl (f4, id);
CREATE INDEX lf_pl_f5 ON lf_pl (f5, id);
CREATE INDEX lf_pl_f6 ON lf_pl (f6, id);
SET default_statistics_target = 200;
ANALYZE lf_pl;
RESET default_statistics_target;

SET leapfrog.trace_planner = on;

-- A pair: one range probe per stream, statistics and correlation once.
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl WHERE f1 = 1 AND f2 = 2 ORDER BY id LIMIT 10;

-- Six equalities: the third stream makes the set dearer, and what is left to
-- fetch cannot pay for a fourth: no set, no range probe for it.
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl
WHERE f1 = 1 AND f2 = 2 AND f3 = 3 AND f4 = 4 AND f5 = 5 AND f6 = 6 ORDER BY id LIMIT 10;

-- leapfrog.min_indexes wants the larger set: it is costed all the same.
SET leapfrog.min_indexes = 4;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl
WHERE f1 = 1 AND f2 = 2 AND f3 = 3 AND f4 = 4 AND f5 = 5 AND f6 = 6 ORDER BY id LIMIT 10;
RESET leapfrog.min_indexes;

-- A stream with a predicate does not become the outer one: the set that follows
-- has the same outer stream, whose correlation is read once.
CREATE INDEX lf_pl_any ON lf_pl (id) WHERE f6 >= 0;
SET leapfrog.min_indexes = 3;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl WHERE f1 = 1 AND f2 = 2 AND f6 >= 0 ORDER BY id LIMIT 10;
RESET leapfrog.min_indexes;
DROP INDEX lf_pl_any;

-- Statistics in another order than the query's cannot tell: the selectivity
-- functions do.
CREATE INDEX lf_pl_f1_val ON lf_pl (f1, val text_pattern_ops);
CREATE INDEX lf_pl_f2_val ON lf_pl (f2, val text_pattern_ops);
SET leapfrog.force = on;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl WHERE f1 = 1 AND f2 = 2 ORDER BY val USING ~<~ LIMIT 10;
RESET leapfrog.force;
RESET leapfrog.trace_planner;
DROP TABLE lf_pl;

-- The estimate from the statistics read once, where the streams hold parts of
-- the sort column's range: 40000 rows, a = 1 in the first 40 %, b = 1 in the last
-- 80 %, each every other row of its part in a pattern that keeps them independent.
CREATE TABLE lf_pl_range (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_pl_range
SELECT g, (g <= 16000 AND abs(hashint8(g)) % 2 = 0)::int,
	(g > 8000 AND abs(hashint8(g * 3)) % 2 = 0)::int
FROM generate_series(1, 40000) g;
CREATE INDEX lf_pl_range_a ON lf_pl_range (a, id);
CREATE INDEX lf_pl_range_b ON lf_pl_range (b, id);
SET default_statistics_target = 200;
ANALYZE lf_pl_range;
RESET default_statistics_target;
CREATE FUNCTION lf_pl_plan_rows(query text) RETURNS float8
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
-- the overlap is 8001..16000: 2000 rows there, far from the 4800 of independence
-- over the whole table
SELECT count(*) AS actual FROM lf_pl_range WHERE a = 1 AND b = 1;
SELECT lf_pl_plan_rows($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$)
	BETWEEN 1500 AND 2700 AS estimate_in_the_overlap;
SELECT lf_check($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$);
-- An overlap inside one bin of the histogram, 100 ids of its 200: by value, not
-- nothing.
UPDATE lf_pl_range SET a = (id <= 20100 AND abs(hashint8(id)) % 2 = 0)::int,
	b = (id > 20000 AND abs(hashint8(id * 3)) % 2 = 0)::int;
VACUUM lf_pl_range;
SET default_statistics_target = 200;
ANALYZE lf_pl_range;
RESET default_statistics_target;
SELECT count(*) AS actual FROM lf_pl_range WHERE a = 1 AND b = 1;
SELECT lf_pl_plan_rows($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$)
	BETWEEN 8 AND 80 AS estimate_inside_a_bin;
SELECT lf_check($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$);
DROP FUNCTION lf_pl_plan_rows(text);
DROP TABLE lf_pl_range;
