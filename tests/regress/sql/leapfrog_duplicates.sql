--
-- leapfrog_duplicates
--
-- A non-unique sort column: the entries of one value are matched by TID.
-- The output order within a group of equal keys is not defined, so the
-- multiset of rows is compared (lf_check with ordered = false) and the
-- order of the sort key itself is checked separately.
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_dup (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	group_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);

-- 24000 rows, 8 owners, 600 groups of 40 rows; the groups are interleaved
-- across owners, and in every group some rows are deleted.
INSERT INTO lf_dup (id, owner_id, group_id, deleted_at, payload)
SELECT g,
	g % 8,
	g % 600,
	CASE WHEN g % 5 IN (0, 1) THEN '2026-01-01'::timestamptz END,
	'p' || g
FROM generate_series(1, 24000) g
ORDER BY (g * 7919) % 24000;

CREATE INDEX lf_dup_owner_group ON lf_dup (owner_id, group_id);
CREATE INDEX lf_dup_live_group ON lf_dup (group_id) WHERE deleted_at IS NULL;
CREATE INDEX lf_dup_deleted_group ON lf_dup (group_id) WHERE deleted_at IS NOT NULL;
ANALYZE lf_dup;

SELECT * FROM lf_plan($$
SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id LIMIT 100 $$);

SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id DESC $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NOT NULL ORDER BY group_id $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NOT NULL ORDER BY group_id DESC $$, false);

-- With a secondary sort key the order is deterministic again: the sort
-- node above the scan is fed the same rows.
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id, id $$);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id DESC, id DESC LIMIT 50 $$);

-- LIMIT inside a group of equal keys: the rows returned are some rows of
-- the first groups; count and key order must agree with the standard plan.
SELECT lf_check($$ SELECT group_id FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id LIMIT 7 $$);
SELECT lf_check($$ SELECT group_id FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id DESC LIMIT 7 $$);
SELECT lf_check($$ SELECT group_id FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NOT NULL ORDER BY group_id DESC LIMIT 1 $$);

-- The key sequence produced by the scan itself is monotonic.
SET leapfrog.force = on;
SELECT count(*) AS out_of_order FROM (
	SELECT group_id, lag(group_id) OVER () AS prev FROM (
		SELECT group_id FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id
	) s
) t WHERE prev > group_id;
SELECT count(*) AS out_of_order FROM (
	SELECT group_id, lag(group_id) OVER () AS prev FROM (
		SELECT group_id FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id DESC
	) s
) t WHERE prev < group_id;
RESET leapfrog.force;

-- Every matched TID is a real match: the counters agree with the result.
SELECT * FROM lf_counters($$
SELECT * FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL ORDER BY group_id $$);
SELECT count(*) FROM lf_dup WHERE owner_id = 3 AND deleted_at IS NULL;

-- Many entries per value: 3 groups, 8000 rows each, every other row live.
TRUNCATE lf_dup;
INSERT INTO lf_dup (id, owner_id, group_id, deleted_at, payload)
SELECT g, g % 4, g % 3, CASE WHEN g % 2 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
FROM generate_series(1, 24000) g;
ANALYZE lf_dup;

SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id DESC LIMIT 1000 $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY group_id, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id DESC LIMIT 1000 $$);

-- Dead index entries: updates and deletes without VACUUM leave old
-- versions in both indexes; they are matched by TID and filtered by
-- visibility, never returned twice.
UPDATE lf_dup SET payload = payload || '!' WHERE id % 3 = 0;
UPDATE lf_dup SET deleted_at = NULL WHERE id % 10 = 0;
UPDATE lf_dup SET deleted_at = '2026-02-01' WHERE id % 10 = 1;
UPDATE lf_dup SET group_id = (group_id + 1) % 3 WHERE id % 10 = 2;
DELETE FROM lf_dup WHERE id % 10 = 3;
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY group_id DESC $$, false);
SELECT lf_check($$ SELECT * FROM lf_dup WHERE owner_id = 1 AND deleted_at IS NULL ORDER BY group_id, id LIMIT 500 $$);

DROP TABLE lf_dup;
