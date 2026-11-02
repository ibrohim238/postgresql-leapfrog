# EvalPlanQual with a text sort column: the node rechecks its equalities on
# the new version of the row, whatever the type it merges on.  Every
# permutation runs with the node and with the stock plan under the same
# interleaving.

setup
{
	CREATE TABLE lf_iso_st (id bigint PRIMARY KEY, a integer NOT NULL, b integer NOT NULL, val text NOT NULL, note text);
	INSERT INTO lf_iso_st SELECT g, g % 4, g % 3, lpad(g::text, 300, '0'), 'n' FROM generate_series(1, 600) g;
	CREATE INDEX lf_iso_st_a ON lf_iso_st (a, val);
	CREATE INDEX lf_iso_st_b ON lf_iso_st (b, val);
	ANALYZE lf_iso_st;
}

teardown
{
	DROP TABLE lf_iso_st;
}

session s1
setup { LOAD 'leapfrog'; }
step s1_begin { BEGIN; }
# a = 2, b = 1: ids 10, 22, 34, ...
step s1_b { UPDATE lf_iso_st SET b = 0 WHERE id = 22; }
step s1_note { UPDATE lf_iso_st SET note = 'changed' WHERE id = 22; }
step s1_commit { COMMIT; }

session s2
setup { LOAD 'leapfrog'; SET leapfrog.force = on; }
step s2_plan { EXPLAIN (COSTS OFF) SELECT id, note FROM lf_iso_st WHERE a = 2 AND b = 1 ORDER BY val LIMIT 3 FOR UPDATE; }
step s2_lock { SELECT id, note FROM lf_iso_st WHERE a = 2 AND b = 1 ORDER BY val LIMIT 3 FOR UPDATE; }
step s2_lock_std {
	SET leapfrog.enabled = off;
	SELECT id, note FROM lf_iso_st WHERE a = 2 AND b = 1 ORDER BY val LIMIT 3 FOR UPDATE;
	RESET leapfrog.enabled;
}

permutation s2_plan
permutation s1_begin s1_b s2_lock s1_commit
permutation s1_begin s1_b s2_lock_std s1_commit
permutation s1_begin s1_note s2_lock s1_commit
permutation s1_begin s1_note s2_lock_std s1_commit
