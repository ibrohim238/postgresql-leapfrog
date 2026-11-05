# EvalPlanQual with text and uuid equalities, rechecked with the column's own equality operator.

setup
{
	CREATE TABLE lf_iso_types (
		id bigint PRIMARY KEY,
		owner_id uuid NOT NULL,
		status text NOT NULL,
		payload text
	);
	INSERT INTO lf_iso_types
	SELECT g, ('00000000-0000-0000-0000-00000000000' || g % 10)::uuid,
		(ARRAY['draft', 'sent', 'error', 'registered', 'deleted'])[1 + g % 5], 'p' || g
	FROM generate_series(1, 5000) g;
	CREATE INDEX lf_iso_types_owner_id ON lf_iso_types (owner_id, id);
	CREATE INDEX lf_iso_types_status_id ON lf_iso_types (status, id);
	ANALYZE lf_iso_types;
}

teardown
{
	DROP TABLE lf_iso_types;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
# rows 4997 and 4987 are owner ...07, status 'error'
step s1_move_status	{ UPDATE lf_iso_types SET status = 'sent' WHERE id = 4997; }
step s1_move_owner	{ UPDATE lf_iso_types SET owner_id = '00000000-0000-0000-0000-000000000008' WHERE id = 4987; }
step s1_payload		{ UPDATE lf_iso_types SET payload = 'changed' WHERE id = 4997; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; SET leapfrog.require_node = require; }
step s2_plan	{
	EXPLAIN (COSTS OFF)
	SELECT id, payload FROM lf_iso_types WHERE owner_id = '00000000-0000-0000-0000-000000000007' AND status = 'error'
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
}
step s2_lock	{
	SELECT id, payload FROM lf_iso_types WHERE owner_id = '00000000-0000-0000-0000-000000000007' AND status = 'error'
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SET leapfrog.require_node = forbid;
	SELECT id, payload FROM lf_iso_types WHERE owner_id = '00000000-0000-0000-0000-000000000007' AND status = 'error'
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
	SET leapfrog.require_node = require;
}

permutation s2_plan

# the text column changes: the row leaves the result
permutation s1_begin s1_move_status s2_lock s1_commit
permutation s1_begin s1_move_status s2_lock_std s1_commit

# the uuid column changes: the row leaves the result
permutation s1_begin s1_move_owner s2_lock s1_commit
permutation s1_begin s1_move_owner s2_lock_std s1_commit

# an unrelated column changes: the row stays, with its new payload
permutation s1_begin s1_payload s2_lock s1_commit
permutation s1_begin s1_payload s2_lock_std s1_commit
