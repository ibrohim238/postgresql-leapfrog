--
-- leapfrog_skip
--
-- Skip-ahead: a scan that lags behind the other side for INTERSECT_SKIP_AFTER
-- entries descends its B-tree again straight to the other side's value
-- (sortcol >= value forward, <= value backward).  The entries in between
-- cannot match; entries equal to the value must not be skipped, which
-- matters when the sort column is not unique.  Results are compared with the
-- standard plans in both directions, with LIMIT and across rescans.
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_skip (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	grp bigint NOT NULL,
	deleted_at timestamptz
);
-- Owner 1 has every other row; deleted rows come in clusters of 50 ids
-- every 10,000 ids, plus one dense block of 20,000 deleted ids.  Between two
-- clusters owner 1 has about 5,000 entries, more than INTERSECT_SKIP_AFTER
-- (1024), so the owner side skips across every gap.  Owner 2 has rows only
-- every 5,000th id, so inside the dense block the deleted side lags by
-- 5,000 entries and skips.  grp repeats every value 3 times.
INSERT INTO lf_skip
SELECT g, CASE WHEN g % 2 = 0 THEN 1 WHEN g % 5000 = 25 THEN 2 ELSE 3 END, g / 3,
	CASE WHEN g % 10000 < 50 OR g BETWEEN 100001 AND 120000
		THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 200000) g;
CREATE INDEX lf_skip_owner_id ON lf_skip (owner_id, id);
CREATE INDEX lf_skip_deleted_id ON lf_skip (id) WHERE deleted_at IS NOT NULL;
CREATE INDEX lf_skip_owner_grp ON lf_skip (owner_id, grp);
CREATE INDEX lf_skip_deleted_grp ON lf_skip (grp) WHERE deleted_at IS NOT NULL;
ANALYZE lf_skip;

-- both directions, with and without LIMIT
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id LIMIT 30 $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC LIMIT 30 $$);

-- the scans did skip, and read far fewer entries than the indexes hold
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Outer Entries Read', 'Inner Entries Read', 'Matched TIDs', 'Skips');
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC $$)
WHERE counter IN ('Outer Entries Read', 'Inner Entries Read', 'Matched TIDs', 'Skips');

-- owner 2: the deleted side lags and skips
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC $$)
WHERE counter IN ('Outer Entries Read', 'Inner Entries Read', 'Matched TIDs', 'Skips');

-- a non-unique sort column: the value skipped to must keep all its entries
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp $$, false);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp DESC $$, false);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp, id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp $$)
WHERE counter IN ('Outer Index', 'Inner Index', 'Matched TIDs', 'Skips');

-- rescans start without a bound: every outer row gets the full answer
SELECT lf_check($$
SELECT v.o, s.id
FROM (VALUES (1::bigint), (2), (1)) v (o),
	LATERAL (SELECT id FROM lf_skip
			 WHERE owner_id = v.o AND deleted_at IS NOT NULL
			 ORDER BY id DESC LIMIT 40) s $$);

-- dead entries across a skip: deleted and re-inserted rows
UPDATE lf_skip SET deleted_at = NULL WHERE id % 10000 = 22;
UPDATE lf_skip SET deleted_at = '2026-02-01' WHERE id % 10000 = 5000;
DELETE FROM lf_skip WHERE id % 10000 = 14;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC $$);

DROP TABLE lf_skip;
