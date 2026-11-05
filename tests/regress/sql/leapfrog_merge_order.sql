-- leapfrog_merge_order: indexes merge when they read in the same order; the sparsest stream leads.
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_mo (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL,
	c integer NOT NULL, x integer NOT NULL, p integer NOT NULL, q integer NOT NULL)
	WITH (autovacuum_enabled = false);
-- a = 1 and b = 1 agree on 100 rows; c = 1 is half the table, the dense stream.
INSERT INTO lf_mo
SELECT g, (g % 500 = 0)::int, (g % 2000 = 0 OR g % 777 = 0)::int,
	(abs(hashint8(g * 5)) % 2 = 0)::int, g % 1000,
	abs(hashint8(g * 7)) % 4, abs(hashint8(g * 11)) % 4
FROM generate_series(1, 200000) g;
CREATE INDEX lf_mo_a ON lf_mo (a, id);
CREATE INDEX lf_mo_b ON lf_mo (b, id);
CREATE INDEX lf_mo_c ON lf_mo (c, id);
SET default_statistics_target = 1000;
ANALYZE lf_mo;
RESET default_statistics_target;

-- The dense stream reads only around the values a and b agree on.
SET leapfrog.min_indexes = 3;
SELECT lf_check($$ SELECT id FROM lf_mo WHERE a = 1 AND b = 1 AND c = 1 ORDER BY id $$);
SELECT max(value::bigint) BETWEEN 1000 AND 12000 AS few_entries
FROM lf_counters($$ SELECT id FROM lf_mo WHERE a = 1 AND b = 1 AND c = 1 ORDER BY id $$)
WHERE counter LIKE '%Entries Read%';
RESET leapfrog.min_indexes;

-- Columns after the sort column do not change its order.
DROP INDEX lf_mo_a, lf_mo_b;
CREATE INDEX lf_mo_a_tail ON lf_mo (a, id, x);
CREATE INDEX lf_mo_b_tail ON lf_mo (b, id, x);
SELECT * FROM lf_plan($$ SELECT id FROM lf_mo WHERE a = 1 AND b = 1 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT id FROM lf_mo WHERE a = 1 AND b = 1 ORDER BY id $$);
DROP INDEX lf_mo_a_tail, lf_mo_b_tail;

-- Partial indexes without equalities read in the order of the sort column too.
DROP INDEX lf_mo_c;
CREATE INDEX lf_mo_p ON lf_mo (id) WHERE p = 1;
CREATE INDEX lf_mo_q ON lf_mo (id) WHERE q = 1;
SELECT * FROM lf_plan($$ SELECT id FROM lf_mo WHERE p = 1 AND q = 1 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT id FROM lf_mo WHERE p = 1 AND q = 1 ORDER BY id LIMIT 500 $$);
SELECT lf_check($$ SELECT id FROM lf_mo WHERE p = 1 AND q = 1 ORDER BY id DESC LIMIT 500 $$);
DROP INDEX lf_mo_p, lf_mo_q;

-- A stream that needs a join parameter does not take away the set without parameters.
CREATE INDEX lf_mo_a ON lf_mo (a, id);
CREATE INDEX lf_mo_b ON lf_mo (b, id);
CREATE INDEX lf_mo_x ON lf_mo (x, id);
CREATE TABLE lf_mo_pick (x integer NOT NULL);
INSERT INTO lf_mo_pick VALUES (0);
ANALYZE lf_mo_pick;
SELECT * FROM lf_plan($$ SELECT t.id FROM lf_mo t JOIN lf_mo_pick k ON t.x = k.x
	WHERE t.a = 1 AND t.b = 1 ORDER BY t.id LIMIT 5 $$);
SELECT lf_check($$ SELECT t.id FROM lf_mo t JOIN lf_mo_pick k ON t.x = k.x
	WHERE t.a = 1 AND t.b = 1 ORDER BY t.id LIMIT 5 $$);
DROP TABLE lf_mo_pick;
DROP INDEX lf_mo_a, lf_mo_b, lf_mo_x;

-- (a) alone reads by TID, not in id order: no stream, BitmapAnd is the plan.
CREATE INDEX lf_mo_ax ON lf_mo (a);
CREATE INDEX lf_mo_bx ON lf_mo (b);
SELECT lf_check($$ SELECT id FROM lf_mo WHERE a = 1 AND b = 1 ORDER BY id $$);

DROP TABLE lf_mo;
