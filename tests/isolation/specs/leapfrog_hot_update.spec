# HOT updates: a column outside both indexes is updated repeatedly while
# another session reads.  The index entries point at the root of the HOT
# chain; the scan follows the chain to the version visible to its snapshot
# and returns each row exactly once.

setup
{
	CREATE TABLE lf_iso (
		id bigint PRIMARY KEY,
		owner_id bigint NOT NULL,
		deleted_at timestamptz,
		payload text
	) WITH (fillfactor = 50);
	INSERT INTO lf_iso (id, owner_id, deleted_at, payload)
	SELECT g, g % 4, CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, 'v0'
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
step s1_begin	{ BEGIN; }
step s1_v1	{ UPDATE lf_iso SET payload = 'v1' WHERE owner_id = 2; }
step s1_v2	{ UPDATE lf_iso SET payload = 'v2' WHERE owner_id = 2 AND id % 2 = 0; }
step s1_v3	{ UPDATE lf_iso SET payload = 'v3' WHERE owner_id = 2 AND id % 4 = 0; }
step s1_commit	{ COMMIT; }
step s1_hot_stats	{
	SELECT n_tup_upd > 0 AS updated, n_tup_hot_upd > 0 AS hot
	FROM pg_stat_xact_user_tables WHERE relname = 'lf_iso';
}

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_begin_rr	{ BEGIN ISOLATION LEVEL REPEATABLE READ; }
step s2_versions	{
	SELECT payload, count(*) FROM (
		SELECT payload FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s
	GROUP BY payload ORDER BY payload;
}
step s2_versions_desc	{
	SELECT payload, count(*) FROM (
		SELECT payload FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20) s
	GROUP BY payload ORDER BY payload;
}
step s2_unique	{
	SELECT count(*) AS rows, count(DISTINCT id) AS distinct_ids FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
}
step s2_std	{
	SET LOCAL leapfrog.enabled = off;
	SELECT payload, count(*) FROM (
		SELECT payload FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s
	GROUP BY payload ORDER BY payload;
	RESET leapfrog.enabled;
}
step s2_commit	{ COMMIT; }

# A REPEATABLE READ reader keeps seeing v0 through three committed HOT
# updates, with no duplicate rows; after its commit it sees the mix.
permutation s2_begin_rr s2_versions s1_begin s1_v1 s1_v2 s1_v3 s1_commit s2_versions s2_versions_desc s2_unique s2_std s2_commit s2_versions s2_versions_desc s2_unique s2_std

# The updates are HOT (the updated column is in no index).
permutation s1_begin s1_v1 s1_hot_stats s1_commit

# Uncommitted updates are invisible to a READ COMMITTED reader and visible
# right after the commit.
permutation s1_begin s1_v1 s2_versions s1_v2 s2_versions s1_commit s2_versions s2_unique s2_std
