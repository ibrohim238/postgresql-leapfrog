-- leapfrog_overflow: a TID group larger than work_mem; forced, the fallback must lose and duplicate nothing.
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_overflow (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	group_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
) WITH (autovacuum_enabled = false);	-- the counters below include dead entries

-- 64kB holds about 10,900 TIDs; each group has 13,333 live entries, so both overflow.
INSERT INTO lf_overflow (id, owner_id, group_id, deleted_at, payload)
SELECT g, g % 2, g % 2 + 100, CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
FROM generate_series(1, 40000) g;

CREATE INDEX lf_overflow_owner_group ON lf_overflow (owner_id, group_id);
CREATE INDEX lf_overflow_live_group ON lf_overflow (group_id) WHERE deleted_at IS NULL;
ANALYZE lf_overflow;

SET work_mem = '64kB';

-- Not forced: the estimated group does not fit, the path is not offered.
SET leapfrog.force = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id;

-- Forced: the scan runs and overflows on the group.
SELECT * FROM lf_plan($$
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id $$);
SELECT count(*) FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL;

SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id $$, false);
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id DESC $$, false);
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id DESC, id DESC LIMIT 100 $$);
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 0 AND deleted_at IS NULL ORDER BY group_id $$, false);

-- A condition stricter than the predicate still filters after the fallback.
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL AND id % 7 = 0 ORDER BY group_id, id $$);

-- Dead entries in an overflowed group
UPDATE lf_overflow SET payload = payload || '!' WHERE id % 4 = 0;
UPDATE lf_overflow SET deleted_at = NULL WHERE id % 9 = 0;
DELETE FROM lf_overflow WHERE id % 11 = 0;
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);

-- A mix: one small group and one that overflows.
UPDATE lf_overflow SET group_id = 200 + id WHERE group_id = 101 AND id % 1000 = 1;
ANALYZE lf_overflow;
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);

-- With enough work_mem the same query matches by TID.
SET work_mem = '4MB';
SELECT * FROM lf_counters($$
SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);
SELECT lf_check($$ SELECT * FROM lf_overflow WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id $$);

RESET work_mem;
DROP TABLE lf_overflow;

-- The group estimate uses the table's distinct sort values: a unique column fits into 64kB
-- however selective the query. Stock scans disabled: the node is chosen by its own cost.
CREATE TABLE lf_overflow_unique (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	flag boolean NOT NULL
);
INSERT INTO lf_overflow_unique SELECT g, g % 20000, true FROM generate_series(1, 200000) g;
CREATE INDEX lf_overflow_unique_owner_id ON lf_overflow_unique (owner_id, id);
CREATE INDEX lf_overflow_unique_flag_id ON lf_overflow_unique (id) WHERE flag;
ANALYZE lf_overflow_unique;
SET work_mem = '64kB';
SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
EXPLAIN (COSTS OFF)
SELECT * FROM lf_overflow_unique WHERE owner_id = 7 AND flag ORDER BY id;
RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;
SELECT lf_check($$ SELECT * FROM lf_overflow_unique WHERE owner_id = 7 AND flag ORDER BY id $$);
RESET work_mem;
DROP TABLE lf_overflow_unique;
