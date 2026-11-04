--
-- leapfrog_heap_prefetch
--
-- Where the node's Filter drops most rows, matches are gathered ahead and their
-- heap pages asked for before they are fetched, in the order found.  Without a
-- Filter, or where it drops few rows, one match is fetched at a time, so that a
-- LIMIT reads no further in the indexes.
--
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

-- off turns it off
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

-- a non-unique sort column: the rows of one value keep their matching
SELECT lf_check($$ SELECT sort_key, id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$, false);

-- rescans start with an empty queue and a target of 1
SELECT lf_check($$
	SELECT o.c, l.id FROM (VALUES (0), (1), (0)) o(c), LATERAL (
		SELECT id FROM lf_hp WHERE customer_id = o.c AND product_id = 0 AND deleted_at IS NULL
		ORDER BY id DESC LIMIT 3) l $$);

-- a cursor stopped with matches in the queue returns the rows of the stock plan
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

-- FOR UPDATE: the same rows through the node, with the queue in use
SELECT lf_check($$ SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE $$);
SELECT counter, (value)::bigint > 0 AS asked FROM lf_counters($$
	SELECT id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE $$)
WHERE counter = 'Heap Prefetches';

-- a group overflowing work_mem is fetched on its own, after what is queued
BEGIN;
SET LOCAL work_mem = '64kB';
SELECT lf_check($$ SELECT sort_key, id FROM lf_hp WHERE customer_id = 0 AND product_id = 0 AND deleted_at IS NULL ORDER BY sort_key DESC, id $$, false);
ROLLBACK;

-- dead rows and HOT chains among the queued matches; an entry the queue found
-- dead must not get the entry the scan stands on marked dead: every live row
-- stays reachable through its index afterwards
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

-- rows found wait for no long stretch: the rows the Filter drops grow the target,
-- then three pass, then the streams hold no common value for 200,000 entries
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

-- A queued row found dead must mark no other entry.  From the top: rows the Filter
-- drops, which grow the target; rows deleted, which end up in the queue; then a stretch
-- without a common value, where the queue is fetched with the outer scan already on a
-- live entry of another row.  That entry would be marked dead on the next step, and
-- the row lost to every scan of the index: the counts must stay equal to the heap's.
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

-- row versions the snapshot does not see are heap reads for nothing as well
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

-- The queue is fetched ahead of an overflowing group with the scan already on
-- that group's first entry: a queued row found dead must not mark that entry.
CREATE TABLE lf_hp_over (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	sort_key bigint NOT NULL,
	deleted_at timestamptz
);
-- from the top: rows the Filter drops, then rows to delete, then one large group
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

-- Three streams, one group overflowing, one stream without the entry the scan
-- stands on, so that it is passed over without a fetch: every row stays reachable
-- through both indexes.
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
