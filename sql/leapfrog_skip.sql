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
-- Owner 1 has rows spread evenly over the ids; deleted rows come in
-- clusters far apart (every 1000th block of 50 ids), so both sides lag in
-- turn: the owner side across the gaps between clusters, the deleted side
-- inside the clusters.  grp repeats every value 3 times.
INSERT INTO lf_skip
SELECT g, CASE WHEN g % 7 = 0 THEN 1 ELSE 2 END, g / 3,
	CASE WHEN g % 1000 < 50 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 100000) g;
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
UPDATE lf_skip SET deleted_at = NULL WHERE id % 1000 = 21;
UPDATE lf_skip SET deleted_at = '2026-02-01' WHERE id % 1000 = 500;
DELETE FROM lf_skip WHERE id % 1000 = 14;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC $$);

DROP TABLE lf_skip;
