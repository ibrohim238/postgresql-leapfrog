-- leapfrog_example: the README example verbatim, so its plans and counters cannot drift.
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

-- EXPLAIN ANALYZE without timings, buffers and sort memory.
CREATE FUNCTION lf_explain_analyze(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
BEGIN
	FOR line IN EXECUTE
		'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF) ' || query
	LOOP
		RETURN NEXT regexp_replace(line, 'Memory: \d+kB', 'Memory: NkB');
	END LOOP;
END
$$;

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    deleted_at  timestamptz,
    payload     text
);
INSERT INTO orders
SELECT g, abs(hashint8(g)) % 200,
       CASE WHEN g <= 400000 AND abs(hashint8(g * 7 + 3)) % 5 = 0
            THEN '2026-01-01'::timestamptz END,
       repeat('x', 100)
FROM generate_series(1, 1000000::bigint) g;

CREATE INDEX idx_orders_customer_id ON orders (customer_id, id);
CREATE INDEX idx_orders_active_id   ON orders (id) WHERE deleted_at IS NULL;
CREATE INDEX idx_orders_deleted_id  ON orders (id) WHERE deleted_at IS NOT NULL;
VACUUM ANALYZE orders;

-- With random_page_cost = 1.1 (data in memory or on SSD) the planner picks the node by cost.
SET random_page_cost = 1.1;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
RESET random_page_cost;

-- With the default random_page_cost = 4 as well.
SELECT * FROM lf_plan_costs($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);

-- Stock plan: the partial index, filtering the customer on every deleted row.
SET leapfrog.enabled = off;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
RESET leapfrog.enabled;

-- BitmapAnd: both indexes read completely, every match fetched, then sorted.
SET leapfrog.enabled = off;
SET enable_indexscan = off;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
RESET enable_indexscan;

-- Index Scan on (customer_id, id), filtering deleted_at on every row of the customer.
BEGIN;
DROP INDEX idx_orders_deleted_id;
SET LOCAL enable_bitmapscan = off;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
ROLLBACK;
RESET leapfrog.enabled;

-- Without LIMIT the planner's pick depends on the ANALYZE sample: only the node's work is checked.
SELECT * FROM lf_counters($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC $$);

SELECT lf_check($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC $$);

DROP TABLE orders;
DROP FUNCTION lf_explain_analyze(text);
