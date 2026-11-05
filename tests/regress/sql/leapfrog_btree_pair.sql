-- leapfrog_btree_pair: two ordinary composite indexes, (customer_id, id) and (product_id, id)
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_pair (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
-- Every customer/product combination present; out of id order.
INSERT INTO lf_pair (id, customer_id, product_id, deleted_at, payload)
SELECT g, g % 50, g % 7,
	CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
FROM generate_series(1, 50000) g
ORDER BY (g * 7919) % 50000;
CREATE INDEX lf_pair_customer_id ON lf_pair (customer_id, id);
CREATE INDEX lf_pair_product_id ON lf_pair (product_id, id);
ANALYZE lf_pair;

-- Both equalities are enforced by the scans: no Filter.
SELECT * FROM lf_plan($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4
ORDER BY id DESC LIMIT 20 $$);

SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id DESC $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id LIMIT 1 $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 999 AND product_id = 4 ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 999 ORDER BY id DESC $$);

SELECT * FROM lf_counters($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id DESC $$);
SELECT count(*) FROM lf_pair WHERE customer_id = 3 AND product_id = 4;

SELECT * FROM lf_plan($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

-- A partial index serves both the product and the deleted_at condition.
CREATE INDEX lf_pair_live_product_id ON lf_pair (product_id, id) WHERE deleted_at IS NULL;
ANALYZE lf_pair;
SELECT * FROM lf_plan($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC $$);
DROP INDEX lf_pair_live_product_id;

SET leapfrog.force = on;
SET plan_cache_mode = force_generic_plan;
PREPARE lf_pair_q (bigint, integer) AS
	SELECT id FROM lf_pair WHERE customer_id = $1 AND product_id = $2
	ORDER BY id DESC LIMIT 3;
EXPLAIN (COSTS OFF) EXECUTE lf_pair_q(3, 4);
EXECUTE lf_pair_q(3, 4);
EXECUTE lf_pair_q(10, 1);
EXECUTE lf_pair_q(3, NULL);
DEALLOCATE lf_pair_q;
RESET plan_cache_mode;
RESET leapfrog.force;

-- The inner equality value is a nestloop parameter.
SELECT * FROM lf_plan($$
SELECT v.p, s.id
FROM (VALUES (1::bigint), (4), (999)) v (p),
	LATERAL (SELECT id FROM lf_pair
			 WHERE customer_id = 3 AND product_id = v.p
			 ORDER BY id DESC LIMIT 3) s $$);
SELECT lf_check($$
SELECT v.p, s.id
FROM (VALUES (1::bigint), (4), (999)) v (p),
	LATERAL (SELECT id FROM lf_pair
			 WHERE customer_id = 3 AND product_id = v.p
			 ORDER BY id DESC LIMIT 3) s $$);

-- No pair: the primary key alone narrows nothing down.
BEGIN;
DROP INDEX lf_pair_product_id;
SELECT * FROM lf_plan($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id LIMIT 20 $$);
ROLLBACK;
-- No pair: (customer_id, product_id, id) enforces both equalities alone.
BEGIN;
DROP INDEX lf_pair_product_id;
CREATE INDEX lf_pair_customer_product_id ON lf_pair (customer_id, product_id, id);
SELECT * FROM lf_plan($$
SELECT * FROM lf_pair WHERE customer_id = 3 AND product_id = 4 ORDER BY id LIMIT 20 $$);
ROLLBACK;

-- A group overflowing work_mem: the fallback must check product_id, which is not in the Filter.
CREATE TABLE lf_pair_dup (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	grp bigint NOT NULL
);
-- 15,000 rows of product 2: more than the 10,922 TIDs that fit into 64kB.
INSERT INTO lf_pair_dup
SELECT g, 1, CASE WHEN g % 4 = 0 THEN 3 ELSE 2 END, 1
FROM generate_series(1, 20000) g;
CREATE INDEX lf_pair_dup_customer_grp ON lf_pair_dup (customer_id, grp);
CREATE INDEX lf_pair_dup_product_grp ON lf_pair_dup (product_id, grp);
ANALYZE lf_pair_dup;

SET work_mem = '64kB';
SELECT * FROM lf_plan($$
SELECT * FROM lf_pair_dup WHERE customer_id = 1 AND product_id = 2 ORDER BY grp $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_pair_dup WHERE customer_id = 1 AND product_id = 2 ORDER BY grp $$)
WHERE counter IN ('Outer Index', 'Inner Index', 'Group Overflows',
				  'Rows Checked by Predicate', 'Actual Rows');
SELECT lf_check($$ SELECT * FROM lf_pair_dup WHERE customer_id = 1 AND product_id = 2 ORDER BY grp $$, false);
SELECT lf_check($$ SELECT * FROM lf_pair_dup WHERE customer_id = 1 AND product_id = 3 ORDER BY grp DESC $$, false);
RESET work_mem;
SELECT lf_check($$ SELECT * FROM lf_pair_dup WHERE customer_id = 1 AND product_id = 2 ORDER BY grp $$, false);

DROP TABLE lf_pair_dup;
DROP TABLE lf_pair;
