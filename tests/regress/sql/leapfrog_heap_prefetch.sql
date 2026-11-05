-- leapfrog_heap_prefetch: heap pages asked for ahead when the Filter drops most rows.
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;
SET effective_io_concurrency = 16;

CREATE TABLE lf_hp (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	sort_key bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
-- customer 1 and product 1 share every 6th row; one in 100 of those is live
INSERT INTO lf_hp
SELECT g, g % 2, g % 3, g / 4,
	CASE WHEN g % 600 = 0 THEN NULL ELSE '2026-01-01'::timestamptz END,
	repeat('x', 100)
FROM generate_series(1, 60000) g;
CREATE INDEX lf_hp_customer_id ON lf_hp (customer_id, id);
CREATE INDEX lf_hp_product_id ON lf_hp (product_id, id);
CREATE INDEX lf_hp_customer_sort ON lf_hp (customer_id, sort_key);
CREATE INDEX lf_hp_product_sort ON lf_hp (product_id, sort_key);
VACUUM ANALYZE lf_hp;

-- the Filter drops most rows: pages are asked for ahead
SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id $$);
SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 7 $$);
SELECT counter, (value)::bigint > 0 AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$)
WHERE counter = 'Heap Prefetches';
SELECT counter, value FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$)
WHERE counter IN ('Matched TIDs', 'Heap Fetches');

SET leapfrog.prefetch = off;
SELECT count(*) AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$)
WHERE counter = 'Heap Prefetches';
SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
RESET leapfrog.prefetch;

-- no Filter: one match at a time, and a LIMIT reads no further for it
SELECT count(*) AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 ORDER BY id DESC LIMIT 5 $$)
WHERE counter = 'Heap Prefetches';
SELECT counter, value FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 ORDER BY id DESC LIMIT 5 $$)
WHERE counter IN ('Heap Fetches');

-- a Filter that passes most rows: the same
SELECT count(*) AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND payload IS NOT NULL ORDER BY id DESC LIMIT 5 $$)
WHERE counter = 'Heap Prefetches';
SELECT counter, value FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND payload IS NOT NULL ORDER BY id DESC LIMIT 5 $$)
WHERE counter IN ('Heap Fetches');

SELECT lf_check($$ SELECT sort_key, id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$, false);

-- rescans start with an empty queue and a target of 1
SELECT lf_check($$
	SELECT o.c, l.id FROM (VALUES (0), (1), (0)) o(c), LATERAL (
		SELECT id FROM lf_hp WHERE customer_id = o.c AND product_id = 0 AND deleted_at IS NULL
		ORDER BY id DESC LIMIT 3) l $$);

-- a cursor stopped with matches in the queue
SET leapfrog.enabled = off;
SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 4;
RESET leapfrog.enabled;
BEGIN;
SET LOCAL leapfrog.force = on;
EXPLAIN (COSTS OFF)
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC;
DECLARE lf_hp_cursor CURSOR FOR
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC;
FETCH 2 FROM lf_hp_cursor;
FETCH 2 FROM lf_hp_cursor;
CLOSE lf_hp_cursor;
COMMIT;

SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE $$);
SELECT counter, (value)::bigint > 0 AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE $$)
WHERE counter = 'Heap Prefetches';

BEGIN;
SET LOCAL work_mem = '64kB';
SELECT lf_check($$ SELECT sort_key, id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$, false);
ROLLBACK;

-- dead rows and HOT chains in the queue: every live row stays reachable through its index
UPDATE lf_hp SET payload = 'hot' WHERE customer_id = 0 AND product_id = 0 AND id % 1200 = 0;
DELETE FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND id % 7 = 0;
SELECT lf_check($$ SELECT id, payload FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT id, payload FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
SET leapfrog.enabled = off;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
SELECT count(*) AS by_customer_index FROM lf_hp WHERE customer_id = 0;
SELECT count(*) AS by_product_index FROM lf_hp WHERE product_id = 0;
RESET enable_seqscan;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) AS on_the_heap FROM lf_hp WHERE customer_id = 0;
SELECT count(*) AS on_the_heap FROM lf_hp WHERE product_id = 0;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
RESET leapfrog.enabled;

DROP TABLE lf_hp;

-- a LIMIT does not wait for a 200,000-entry stretch without a common value
CREATE TABLE lf_hp_gap (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_gap
SELECT g, CASE WHEN g > 200000 OR g % 2 = 0 THEN 0 ELSE 1 END,
	CASE WHEN g > 200000 OR g % 2 = 1 THEN 0 ELSE 1 END,
	CASE WHEN g > 200003 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 201000) g;
CREATE INDEX lf_hp_gap_customer ON lf_hp_gap (customer_id, id);
CREATE INDEX lf_hp_gap_product ON lf_hp_gap (product_id, id);
VACUUM ANALYZE lf_hp_gap;
SELECT lf_check($$ SELECT id FROM lf_hp_gap WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 $$);
SELECT counter, (value)::bigint < 20000 AS bounded FROM lf_counters($$
	SELECT id FROM lf_hp_gap WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 $$)
