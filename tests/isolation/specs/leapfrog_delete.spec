# Concurrent DELETE and the equality column moving to another owner.  Dead
# index entries remain in both indexes until VACUUM; a reader with an older
# snapshot still sees the rows, a newer one does not, and nothing is
# returned twice or lost after VACUUM.

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
	ANALYZE lf_iso;
}

teardown
{
	DROP TABLE lf_iso;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
step s1_delete		{ DELETE FROM lf_iso WHERE owner_id = 2 AND id % 10 = 2; }
step s1_move_owner	{ UPDATE lf_iso SET owner_id = 3 WHERE owner_id = 2 AND id % 10 = 6; }
step s1_adopt		{ UPDATE lf_iso SET owner_id = 2 WHERE owner_id = 1 AND id % 10 = 1; }
step s1_commit		{ COMMIT; }
step s1_vacuum		{ VACUUM lf_iso; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_begin_rr	{ BEGIN ISOLATION LEVEL REPEATABLE READ; }
step s2_count	{
	SELECT count(*), count(DISTINCT id), sum(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
}
step s2_count_desc	{
	SELECT count(*), count(DISTINCT id), sum(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC) s;
}
step s2_first	{
	SELECT id, owner_id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 4;
}
step s2_std	{
	SET LOCAL leapfrog.enabled = off;
	SELECT count(*), count(DISTINCT id), sum(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
	SELECT id, owner_id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 4;
	RESET leapfrog.enabled;
}
step s2_commit	{ COMMIT; }

# Rows deleted under an older snapshot stay visible to it; a new snapshot
# does not see them, before and after VACUUM.
permutation s2_begin_rr s2_count s2_first s1_begin s1_delete s1_commit s2_count s2_count_desc s2_first s2_std s2_commit s2_count s2_first s2_std s1_vacuum s2_count s2_count_desc s2_first s2_std

# Rows leaving and joining the owner: the old entries are dead in the
# outer index for the new snapshot, the new entries invisible to the old.
permutation s2_begin_rr s2_count s1_begin s1_move_owner s1_adopt s1_commit s2_count s2_first s2_std s2_commit s2_count s2_count_desc s2_first s2_std s1_vacuum s2_count s2_first s2_std

# All three changes at once
permutation s2_begin_rr s2_count s1_begin s1_delete s1_move_owner s1_adopt s1_commit s2_count s2_std s2_commit s2_count s2_std s1_vacuum s2_count s2_std
