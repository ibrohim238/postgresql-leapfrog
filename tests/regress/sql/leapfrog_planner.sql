-- leapfrog_planner: planning work by the counts of leapfrog.trace_planner; estimates from statistics
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

-- Six equalities: what is left to fetch cannot pay for a fourth stream, so no range probe for it.
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl
WHERE f1 = 1 AND f2 = 2 AND f3 = 3 AND f4 = 4 AND f5 = 5 AND f6 = 6 ORDER BY id LIMIT 10;

-- leapfrog.min_indexes wants the larger set: it is costed all the same.
SET leapfrog.min_indexes = 4;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl
WHERE f1 = 1 AND f2 = 2 AND f3 = 3 AND f4 = 4 AND f5 = 5 AND f6 = 6 ORDER BY id LIMIT 10;
RESET leapfrog.min_indexes;

-- A stream with a predicate is not the outer one: the outer correlation is read once.
CREATE INDEX lf_pl_any ON lf_pl (id) WHERE f6 >= 0;
SET leapfrog.min_indexes = 3;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl WHERE f1 = 1 AND f2 = 2 AND f6 >= 0 ORDER BY id LIMIT 10;
RESET leapfrog.min_indexes;
DROP INDEX lf_pl_any;

-- An order other than the statistics' one: the selectivity functions decide.
CREATE INDEX lf_pl_f1_val ON lf_pl (f1, val text_pattern_ops);
CREATE INDEX lf_pl_f2_val ON lf_pl (f2, val text_pattern_ops);
SET leapfrog.force = on;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl WHERE f1 = 1 AND f2 = 2 ORDER BY val USING ~<~ LIMIT 10;
RESET leapfrog.force;
RESET leapfrog.trace_planner;
DROP TABLE lf_pl;