WHERE counter IN ('Outer Entries Read', 'Inner Entries Read');
DROP TABLE lf_hp_gap;

-- A queued row found dead must not get the outer scan's current entry marked dead.
CREATE TABLE lf_hp_kill (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_kill
SELECT g,
	CASE WHEN g = 1 OR g > 100000 OR g % 2 = 0 THEN 0 ELSE 1 END,
	CASE WHEN g = 1 OR g > 100000 OR g % 2 = 1 THEN 0 ELSE 1 END,
	CASE WHEN g > 100100 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 101000) g;
CREATE INDEX lf_hp_kill_customer ON lf_hp_kill (customer_id, id);
CREATE INDEX lf_hp_kill_product ON lf_hp_kill (product_id, id);
VACUUM ANALYZE lf_hp_kill;
DELETE FROM lf_hp_kill WHERE id > 100000 AND id <= 100100;
-- the node first: a stock Index Scan would mark the dead entries itself
SELECT counter, (value)::bigint > 0 AS asked FROM lf_counters($$
	SELECT id FROM lf_hp_kill WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$)
WHERE counter = 'Heap Prefetches';
SELECT lf_check($$ SELECT id FROM lf_hp_kill WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
SET leapfrog.enabled = off;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) AS by_customer_index FROM lf_hp_kill WHERE customer_id = 0;
SELECT count(*) AS by_product_index FROM lf_hp_kill WHERE product_id = 0;
RESET enable_seqscan;
SET enable_indexscan = off;
SELECT count(*) AS customer_on_the_heap FROM lf_hp_kill WHERE customer_id = 0;
SELECT count(*) AS product_on_the_heap FROM lf_hp_kill WHERE product_id = 0;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
RESET leapfrog.enabled;
DROP TABLE lf_hp_kill;

-- a Filter that drops one row in ten does not grow the target
CREATE TABLE lf_hp_few (id bigint PRIMARY KEY, customer_id bigint NOT NULL, product_id bigint NOT NULL);
INSERT INTO lf_hp_few SELECT g, g % 2, g % 3 FROM generate_series(1, 30000) g;
CREATE INDEX lf_hp_few_customer ON lf_hp_few (customer_id, id);
CREATE INDEX lf_hp_few_product ON lf_hp_few (product_id, id);
VACUUM ANALYZE lf_hp_few;
SELECT count(*) AS asked FROM lf_counters($$
	SELECT id FROM lf_hp_few WHERE customer_id = 0 AND product_id = 0 AND id % 10 <> 0 ORDER BY id DESC LIMIT 50 $$)
WHERE counter = 'Heap Prefetches';
SELECT lf_check($$ SELECT id FROM lf_hp_few WHERE customer_id = 0 AND product_id = 0 AND id % 10 <> 0 ORDER BY id DESC LIMIT 50 $$);
DROP TABLE lf_hp_few;

-- the same wait within one value of a non-unique sort column
CREATE TABLE lf_hp_group (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	sort_key bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_group
SELECT g, CASE WHEN g <= 200000 AND g % 2 = 1 THEN 1 ELSE 0 END,
	CASE WHEN g <= 200000 AND g % 2 = 0 THEN 1 ELSE 0 END,
	CASE WHEN g <= 200000 THEN 1 ELSE g END,
	CASE WHEN g > 200003 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 201000) g;
CREATE INDEX lf_hp_group_customer ON lf_hp_group (customer_id, sort_key);
CREATE INDEX lf_hp_group_product ON lf_hp_group (product_id, sort_key);
VACUUM ANALYZE lf_hp_group;
SELECT lf_check($$ SELECT id FROM lf_hp_group WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id LIMIT 3 $$, false);
SELECT counter, (value)::bigint < 3000 AS bounded FROM lf_counters($$
	SELECT id FROM lf_hp_group WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC LIMIT 3 $$)
WHERE counter = 'Outer Entries Read';
DROP TABLE lf_hp_group;

-- a small inner group, so that the outer lookups by TID alone count
CREATE TABLE lf_hp_lookup (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	sort_key bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_lookup
SELECT g, CASE WHEN g <= 100000 THEN 1 ELSE 0 END,
	CASE WHEN g > 100000 AND g <= 100100 THEN 1 ELSE 0 END,
	CASE WHEN g <= 100100 THEN 1 ELSE g END,
	CASE WHEN g > 100103 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 101100) g;
CREATE INDEX lf_hp_lookup_customer ON lf_hp_lookup (customer_id, sort_key);
CREATE INDEX lf_hp_lookup_product ON lf_hp_lookup (product_id, sort_key);
VACUUM ANALYZE lf_hp_lookup;
SELECT lf_check($$ SELECT id FROM lf_hp_lookup WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id LIMIT 3 $$, false);
SELECT value AS outer_index FROM lf_counters($$
	SELECT id FROM lf_hp_lookup WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC LIMIT 3 $$)
