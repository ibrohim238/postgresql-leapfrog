# The column of the partial index predicate flips while another session
# holds a snapshot.  The row moves between the two partial indexes: the old
# entry stays in one, a new one appears in the other.  Each session must see
# exactly its snapshot's version through either index pair.

setup
{
	CREATE TABLE lf_iso (
		id bigint PRIMARY KEY,
		owner_id bigint NOT NULL,
		deleted_at timestamptz,
		payload text
	);
	INSERT INTO lf_iso (id, owner_id, deleted_at, payload)
	SELECT g, g % 4, CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
	FROM generate_series(1, 400) g;
	CREATE INDEX lf_iso_owner_id ON lf_iso (owner_id, id);
	CREATE INDEX lf_iso_live_id ON lf_iso (id) WHERE deleted_at IS NULL;
	CREATE INDEX lf_iso_deleted_id ON lf_iso (id) WHERE deleted_at IS NOT NULL;
	ANALYZE lf_iso;
}

teardown
{
	DROP TABLE lf_iso;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
step s1_soft_delete	{ UPDATE lf_iso SET deleted_at = now() WHERE owner_id = 2 AND id < 100 AND deleted_at IS NULL; }
step s1_restore		{ UPDATE lf_iso SET deleted_at = NULL WHERE owner_id = 2 AND deleted_at IS NOT NULL; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_begin_rr	{ BEGIN ISOLATION LEVEL REPEATABLE READ; }
step s2_begin_rc	{ BEGIN ISOLATION LEVEL READ COMMITTED; }
step s2_live	{
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
}
step s2_deleted	{
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC) s;
}
step s2_both_std	{
	SET LOCAL leapfrog.enabled = off;
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC) s;
	RESET leapfrog.enabled;
}
step s2_commit	{ COMMIT; }

# REPEATABLE READ: the snapshot predates the flip; the counts do not change
# until the transaction ends, and agree with the standard plan.
permutation s2_begin_rr s2_live s2_deleted s1_begin s1_soft_delete s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted s2_both_std

# The reverse flip
permutation s2_begin_rr s2_live s2_deleted s1_begin s1_restore s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted s2_both_std

# READ COMMITTED: every statement takes a new snapshot and sees the
# committed flip; an uncommitted flip is invisible.
permutation s2_begin_rc s2_live s1_begin s1_soft_delete s2_live s2_deleted s1_commit s2_live s2_deleted s2_both_std s2_commit

# Both flips in one transaction, read in between by a REPEATABLE READ
# session: nothing changes for it.
permutation s2_begin_rr s2_live s1_begin s1_soft_delete s1_restore s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted
