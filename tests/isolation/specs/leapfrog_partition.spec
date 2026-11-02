# EvalPlanQual through partitions: the node under a Merge Append rechecks the
# equalities enforced by its inner index on the new row version.  Every
# permutation runs with the node and with the stock plan under the same
# interleaving and must give the same rows; a row moved to another partition
# fails the same way in both.

setup
{
	CREATE TABLE lf_iso_part (id bigint NOT NULL, owner_id bigint NOT NULL, kind integer NOT NULL, flag integer NOT NULL, val integer NOT NULL)
		PARTITION BY LIST (owner_id);
	CREATE TABLE lf_iso_part_1 PARTITION OF lf_iso_part FOR VALUES IN (1);
	CREATE TABLE lf_iso_part_2 PARTITION OF lf_iso_part FOR VALUES IN (2);
	-- kind = 1 AND flag = 2: ids 7, 22, 37, ..., in turn in partitions 2 and 1
	INSERT INTO lf_iso_part SELECT g, 1 + g % 2, g % 3, g % 5, 0 FROM generate_series(1, 3000) g;
	CREATE INDEX lf_iso_part_flag ON lf_iso_part (flag, id);
	CREATE INDEX lf_iso_part_kind ON lf_iso_part (kind, id);
	ANALYZE lf_iso_part;
}

teardown
{
	DROP TABLE lf_iso_part;
}

session writer
setup { LOAD 'leapfrog'; }
step w_begin { BEGIN; }
step w_kind { UPDATE lf_iso_part SET kind = 2 WHERE id = 7; }
step w_flag { UPDATE lf_iso_part SET flag = 3 WHERE id = 7; }
step w_val { UPDATE lf_iso_part SET val = 1 WHERE id = 7; }
step w_move { UPDATE lf_iso_part SET owner_id = 1 WHERE id = 7; }
step w_commit { COMMIT; }

session reader
setup { LOAD 'leapfrog'; }
step r_node { SET leapfrog.enabled = on; SET leapfrog.force = on; }
step r_stock { SET leapfrog.enabled = off; SET leapfrog.force = off; }
step r_plan { EXPLAIN (COSTS OFF) SELECT id, val FROM lf_iso_part WHERE kind = 1 AND flag = 2 ORDER BY id LIMIT 2 FOR UPDATE; }
step r_lock { SELECT id, val FROM lf_iso_part WHERE kind = 1 AND flag = 2 ORDER BY id LIMIT 2 FOR UPDATE; }

permutation r_node r_plan

# The inner equality fails on the new version: the row is dropped.
permutation r_node w_begin w_kind r_lock w_commit
permutation r_stock w_begin w_kind r_lock w_commit

# The outer equality fails on the new version: the row is dropped.
permutation r_node w_begin w_flag r_lock w_commit
permutation r_stock w_begin w_flag r_lock w_commit

# An unrelated column changes: the row stays, with the new value.
permutation r_node w_begin w_val r_lock w_commit
permutation r_stock w_begin w_val r_lock w_commit

# The row moves to the other partition: an error in READ COMMITTED.
permutation r_node w_begin w_move r_lock w_commit
permutation r_stock w_begin w_move r_lock w_commit
