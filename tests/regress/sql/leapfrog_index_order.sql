--
-- leapfrog_index_order
--
-- DESC and NULLS FIRST index columns: every stream scans in the direction that
-- gives the query's order in its own index, so the streams of one node may
-- run in opposite directions.
--
SET max_parallel_workers_per_gather = 0;

-- A NOT NULL column: the position of NULLs does not matter, any index will do.
CREATE TABLE lf_ord (
	id bigint PRIMARY KEY,
	a integer NOT NULL,
	b integer NOT NULL,
	c integer NOT NULL,
	val bigint NOT NULL,
	txt text NOT NULL,
	deleted_at timestamptz
) WITH (autovacuum_enabled = false);
INSERT INTO lf_ord
SELECT g, abs(hashint8(g * 3)) % 10, abs(hashint8(g * 5)) % 10, abs(hashint8(g * 11)) % 4,
	abs(hashint8(g * 7)) % 4000,
	repeat('o', 200) || lpad((abs(hashint8(g * 7)) % 4000)::text, 8, '0'),
	CASE WHEN g % 9 = 0 THEN now() END
FROM generate_series(1, 40000) g;
CREATE INDEX lf_ord_a ON lf_ord (a, val);
CREATE INDEX lf_ord_b ON lf_ord (b, val DESC);
CREATE INDEX lf_ord_c ON lf_ord (c, val DESC NULLS LAST);
CREATE INDEX lf_ord_a_txt ON lf_ord (a, txt DESC);
CREATE INDEX lf_ord_b_txt ON lf_ord (b, txt NULLS FIRST);
CREATE INDEX lf_ord_live_desc ON lf_ord (val DESC) WHERE deleted_at IS NULL;
-- the whole table in the sample: a plan does not depend on which rows it took
SET default_statistics_target = 200;
ANALYZE lf_ord;
RESET default_statistics_target;

SET leapfrog.min_indexes = 3;
SELECT * FROM lf_plan($$ SELECT id FROM lf_ord WHERE a = 3 AND b = 2 AND c = 1 ORDER BY val LIMIT 5 $$);
RESET leapfrog.min_indexes;

-- Mixed directions, in both query directions, with duplicates and LIMIT.
SELECT cond, ord, lim, lf_check(format(
	'SELECT id FROM lf_ord WHERE %s ORDER BY %s, id %s', cond, ord, lim))
FROM unnest(ARRAY['a = 3 AND b = 2', 'a = 3 AND c = 1', 'b = 2 AND c = 1',
				  'a = 3 AND deleted_at IS NULL', 'b = 2 AND deleted_at IS NULL']) cond,
	unnest(ARRAY['val', 'val DESC', 'val NULLS FIRST', 'val DESC NULLS LAST']) ord,
	unnest(ARRAY['', 'LIMIT 6']) lim
ORDER BY 1, 2, 3;

-- By-reference values, skips in opposite directions.
SELECT ord, lf_check(format('SELECT id FROM lf_ord WHERE a = 3 AND b = 2 ORDER BY %s, id', ord))
FROM unnest(ARRAY['txt', 'txt DESC']) ord ORDER BY 1;

-- A stream ahead by far skips with the bound of the query's direction, which
-- nbtree applies to a DESC column by itself.
CREATE TABLE lf_ord_skip (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint NOT NULL)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_ord_skip
SELECT g, CASE WHEN g % 500 = 0 THEN 1 ELSE 2 END, CASE WHEN g % 2 = 0 THEN 1 ELSE 2 END, g
FROM generate_series(1, 50000) g;
CREATE INDEX lf_ord_skip_a ON lf_ord_skip (a, val DESC);
CREATE INDEX lf_ord_skip_b ON lf_ord_skip (b, val);
ANALYZE lf_ord_skip;
SELECT ord, lf_check(format('SELECT id FROM lf_ord_skip WHERE a = 1 AND b = 1 ORDER BY %s', ord))
FROM unnest(ARRAY['val', 'val DESC']) ord ORDER BY 1;
SELECT ord, c.value::bigint > 0 AS skipped
FROM unnest(ARRAY['val', 'val DESC']) ord,
	LATERAL lf_counters(format('SELECT id FROM lf_ord_skip WHERE a = 1 AND b = 1 ORDER BY %s', ord)) c
WHERE c.counter = 'Skips' ORDER BY 1;
DROP TABLE lf_ord_skip;

-- Parameters: a rescan runs the same directions.
SELECT lf_check($$ SELECT p.o, q.id FROM (VALUES (3), (4), (5)) p(o)
	CROSS JOIN LATERAL (SELECT id FROM lf_ord t WHERE t.a = p.o AND t.b = 2 ORDER BY val DESC, id LIMIT 3) q
	ORDER BY 1, 2 $$);
DROP TABLE lf_ord;

-- A nullable column: an index serves an order when its NULLs lie at the right
-- end in the direction that gives the values' order.
CREATE TABLE lf_ord_null (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint)
	WITH (autovacuum_enabled = false);
INSERT INTO lf_ord_null
SELECT g, abs(hashint8(g * 3)) % 10, abs(hashint8(g * 5)) % 10,
	CASE WHEN g % 5 = 0 THEN NULL ELSE abs(hashint8(g * 7)) % 2000 END
FROM generate_series(1, 20000) g;
-- ASC NULLS LAST and its mirror, DESC NULLS FIRST: both read one query order
CREATE INDEX lf_ord_null_a ON lf_ord_null (a, val);
CREATE INDEX lf_ord_null_b ON lf_ord_null (b, val DESC);
ANALYZE lf_ord_null;
SELECT ord, lf_check(format('SELECT id FROM lf_ord_null WHERE a = 3 AND b = 2 ORDER BY %s, id', ord))
FROM unnest(ARRAY['val ASC NULLS LAST', 'val DESC NULLS FIRST', 'val ASC NULLS FIRST', 'val DESC NULLS LAST']) ord
ORDER BY 1;
-- the other pair serves the other two
DROP INDEX lf_ord_null_a, lf_ord_null_b;
CREATE INDEX lf_ord_null_a ON lf_ord_null (a, val NULLS FIRST);
CREATE INDEX lf_ord_null_b ON lf_ord_null (b, val DESC NULLS LAST);
ANALYZE lf_ord_null;
SELECT ord, lf_check(format('SELECT id FROM lf_ord_null WHERE a = 3 AND b = 2 ORDER BY %s, id', ord))
FROM unnest(ARRAY['val ASC NULLS LAST', 'val DESC NULLS FIRST', 'val ASC NULLS FIRST', 'val DESC NULLS LAST']) ord
ORDER BY 1;
-- an index of each kind is no pair
DROP INDEX lf_ord_null_b;
CREATE INDEX lf_ord_null_b ON lf_ord_null (b, val DESC);
SELECT ord, lf_check(format('SELECT id FROM lf_ord_null WHERE a = 3 AND b = 2 ORDER BY %s, id', ord))
FROM unnest(ARRAY['val ASC NULLS LAST', 'val ASC NULLS FIRST']) ord
ORDER BY 1;
DROP TABLE lf_ord_null;
