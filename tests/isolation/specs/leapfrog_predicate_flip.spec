# The partial index predicate column flips under a snapshot: each session sees its own version.

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
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; SET leapfrog.require_node = require; }
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
	SET LOCAL leapfrog.require_node = forbid;
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
	SELECT count(*), min(id), max(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id DESC) s;
	RESET leapfrog.enabled;
	SET leapfrog.require_node = require;
}
step s2_commit	{ COMMIT; }

# REPEATABLE READ: the counts do not change until the transaction ends.
permutation s2_begin_rr s2_live s2_deleted s1_begin s1_soft_delete s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted s2_both_std

# The reverse flip
permutation s2_begin_rr s2_live s2_deleted s1_begin s1_restore s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted s2_both_std

# READ COMMITTED: a new snapshot per statement sees the committed flip only.
permutation s2_begin_rc s2_live s1_begin s1_soft_delete s2_live s2_deleted s1_commit s2_live s2_deleted s2_both_std s2_commit

# Both flips in one transaction: nothing changes for a REPEATABLE READ reader.
permutation s2_begin_rr s2_live s1_begin s1_soft_delete s1_restore s1_commit s2_live s2_deleted s2_both_std s2_commit s2_live s2_deleted
