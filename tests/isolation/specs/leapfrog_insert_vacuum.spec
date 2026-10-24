# Concurrent INSERT under READ COMMITTED, and VACUUM removing dead entries
# while a cursor over the node is in the middle of its scan.  Every result
# is followed by the stock plan's answer on the same snapshot.

setup
{
	CREATE TABLE lf_iso_iv (
		id bigint PRIMARY KEY,
		owner_id bigint NOT NULL,
		deleted_at timestamptz,
		payload text
	) WITH (autovacuum_enabled = false);
	INSERT INTO lf_iso_iv SELECT g, g % 4, CASE WHEN g % 3 = 0 THEN now() END, 'p' || g
	FROM generate_series(1, 2000) g;
	CREATE INDEX lf_iso_iv_owner_id ON lf_iso_iv (owner_id, id);
	CREATE INDEX lf_iso_iv_live_id ON lf_iso_iv (id) WHERE deleted_at IS NULL;
	ANALYZE lf_iso_iv;
}

teardown
{
	DROP TABLE lf_iso_iv;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
step s1_insert		{ INSERT INTO lf_iso_iv SELECT g, 2, NULL, 'new' FROM generate_series(5001, 5100) g; }
# lock the newest matching row and insert a newer matching one
step s1_lock_and_insert	{
	UPDATE lf_iso_iv SET payload = 'locked' WHERE id = 1994;
	INSERT INTO lf_iso_iv VALUES (900001, 2, NULL, 'newer');
}
step s1_commit		{ COMMIT; }
# delete the second half of owner 2's live rows, committed before s2 starts
step s1_delete_tail	{ DELETE FROM lf_iso_iv WHERE owner_id = 2 AND id > 1000; }
step s1_vacuum		{ VACUUM lf_iso_iv; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_begin	{ BEGIN ISOLATION LEVEL READ COMMITTED; }
step s2_count	{
	SELECT count(*), max(id), sum(id) FROM (
		SELECT id FROM lf_iso_iv WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC) s;
}
step s2_count_std	{
	SET LOCAL leapfrog.enabled = off;
	SELECT count(*), max(id), sum(id) FROM (
		SELECT id FROM lf_iso_iv WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC) s;
	RESET leapfrog.enabled;
}
step s2_lock	{
	SELECT id, payload FROM lf_iso_iv WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT id, payload FROM lf_iso_iv WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id DESC LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
}
step s2_declare	{
	DECLARE c CURSOR FOR
		SELECT id FROM lf_iso_iv WHERE owner_id = 2 AND deleted_at IS NULL ORDER BY id;
}
step s2_fetch	{ FETCH 3 FROM c; }
step s2_drain	{
	MOVE ALL FROM c;
}
step s2_commit	{ COMMIT; }

# READ COMMITTED: an uncommitted insert is invisible, a committed one is
# seen by the next statement, by both plans.
permutation s2_begin s2_count s1_begin s1_insert s2_count s2_count_std s1_commit s2_count s2_count_std s2_commit

# A row inserted by the transaction SELECT FOR UPDATE waits for is not seen
# by that statement after the wait (its snapshot predates the insert); the
# locked row is returned with its new payload.  The next statement sees the
# new row.
permutation s1_begin s1_lock_and_insert s2_begin s2_lock s1_commit s2_lock s2_commit
permutation s1_begin s1_lock_and_insert s2_begin s2_lock_std s1_commit s2_lock_std s2_commit

# VACUUM removing the dead entries of rows deleted before the cursor's
# snapshot, with the cursor still open after its scan has run out, and the
# answers of both plans afterwards.  (VACUUM while the node's scan is
# positioned on a leaf page waits for the scan to move on, as it does for an
# Index Only Scan: the scan keeps its leaf page pinned because it reads the
# sort value from the index tuple.  isolationtester cannot see buffer pin
# waits, so that case is not in this spec.)
permutation s1_delete_tail s2_begin s2_declare s2_fetch s2_drain s1_vacuum s2_count s2_count_std s2_commit
