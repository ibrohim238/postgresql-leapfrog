# EvalPlanQual with a partial index on the outer side.  The node does not
# keep the outer predicate itself; the condition it implies
# (deleted_at IS NULL) must stay in the node's Filter, which ExecScan
# applies to the new row version under EvalPlanQual.  A row soft-deleted
# while SELECT ... FOR UPDATE waits for it must be dropped, as by the stock
# plan under the same interleaving.

setup
{
	CREATE TABLE lf_iso_op (
		id bigint PRIMARY KEY,
		customer_id bigint NOT NULL,
		product_id bigint NOT NULL,
		kind integer NOT NULL,
		deleted_at timestamptz
	);
	INSERT INTO lf_iso_op SELECT g, g % 4, g % 3, g % 2, NULL FROM generate_series(1, 600) g;
	CREATE INDEX lf_iso_op_live_customer_id ON lf_iso_op (customer_id, id) WHERE deleted_at IS NULL;
	CREATE INDEX lf_iso_op_product_id_kind ON lf_iso_op (product_id, id, kind);
	ANALYZE lf_iso_op;
}

teardown
{
	DROP TABLE lf_iso_op;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
# customer 2, product 1: ids 10, 22, 34, 46, ...
step s1_soft_delete	{ UPDATE lf_iso_op SET deleted_at = now() WHERE id = 22; }
step s1_kind		{ UPDATE lf_iso_op SET kind = 7 WHERE id = 22; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_plan	{
	EXPLAIN (COSTS OFF)
	SELECT id, customer_id, product_id, kind, deleted_at IS NULL AS live FROM lf_iso_op
	WHERE customer_id = 2 AND product_id = 1 AND deleted_at IS NULL ORDER BY id LIMIT 4 FOR UPDATE;
}
step s2_lock	{
	SELECT id, customer_id, product_id, kind, deleted_at IS NULL AS live FROM lf_iso_op
	WHERE customer_id = 2 AND product_id = 1 AND deleted_at IS NULL ORDER BY id LIMIT 4 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT id, customer_id, product_id, kind, deleted_at IS NULL AS live FROM lf_iso_op
	WHERE customer_id = 2 AND product_id = 1 AND deleted_at IS NULL ORDER BY id LIMIT 4 FOR UPDATE;
	RESET leapfrog.enabled;
}

permutation s2_plan

# The outer predicate fails on the new version: the row is dropped.
permutation s1_begin s1_soft_delete s2_lock s1_commit
permutation s1_begin s1_soft_delete s2_lock_std s1_commit

# A column of the inner index after the sort column changes (non-HOT): the
# row still matches and is returned with the new value.
permutation s1_begin s1_kind s2_lock s1_commit
permutation s1_begin s1_kind s2_lock_std s1_commit
