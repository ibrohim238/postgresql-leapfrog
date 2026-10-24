# EvalPlanQual with three streams: a concurrent update changes the column of
# the second or the third stream while SELECT FOR UPDATE waits for the row.
# The recheck evaluates every stream's conditions on the new version.  Every
# permutation is followed by the stock plan under the same interleaving.

setup
{
	CREATE TABLE lf_iso_nway (
		id bigint PRIMARY KEY,
		customer_id bigint NOT NULL,
		product_id bigint NOT NULL,
		deleted_at timestamptz,
		payload text
	);
	INSERT INTO lf_iso_nway
	SELECT g, g % 10, g % 5, CASE WHEN g % 4 = 0 THEN now() END, 'p' || g
	FROM generate_series(1, 5000) g;
	CREATE INDEX lf_iso_nway_customer_id ON lf_iso_nway (customer_id, id);
	CREATE INDEX lf_iso_nway_product_id ON lf_iso_nway (product_id, id);
	CREATE INDEX lf_iso_nway_live_id ON lf_iso_nway (id) WHERE deleted_at IS NULL;
	ANALYZE lf_iso_nway;
}

teardown
{
	DROP TABLE lf_iso_nway;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
# rows 4997 and 4987 are customer 7, product 2, live
step s1_move_product	{ UPDATE lf_iso_nway SET product_id = 3 WHERE id = 4997; }
step s1_soft_delete	{ UPDATE lf_iso_nway SET deleted_at = now() WHERE id = 4987; }
step s1_payload		{ UPDATE lf_iso_nway SET payload = 'changed' WHERE id = 4997; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; SET leapfrog.min_indexes = 3; }
step s2_plan	{
	EXPLAIN (COSTS OFF)
	SELECT id, payload FROM lf_iso_nway WHERE customer_id = 7 AND product_id = 2 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
}
step s2_lock	{
	SELECT id, payload FROM lf_iso_nway WHERE customer_id = 7 AND product_id = 2 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT id, payload FROM lf_iso_nway WHERE customer_id = 7 AND product_id = 2 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
}

permutation s2_plan

# the second stream's column changes: the row leaves the result
permutation s1_begin s1_move_product s2_lock s1_commit
permutation s1_begin s1_move_product s2_lock_std s1_commit

# the third stream's condition changes: the row leaves the result
permutation s1_begin s1_soft_delete s2_lock s1_commit
permutation s1_begin s1_soft_delete s2_lock_std s1_commit

# an unrelated column changes: the row stays, with its new payload
permutation s1_begin s1_payload s2_lock s1_commit
permutation s1_begin s1_payload s2_lock_std s1_commit
