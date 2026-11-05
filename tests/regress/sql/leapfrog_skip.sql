-- leapfrog_skip: a lagging scan re-descends to the other side's value; equal entries are not skipped.
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_skip (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	grp bigint NOT NULL,
	deleted_at timestamptz
);
-- Owner 1: every other row, about 5,000 entries between deleted clusters, so it skips every gap.
-- Owner 2: a row every 5,000 ids, so the deleted side lags in its dense block. grp repeats 3 times.
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

-- skip_after = 0 turns skipping off, 1 re-descends after every entry; the answers stay the same
SET leapfrog.skip_after = 0;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Outer Entries Read', 'Inner Entries Read', 'Matched TIDs', 'Skips');
SET leapfrog.skip_after = 1;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp $$, false);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY grp DESC $$, false);
RESET leapfrog.skip_after;

-- Adaptive threshold: matches 50 entries apart in one leaf page; short skips raise it, so a few skips, not 2,000.
CREATE INDEX lf_skip_every100 ON lf_skip (id) WHERE id % 100 = 8;
SET leapfrog.skip_after = 8;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND id % 100 = 8 ORDER BY id $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND id % 100 = 8 ORDER BY id $$)
WHERE counter IN ('Inner Index', 'Matched TIDs', 'Skips', 'Short Skips');
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND id % 100 = 8 ORDER BY id DESC $$);
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND id % 100 = 8 ORDER BY id DESC $$)
WHERE counter IN ('Matched TIDs', 'Skips', 'Short Skips');
-- long gaps keep the threshold low: none of the skips is short
SELECT * FROM lf_counters($$
SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$)
WHERE counter IN ('Matched TIDs', 'Skips', 'Short Skips');
RESET leapfrog.skip_after;
DROP INDEX lf_skip_every100;

-- dead entries across a skip: deleted and re-inserted rows
UPDATE lf_skip SET deleted_at = NULL WHERE id % 10000 = 22;
UPDATE lf_skip SET deleted_at = '2026-02-01' WHERE id % 10000 = 5000;
DELETE FROM lf_skip WHERE id % 10000 = 14;
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_skip WHERE owner_id = 1 AND deleted_at IS NOT NULL ORDER BY id DESC $$);

DROP TABLE lf_skip;
