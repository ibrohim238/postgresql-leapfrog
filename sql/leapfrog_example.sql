--
-- leapfrog_example
--
-- The example of the README, verbatim: the same data and queries, so that
-- the plans and counters shown there cannot drift from the code.  Timings
-- and buffer counts differ between machines and are not checked here; the
-- plan shapes and the row and entry counts are deterministic.
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

-- 1,000,000 orders of 200 customers.  Recent orders are live; one in five
-- of the oldest 400,000 is deleted.  A deterministic hash spreads customers
-- and deletions independently of each other.
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

-- The latest 100 deleted orders of one customer.

-- With page costs for data in memory or on SSD (the usual
-- random_page_cost = 1.1), the planner picks the node by cost.
SET random_page_cost = 1.1;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
RESET random_page_cost;

-- With the default random_page_cost = 4 it keeps the stock plan: an Index
-- Scan on the partial index that filters the customer on every deleted row.
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);

-- BitmapAnd: both indexes read completely, every match fetched, then sorted.
SET leapfrog.enabled = off;
SET enable_indexscan = off;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
RESET enable_indexscan;

-- An Index Scan on (customer_id, id) that filters deleted_at on every row of
-- the customer (the partial index is out of the way in this transaction).
BEGIN;
DROP INDEX idx_orders_deleted_id;
SET LOCAL enable_bitmapscan = off;
SELECT * FROM lf_explain_analyze($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
ROLLBACK;
RESET leapfrog.enabled;

-- Without LIMIT the whole result is needed.  The node and BitmapAnd + Sort
-- are estimated close to each other, so which one the planner picks depends
-- on the ANALYZE sample and is not checked; the node's work is.
SELECT * FROM lf_counters($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC $$);

-- Same rows as the standard plans, with and without LIMIT.
SELECT lf_check($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC LIMIT 100 $$);
SELECT lf_check($$
SELECT * FROM orders WHERE customer_id = 100 AND deleted_at IS NOT NULL
ORDER BY id DESC $$);

DROP TABLE orders;
DROP FUNCTION lf_explain_analyze(text);
