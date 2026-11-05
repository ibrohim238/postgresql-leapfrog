# EvalPlanQual with a nullable sort column: the sort position comes from the old version, as for an Index Scan.

setup
{
	CREATE TABLE lf_iso_null (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val bigint);
	INSERT INTO lf_iso_null SELECT g, g % 4, g % 3, CASE WHEN g % 10 = 0 THEN NULL ELSE g END FROM generate_series(1, 600) g;
	CREATE INDEX lf_iso_null_a ON lf_iso_null (a, val);
	CREATE INDEX lf_iso_null_b ON lf_iso_null (b, val);
	ANALYZE lf_iso_null;
}

teardown
{
	DROP TABLE lf_iso_null;
}

session s1
setup { LOAD 'leapfrog'; }
step s1_begin { BEGIN; }
# a = 2, b = 1: ids 10 (NULL), 22, 34, ...
step s1_null { UPDATE lf_iso_null SET val = NULL WHERE id = 22; }
step s1_b { UPDATE lf_iso_null SET b = 0 WHERE id = 10; }
step s1_commit { COMMIT; }

session s2
setup { LOAD 'leapfrog'; SET leapfrog.force = on; SET leapfrog.require_node = require; }
step s2_plan { EXPLAIN (COSTS OFF) SELECT id, val FROM lf_iso_null WHERE a = 2 AND b = 1 ORDER BY val NULLS LAST LIMIT 2 FOR UPDATE; }
step s2_lock { SELECT id, val FROM lf_iso_null WHERE a = 2 AND b = 1 ORDER BY val NULLS LAST LIMIT 2 FOR UPDATE; }
step s2_lock_std {
	SET leapfrog.enabled = off;
	SET leapfrog.require_node = forbid;
	SELECT id, val FROM lf_iso_null WHERE a = 2 AND b = 1 ORDER BY val NULLS LAST LIMIT 2 FOR UPDATE;
	RESET leapfrog.enabled;
	SET leapfrog.require_node = require;
}
step s2_tail { SELECT id, val FROM lf_iso_null WHERE a = 2 AND b = 1 ORDER BY val DESC NULLS FIRST, id LIMIT 3 FOR UPDATE; }
step s2_tail_std {
	SET leapfrog.enabled = off;
	SET leapfrog.require_node = forbid;
	SELECT id, val FROM lf_iso_null WHERE a = 2 AND b = 1 ORDER BY val DESC NULLS FIRST, id LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
	SET leapfrog.require_node = require;
}

permutation s2_plan
permutation s1_begin s1_null s2_lock s1_commit
permutation s1_begin s1_null s2_lock_std s1_commit
# a row of the NULL group stops matching
permutation s1_begin s1_b s2_tail s1_commit
permutation s1_begin s1_b s2_tail_std s1_commit
