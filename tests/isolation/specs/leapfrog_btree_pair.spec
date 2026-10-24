# EvalPlanQual for the intersection of two ordinary indexes,
# (customer_id, id) and (product_id, id).  The equality on product_id is
# enforced by the inner scan only and is not in the node's Filter, so the
# recheck of a concurrently updated row must evaluate it again on the new
# version.  Every permutation runs with the node and with the stock plan
# under the same interleaving.

setup
{
	CREATE TABLE lf_iso_pair (
		id bigint PRIMARY KEY,
		customer_id bigint NOT NULL,
		product_id bigint NOT NULL,
		payload text
	);
	INSERT INTO lf_iso_pair
	SELECT g, g % 4, g % 3, 'p' || g FROM generate_series(1, 600) g;
	CREATE INDEX lf_iso_pair_customer_id ON lf_iso_pair (customer_id, id);
	CREATE INDEX lf_iso_pair_product_id ON lf_iso_pair (product_id, id);
	ANALYZE lf_iso_pair;
}

teardown
{
	DROP TABLE lf_iso_pair;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
# customer 2, product 1: ids 10, 22, 34, 46, 58, ...
step s1_move_product	{ UPDATE lf_iso_pair SET product_id = 0 WHERE id = 22; }
step s1_move_customer	{ UPDATE lf_iso_pair SET customer_id = 3 WHERE id = 22; }
step s1_join_product	{ UPDATE lf_iso_pair SET product_id = 1 WHERE id = 14; }
step s1_payload		{ UPDATE lf_iso_pair SET payload = 'changed' WHERE id = 22; }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_plan	{
	EXPLAIN (COSTS OFF)
	SELECT id, customer_id, product_id, payload FROM lf_iso_pair
	WHERE customer_id = 2 AND product_id = 1 ORDER BY id LIMIT 4 FOR UPDATE;
}
step s2_lock	{
	SELECT id, customer_id, product_id, payload FROM lf_iso_pair
	WHERE customer_id = 2 AND product_id = 1 ORDER BY id LIMIT 4 FOR UPDATE;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT id, customer_id, product_id, payload FROM lf_iso_pair
	WHERE customer_id = 2 AND product_id = 1 ORDER BY id LIMIT 4 FOR UPDATE;
	RESET leapfrog.enabled;
}

permutation s2_plan

# The inner equality fails on the new version: the row is dropped.
permutation s1_begin s1_move_product s2_lock s1_commit
permutation s1_begin s1_move_product s2_lock_std s1_commit

# The outer equality fails on the new version.
permutation s1_begin s1_move_customer s2_lock s1_commit
permutation s1_begin s1_move_customer s2_lock_std s1_commit

# A row that starts to match after the snapshot is not seen by either plan.
permutation s1_begin s1_join_product s2_lock s1_commit
permutation s1_begin s1_join_product s2_lock_std s1_commit

# A column outside both indexes changes: the row is returned with the new
# payload.
permutation s1_begin s1_payload s2_lock s1_commit
permutation s1_begin s1_payload s2_lock_std s1_commit
