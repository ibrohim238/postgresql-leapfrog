# EvalPlanQual under READ COMMITTED: session 1 changes a row that the
# intersection scan of session 2 is about to lock with FOR UPDATE.  The scan
# matched the old version by its index entries; the new version is fetched by
# EvalPlanQual and must be rechecked against the equality on owner_id and the
# predicate of the inner index, exactly as a standard index scan does.
#
# Every scenario is run twice: with the forced custom scan (s2_lock) and
# with leapfrog disabled (s2_lock_std), under the same interleaving, so the
# EvalPlanQual behaviour of the node is compared with the standard plan's
# directly.  Each run ends with the query after the commit, as a view of the
# final state.
#
# PostgreSQL rechecks the search condition on the new row version but not
# its ordering: a row whose merge column changed is returned at its old
# position by every plan, as the s1_move_id permutations show.

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
step s1_begin	{ BEGIN; }
# owner 2, live: ids 2, 10, 14, 22, 26, 34, ... (even, not divisible by 3)
step s1_move_owner	{ UPDATE lf_iso SET owner_id = 3 WHERE id = 14; }
step s1_soft_delete	{ UPDATE lf_iso SET deleted_at = now() WHERE id = 14; }
step s1_restore		{ UPDATE lf_iso SET deleted_at = NULL WHERE id = 6; }
step s1_hot		{ UPDATE lf_iso SET payload = 'changed' WHERE id = 14; }
step s1_delete		{ DELETE FROM lf_iso WHERE id = 14; }
step s1_move_id		{ UPDATE lf_iso SET id = 1014 WHERE id = 14; }
step s1_commit	{ COMMIT; }
step s1_rollback	{ ROLLBACK; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_plan	{
	EXPLAIN (COSTS OFF)
	SELECT id, owner_id, deleted_at, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 5 FOR UPDATE;
}
step s2_lock	{
	SELECT id, owner_id, deleted_at, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 5 FOR UPDATE;
}
step s2_lock_deleted	{
	SELECT id, owner_id, deleted_at IS NOT NULL AS deleted, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id LIMIT 3 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT id, owner_id, deleted_at, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 5 FOR UPDATE;
	RESET leapfrog.enabled;
}
step s2_std	{
	SET leapfrog.enabled = off;
	SELECT id, owner_id, deleted_at, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 5 FOR UPDATE;
	RESET leapfrog.enabled;
}
step s2_std_deleted	{
	SET leapfrog.enabled = off;
	SELECT id, owner_id, deleted_at IS NOT NULL AS deleted, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NOT NULL ORDER BY id LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
}

# The plan under test is the custom scan with LockRows above it.
permutation s2_plan

# The row moves to another owner: EPQ rechecks owner_id = 2 and drops it,
# the LIMIT is filled from the next row.
permutation s1_begin s1_move_owner s2_lock s1_commit s2_std
permutation s1_begin s1_move_owner s2_lock_std s1_commit s2_std

# The row is soft-deleted: the inner index predicate fails on the new version.
permutation s1_begin s1_soft_delete s2_lock s1_commit s2_std
permutation s1_begin s1_soft_delete s2_lock_std s1_commit s2_std

# A deleted row of owner 2 is restored while the scan runs: the new version
# was never matched by the scan (invisible under its snapshot), it is not
# returned until the next statement.
permutation s1_begin s1_restore s2_lock s1_commit s2_std
permutation s1_begin s1_restore s2_lock_std s1_commit s2_std

# HOT update of a column outside both indexes: the row is returned once,
# with the new payload.
permutation s1_begin s1_hot s2_lock s1_commit s2_std
permutation s1_begin s1_hot s2_lock_std s1_commit s2_std

# Delete: the row is gone.
permutation s1_begin s1_delete s2_lock s1_commit s2_std
permutation s1_begin s1_delete s2_lock_std s1_commit s2_std

# The merge column itself changes: the new version still satisfies the
# search condition and is returned at the old position, by both plans.
permutation s1_begin s1_move_id s2_lock s1_commit s2_std
permutation s1_begin s1_move_id s2_lock_std s1_commit s2_std

# Rollback of the concurrent change: the old version is locked and returned.
permutation s1_begin s1_move_owner s2_lock s1_rollback s2_std
permutation s1_begin s1_move_owner s2_lock_std s1_rollback s2_std
permutation s1_begin s1_soft_delete s2_lock s1_rollback s2_std
permutation s1_begin s1_soft_delete s2_lock_std s1_rollback s2_std

# The mirror pair over the deleted rows: a row restored under the lock
# fails the recheck of deleted_at IS NOT NULL.
permutation s1_begin s1_restore s2_lock_deleted s1_commit s2_std_deleted
