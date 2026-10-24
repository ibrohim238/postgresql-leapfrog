# EvalPlanQual through the overflow fallback.  The TID group of the only
# grp value exceeds work_mem (64kB), so every outer row of the value is
# fetched and the inner equality (product_id) is checked on the row; under
# EvalPlanQual it is checked again on the new version.  Row order inside one
# grp value is not defined, so the results are compared as count and sum.

setup
{
	CREATE TABLE lf_iso_oe (
		id bigint PRIMARY KEY,
		customer_id bigint NOT NULL,
		product_id bigint NOT NULL,
		grp bigint NOT NULL
	);
	INSERT INTO lf_iso_oe
	SELECT g, 1, CASE WHEN g % 4 = 0 THEN 3 ELSE 2 END, 1
	FROM generate_series(1, 20000) g;
	CREATE INDEX lf_iso_oe_customer_grp ON lf_iso_oe (customer_id, grp);
	CREATE INDEX lf_iso_oe_product_grp ON lf_iso_oe (product_id, grp);
	ANALYZE lf_iso_oe;
}

teardown
{
	DROP TABLE lf_iso_oe;
}

session s1
setup		{ LOAD 'leapfrog'; }
step s1_begin		{ BEGIN; }
step s1_move_product	{ UPDATE lf_iso_oe SET product_id = 3 WHERE id IN (1, 2, 5); }
step s1_join_product	{ UPDATE lf_iso_oe SET product_id = 2 WHERE id IN (4, 8); }
step s1_commit		{ COMMIT; }

session s2
setup		{ LOAD 'leapfrog'; SET leapfrog.force = on; SET work_mem = '64kB'; }
step s2_explain	{
	EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, BUFFERS OFF)
	SELECT id FROM lf_iso_oe WHERE customer_id = 1 AND product_id = 2 ORDER BY grp FOR UPDATE;
}
step s2_lock	{
	SELECT count(*), sum(id) FROM (
		SELECT id FROM lf_iso_oe WHERE customer_id = 1 AND product_id = 2 ORDER BY grp FOR UPDATE) s;
}
step s2_lock_std	{
	SET leapfrog.enabled = off;
	SELECT count(*), sum(id) FROM (
		SELECT id FROM lf_iso_oe WHERE customer_id = 1 AND product_id = 2 ORDER BY grp FOR UPDATE) s;
	RESET leapfrog.enabled;
}

# the plan: the node, overflowing its group
permutation s2_explain

# Rows leave the inner side while the locking query waits for them: the
# fallback's recheck drops them, as the stock plan does.
permutation s1_begin s1_move_product s2_lock s1_commit
permutation s1_begin s1_move_product s2_lock_std s1_commit

# Rows that start to match after the snapshot are not returned by either.
permutation s1_begin s1_join_product s2_lock s1_commit
permutation s1_begin s1_join_product s2_lock_std s1_commit