WHERE counter = 'Outer Index';
SELECT counter, (value)::bigint < 20000 AS bounded FROM lf_counters($$
	SELECT id FROM lf_hp_lookup WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC LIMIT 3 $$)
WHERE counter = 'Outer Entries Read';
DROP TABLE lf_hp_lookup;

-- invisible row versions are heap reads for nothing as well
CREATE TABLE lf_hp_dead (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_dead SELECT g, g % 2, g % 3, NULL FROM generate_series(1, 30000) g;
CREATE INDEX lf_hp_dead_customer ON lf_hp_dead (customer_id, id);
CREATE INDEX lf_hp_dead_product ON lf_hp_dead (product_id, id);
VACUUM ANALYZE lf_hp_dead;
-- an open snapshot keeps the entries from being marked dead between the runs
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM lf_hp_dead;
DELETE FROM lf_hp_dead WHERE id % 100 <> 0;
SELECT counter, (value)::bigint > 0 AS asked FROM lf_counters($$
	SELECT id FROM lf_hp_dead WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$)
WHERE counter = 'Heap Prefetches';
SELECT lf_check($$ SELECT id FROM lf_hp_dead WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC $$);
ROLLBACK;
DROP TABLE lf_hp_dead;

-- Queue fetched with the scan on an overflowing group's first entry: that entry stays live.
CREATE TABLE lf_hp_over (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	sort_key bigint NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_hp_over
SELECT g, 0, 0, CASE WHEN g <= 30000 THEN 0 ELSE g END,
	CASE WHEN g > 30500 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 31500) g;
CREATE INDEX lf_hp_over_customer ON lf_hp_over (customer_id, sort_key);
CREATE INDEX lf_hp_over_product ON lf_hp_over (product_id, sort_key);
VACUUM ANALYZE lf_hp_over;
DELETE FROM lf_hp_over WHERE id > 30000 AND id <= 30500;
BEGIN;
SET LOCAL work_mem = '64kB';
SELECT lf_check($$ SELECT id FROM lf_hp_over WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$, false);
SELECT counter, value FROM lf_counters($$
	SELECT id FROM lf_hp_over WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$)
WHERE counter IN ('Group Overflows', 'Inner Group Overflows');
COMMIT;
SET leapfrog.enabled = off;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
SELECT count(*) AS by_customer_index FROM lf_hp_over WHERE customer_id = 0;
SELECT count(*) AS by_product_index FROM lf_hp_over WHERE product_id = 0;
RESET enable_seqscan;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) AS on_the_heap FROM lf_hp_over;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
RESET leapfrog.enabled;

-- Three streams, one passed over without a fetch: every row stays reachable.
ALTER TABLE lf_hp_over ADD COLUMN kind int NOT NULL DEFAULT 1;
UPDATE lf_hp_over SET kind = 0 WHERE id > 30500 OR (id % 300 = 0 AND id <> 30000);
DELETE FROM lf_hp_over WHERE id > 30500 AND id <= 30600;
CREATE INDEX lf_hp_over_kind ON lf_hp_over (kind, sort_key);
VACUUM ANALYZE lf_hp_over;
INSERT INTO lf_hp_over SELECT g, 0, 0, g, '2026-01-01', 0 FROM generate_series(40001, 41000) g;
INSERT INTO lf_hp_over SELECT g, 0, 0, g, NULL, 0 FROM generate_series(39901, 40000) g;
DELETE FROM lf_hp_over WHERE id BETWEEN 39901 AND 40000;
BEGIN;
SET LOCAL work_mem = '64kB';
SET LOCAL leapfrog.min_indexes = 3;
SET LOCAL leapfrog.max_indexes = 3;
SELECT lf_check($$ SELECT id FROM lf_hp_over WHERE customer_id = 0 AND product_id = 0 AND kind = 0 AND deleted_at IS NOT NULL ORDER BY sort_key DESC, id $$, false);
SELECT counter, value FROM lf_counters($$
	SELECT id FROM lf_hp_over WHERE customer_id = 0 AND product_id = 0 AND kind = 0 AND deleted_at IS NOT NULL ORDER BY sort_key DESC, id $$)
WHERE counter IN ('Outer Index', 'Group Overflows');
COMMIT;
SET leapfrog.enabled = off;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
SELECT count(*) AS by_customer_index FROM lf_hp_over WHERE customer_id = 0;
SELECT count(*) AS by_product_index FROM lf_hp_over WHERE product_id = 0;
RESET enable_seqscan;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SELECT count(*) AS on_the_heap FROM lf_hp_over;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
RESET leapfrog.enabled;
DROP TABLE lf_hp_over;