-- At the newest end one value has most of the rows.
CREATE TABLE lf_pl_group (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, ts integer NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_pl_group
SELECT g, abs(hashint8(g)) % 50, abs(hashint8(g * 3)) % 4,
	CASE WHEN g <= 200000 THEN 1000000 ELSE g END
FROM generate_series(1, 240000) g;
CREATE INDEX lf_pl_group_a ON lf_pl_group (a, ts);
CREATE INDEX lf_pl_group_b ON lf_pl_group (b, ts);
ANALYZE lf_pl_group;
CREATE FUNCTION lf_pl_startup(query text) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	RETURN (jsonb_path_query_first(plan,
		'$.** ? (@."Custom Plan Provider" == "Index Merge Intersect")')->>'Startup Cost')::float8;
END
$$;
SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_sort = off;
SELECT lf_pl_startup($$ SELECT id FROM lf_pl_group WHERE a = 7 AND b = 2 ORDER BY ts DESC LIMIT 100 $$) >
	5 * lf_pl_startup($$ SELECT id FROM lf_pl_group WHERE a = 7 AND b = 2 ORDER BY ts LIMIT 100 $$)
	AS first_group_is_charged;
RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET enable_sort;
SELECT lf_check($$ SELECT id FROM lf_pl_group WHERE a = 7 AND b = 2 ORDER BY ts DESC, id LIMIT 100 $$);
DROP FUNCTION lf_pl_startup(text);
DROP TABLE lf_pl_group;

-- a = 1 in the first 40 % of ids, b = 1 in the last 80 %, independent within their parts
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
-- the overlap 8001..16000 holds 2000 rows; independence over the table would say 4800
SELECT count(*) AS actual FROM lf_pl_range WHERE a = 1 AND b = 1;
SELECT lf_pl_plan_rows($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$)
	BETWEEN 1500 AND 2700 AS estimate_in_the_overlap;
SELECT lf_check($$ SELECT id FROM lf_pl_range WHERE a = 1 AND b = 1 ORDER BY id $$);
-- An overlap inside one histogram bin is estimated by value, not as nothing.
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

-- Live rows: the largest index, but rare for this customer (extended statistics).
CREATE TABLE lf_pl_pair (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
INSERT INTO lf_pl_pair
SELECT g, CASE WHEN g % 10 = 0 THEN 0 ELSE g % 9 + 1 END,
	CASE WHEN g % 20 = 0 OR g % 5 < 2 THEN 1 ELSE g % 50 + 2 END,
	CASE WHEN g % 10 = 0 AND g % 500 <> 0 THEN '2026-01-01'::timestamptz
		 WHEN g % 10 <> 0 AND g % 2 = 0 THEN '2026-01-01'::timestamptz END,
	repeat('x', 300)
FROM generate_series(1, 200000) g
ORDER BY hashint8(g);
CREATE INDEX lf_pl_pair_customer ON lf_pl_pair (customer_id, id);
CREATE INDEX lf_pl_pair_product ON lf_pl_pair (product_id, id);
CREATE INDEX lf_pl_pair_live ON lf_pl_pair (id) WHERE deleted_at IS NULL;
CREATE STATISTICS lf_pl_pair_stats (mcv) ON customer_id, deleted_at FROM lf_pl_pair;
VACUUM ANALYZE lf_pl_pair;
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_indexonlyscan = off;
SET LOCAL enable_bitmapscan = off;
-- two streams, so that the pass ends at the customer and the product
SET LOCAL leapfrog.max_indexes = 2;
EXPLAIN (COSTS OFF)
	SELECT id FROM lf_pl_pair WHERE customer_id = 0 AND product_id = 1 AND deleted_at IS NULL ORDER BY id DESC;
COMMIT;
BEGIN;
SET LOCAL leapfrog.max_indexes = 2;
SELECT lf_check($$ SELECT id FROM lf_pl_pair WHERE customer_id = 0 AND product_id = 1 AND deleted_at IS NULL ORDER BY id DESC $$);
SELECT line FROM lf_plan($$ SELECT id FROM lf_pl_pair WHERE customer_id = 0 AND product_id = 1 AND deleted_at IS NULL ORDER BY id DESC $$) AS line
WHERE line LIKE '%Stream on%';
COMMIT;
-- a parameterized customer: the plan keeps the nested loop into the set with the parameter
EXPLAIN (COSTS OFF)
SELECT o.c, l.id FROM (VALUES (0::bigint), (1)) o(c), LATERAL (
	SELECT id FROM lf_pl_pair WHERE customer_id = o.c AND product_id = 1 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3) l;
SELECT lf_check($$ SELECT o.c, l.id FROM (VALUES (0::bigint), (1)) o(c), LATERAL (
	SELECT id FROM lf_pl_pair WHERE customer_id = o.c AND product_id = 1 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3) l $$);
DROP TABLE lf_pl_pair;

-- Pairs are priced only with an MCV list on two condition columns (the sets in the NOTICE).
CREATE TABLE lf_pl_gate (id bigint PRIMARY KEY, a int NOT NULL, b int NOT NULL, e int NOT NULL, c int, d int);
INSERT INTO lf_pl_gate SELECT g, g % 7, g % 11, g % 13, g % 3, g % 5 FROM generate_series(1, 20000) g;
CREATE INDEX ON lf_pl_gate (a, id);
CREATE INDEX ON lf_pl_gate (b, id);
CREATE INDEX ON lf_pl_gate (e, id);
CREATE STATISTICS lf_pl_gate_other (mcv) ON c, d FROM lf_pl_gate;
CREATE STATISTICS lf_pl_gate_kind (ndistinct) ON a, b FROM lf_pl_gate;
VACUUM ANALYZE lf_pl_gate;
SET leapfrog.trace_planner = on;
SET leapfrog.force = on;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl_gate WHERE a = 1 AND b = 1 AND e = 1 ORDER BY id;
CREATE STATISTICS lf_pl_gate_cover (mcv) ON a, e FROM lf_pl_gate;
ANALYZE lf_pl_gate;
EXPLAIN (COSTS OFF) SELECT id FROM lf_pl_gate WHERE a = 1 AND b = 1 AND e = 1 ORDER BY id;
RESET leapfrog.force;
RESET leapfrog.trace_planner;
DROP TABLE lf_pl_gate;

-- Partial index entries correlated with its predicate: 18,000 for this customer, not 2,000.
CREATE TABLE lf_pl_corr (id bigint PRIMARY KEY, customer_id bigint NOT NULL, product_id bigint NOT NULL, deleted_at timestamptz);
INSERT INTO lf_pl_corr
SELECT g, CASE WHEN g % 10 = 0 THEN 0 ELSE g % 9 + 1 END, g % 2,
	CASE WHEN g % 10 = 0 AND g % 100 <> 0 THEN NULL
		 WHEN g % 100 = 1 THEN NULL
		 ELSE '2026-01-01'::timestamptz END
FROM generate_series(1, 200000) g;
CREATE INDEX lf_pl_corr_live ON lf_pl_corr (customer_id, id) WHERE deleted_at IS NULL;
CREATE INDEX lf_pl_corr_product ON lf_pl_corr (product_id, id);
CREATE STATISTICS lf_pl_corr_stats (mcv) ON customer_id, deleted_at FROM lf_pl_corr;
VACUUM ANALYZE lf_pl_corr;
CREATE FUNCTION lf_pl_entries(query text, index_name text) RETURNS float8 LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
BEGIN
	PERFORM set_config('leapfrog.force', 'on', true);
	EXECUTE 'EXPLAIN (VERBOSE, FORMAT JSON) ' || query INTO plan;
	RETURN (SELECT (s ->> 'Entries Estimated')::float8
			FROM jsonb_path_query(plan, 'strict $[0].Plan.**') AS n,
				jsonb_array_elements(n -> 'Index Streams') AS s
			WHERE s ->> 'Index Name' = index_name);
END
$$;
SELECT lf_pl_entries($$ SELECT id FROM lf_pl_corr WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$,
	'lf_pl_corr_live') BETWEEN 13000 AND 23000 AS entries_near_18000;
SELECT lf_check($$ SELECT id FROM lf_pl_corr WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
DROP FUNCTION lf_pl_entries(text, text);
DROP TABLE lf_pl_corr;
