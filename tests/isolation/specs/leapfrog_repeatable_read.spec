# REPEATABLE READ and SERIALIZABLE: repeated queries inside one transaction
# return the same rows regardless of concurrent commits, and a FOR UPDATE on
# a row that another transaction changed after the snapshot fails with a
# serialization error, as it does for a standard index scan.

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
step s1_change		{
	UPDATE lf_iso SET owner_id = 3 WHERE id = 14;
	UPDATE lf_iso SET deleted_at = now() WHERE id = 22;
	UPDATE lf_iso SET payload = 'changed' WHERE id = 26;
	DELETE FROM lf_iso WHERE id = 34;
	INSERT INTO lf_iso VALUES (1002, 2, NULL, 'new');
}
step s1_hot		{ UPDATE lf_iso SET payload = 'changed' WHERE id = 2; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_begin_rr	{ BEGIN ISOLATION LEVEL REPEATABLE READ; }
step s2_begin_ser	{ BEGIN ISOLATION LEVEL SERIALIZABLE; }
step s2_rows	{
	SELECT id, owner_id, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 8;
}
step s2_rows_desc	{
	SELECT id, owner_id, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL AND id < 40 ORDER BY id DESC;
}
step s2_count	{
	SELECT count(*), sum(id) FROM (
		SELECT id FROM lf_iso WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id) s;
}
step s2_lock	{
	SELECT id, owner_id, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 1 FOR UPDATE;
}
step s2_std	{
	SET LOCAL leapfrog.enabled = off;
	SELECT id, owner_id, payload FROM lf_iso
	WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 8;
	RESET leapfrog.enabled;
}
step s2_commit	{ COMMIT; }

# Repeated reads inside REPEATABLE READ are stable across a committed
# change of every kind; the next transaction sees the change.
permutation s2_begin_rr s2_rows s2_count s1_begin s1_change s1_commit s2_rows s2_rows_desc s2_count s2_std s2_commit s2_rows s2_rows_desc s2_count s2_std

# The same under SERIALIZABLE (read-only, no conflict).
permutation s2_begin_ser s2_rows s2_count s1_begin s1_change s1_commit s2_rows s2_count s2_std s2_commit s2_rows

# FOR UPDATE in REPEATABLE READ on a row changed after the snapshot: the
# lock waits for the other transaction and then fails to serialize.
permutation s2_begin_rr s2_rows s1_begin s1_hot s2_lock s1_commit s2_commit s2_rows

# The same when the change is committed before the lock is attempted but
# after the snapshot was taken.
permutation s2_begin_rr s2_rows s1_begin s1_hot s1_commit s2_lock s2_commit s2_rows
