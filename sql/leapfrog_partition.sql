--
-- Partitioned tables and inheritance: each child gets the node on its own
-- indexes, under the parent's MergeAppend or ordered Append.
--
CREATE TABLE lf_part (id bigint NOT NULL, owner_id bigint NOT NULL, kind integer NOT NULL, deleted_at timestamptz)
	PARTITION BY HASH (owner_id);
CREATE TABLE lf_part_0 PARTITION OF lf_part FOR VALUES WITH (MODULUS 3, REMAINDER 0);
CREATE TABLE lf_part_1 PARTITION OF lf_part FOR VALUES WITH (MODULUS 3, REMAINDER 1);
-- a partition with other attribute numbers: a dropped column shifts them
CREATE TABLE lf_part_2 (junk text, id bigint NOT NULL, owner_id bigint NOT NULL, kind integer NOT NULL, deleted_at timestamptz);
ALTER TABLE lf_part_2 DROP COLUMN junk;
ALTER TABLE lf_part ATTACH PARTITION lf_part_2 FOR VALUES WITH (MODULUS 3, REMAINDER 2);
INSERT INTO lf_part
SELECT g, g % 50, (g / 7) % 10, CASE WHEN g % 11 = 0 THEN now() END
FROM generate_series(1, 60000) g;
CREATE INDEX lf_part_owner ON lf_part (owner_id, id);
CREATE INDEX lf_part_kind ON lf_part (kind, id);
CREATE INDEX lf_part_live ON lf_part (id) WHERE deleted_at IS NULL;
ANALYZE lf_part;

-- several partitions: a MergeAppend over the node
SELECT * FROM lf_plan($$
SELECT * FROM lf_part WHERE kind = 3 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT id, owner_id, kind FROM lf_part WHERE kind = 3 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT id, owner_id, kind FROM lf_part WHERE kind = 3 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT id, owner_id, kind FROM lf_part WHERE kind = 3 AND deleted_at IS NULL ORDER BY id $$);

-- pruned down to one partition: its node, no MergeAppend
SELECT * FROM lf_plan($$
SELECT * FROM lf_part WHERE owner_id = 5 AND kind = 3 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT id, owner_id, kind FROM lf_part WHERE owner_id = 5 AND kind = 3 ORDER BY id LIMIT 20 $$);

-- run-time pruning with a generic plan
SET plan_cache_mode = force_generic_plan;
SET leapfrog.force = on;
PREPARE lf_part_q(bigint, integer) AS
	SELECT id, owner_id, kind FROM lf_part WHERE owner_id = $1 AND kind = $2 ORDER BY id LIMIT 20;
EXPLAIN (COSTS OFF) EXECUTE lf_part_q(5, 3);
EXECUTE lf_part_q(5, 3);
DEALLOCATE lf_part_q;
RESET leapfrog.force;
RESET plan_cache_mode;

-- a join: the values come from the other side, per partition
CREATE TABLE lf_part_pick (owner_id bigint NOT NULL, kind integer NOT NULL);
INSERT INTO lf_part_pick VALUES (5, 3), (7, 1), (9, 8);
SELECT lf_check($$ SELECT p.owner_id, q.id FROM lf_part_pick p
	CROSS JOIN LATERAL (SELECT id FROM lf_part t WHERE t.owner_id = p.owner_id AND t.kind = p.kind ORDER BY id LIMIT 3) q
	ORDER BY 1, 2 $$);
DROP TABLE lf_part_pick;

-- FOR UPDATE keeps conditions for EvalPlanQual per partition
SELECT lf_check($$ SELECT id, owner_id FROM lf_part WHERE kind = 3 AND deleted_at IS NULL ORDER BY id LIMIT 20 FOR UPDATE $$);

-- row-level security reaches the partitions: numeric = is not leakproof
BEGIN;
CREATE ROLE lf_part_reader;
CREATE TABLE lf_part_rls (id bigint NOT NULL, tenant_id integer NOT NULL, kind integer NOT NULL, price numeric NOT NULL)
	PARTITION BY HASH (id);
CREATE TABLE lf_part_rls_0 PARTITION OF lf_part_rls FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE lf_part_rls_1 PARTITION OF lf_part_rls FOR VALUES WITH (MODULUS 2, REMAINDER 1);
INSERT INTO lf_part_rls SELECT g, g % 2, g % 10, g % 7 FROM generate_series(1, 20000) g;
CREATE INDEX ON lf_part_rls (tenant_id, id);
CREATE INDEX ON lf_part_rls (kind, id);
CREATE INDEX ON lf_part_rls (price, id);
ANALYZE lf_part_rls;
ALTER TABLE lf_part_rls ENABLE ROW LEVEL SECURITY;
CREATE POLICY lf_part_rls_one ON lf_part_rls USING (tenant_id = 1);
GRANT SELECT ON lf_part_rls TO lf_part_reader;
SET LOCAL ROLE lf_part_reader;
SELECT * FROM lf_plan($$
SELECT * FROM lf_part_rls WHERE kind = 3 AND price = 3 ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT * FROM lf_part_rls WHERE kind = 3 AND price = 3 ORDER BY id LIMIT 5 $$);
ROLLBACK;

-- TABLESAMPLE of a partitioned table reaches the partitions: not the node
SELECT lf_check($$ SELECT id FROM lf_part TABLESAMPLE SYSTEM (50) REPEATABLE (1)
	WHERE kind = 3 AND deleted_at IS NULL ORDER BY id LIMIT 20 $$);

DROP TABLE lf_part;

-- Range partitions on the sort column: an ordered Append, read lazily.
CREATE TABLE lf_range (id bigint NOT NULL, owner_id bigint NOT NULL, kind integer NOT NULL)
	PARTITION BY RANGE (id);
CREATE TABLE lf_range_1 PARTITION OF lf_range FOR VALUES FROM (0) TO (20000);
CREATE TABLE lf_range_2 PARTITION OF lf_range FOR VALUES FROM (20000) TO (40000);
-- a partition without the second index gets a stock plan instead of the node
CREATE TABLE lf_range_3 (LIKE lf_range);
INSERT INTO lf_range SELECT g, g % 50, (g / 7) % 10 FROM generate_series(1, 39999) g;
INSERT INTO lf_range_3 SELECT g, g % 50, (g / 7) % 10 FROM generate_series(40000, 45000) g;
CREATE INDEX lf_range_owner ON ONLY lf_range (owner_id, id);
CREATE INDEX ON lf_range_1 (owner_id, id);
CREATE INDEX ON lf_range_2 (owner_id, id);
CREATE INDEX ON lf_range_1 (kind, id);
CREATE INDEX ON lf_range_2 (kind, id);
ALTER TABLE lf_range ATTACH PARTITION lf_range_3 FOR VALUES FROM (40000) TO (60000);
ANALYZE lf_range;
SELECT * FROM lf_plan($$
SELECT * FROM lf_range WHERE owner_id = 5 AND kind = 3 ORDER BY id LIMIT 3 $$);
SELECT lf_check($$ SELECT * FROM lf_range WHERE owner_id = 5 AND kind = 3 ORDER BY id LIMIT 3 $$);
SELECT lf_check($$ SELECT * FROM lf_range WHERE owner_id = 5 AND kind = 3 ORDER BY id $$);
SELECT lf_check($$ SELECT * FROM lf_range WHERE owner_id = 5 AND kind = 3 ORDER BY id DESC $$);
DROP TABLE lf_range;

-- Traditional inheritance: the parent's own rows and the child's, each once.
CREATE TABLE lf_inh (id bigint NOT NULL, owner_id bigint NOT NULL, kind integer NOT NULL);
CREATE TABLE lf_inh_child (extra text) INHERITS (lf_inh);
INSERT INTO lf_inh SELECT g, g % 50, (g / 7) % 10 FROM generate_series(1, 20000) g;
INSERT INTO lf_inh_child SELECT g, g % 50, (g / 7) % 10 FROM generate_series(20001, 40000) g;
CREATE INDEX ON lf_inh (owner_id, id);
CREATE INDEX ON lf_inh (kind, id);
CREATE INDEX ON lf_inh_child (owner_id, id);
CREATE INDEX ON lf_inh_child (kind, id);
ANALYZE lf_inh;
ANALYZE lf_inh_child;
SELECT * FROM lf_plan($$
SELECT id FROM lf_inh WHERE owner_id = 5 AND kind = 3 ORDER BY id LIMIT 20 $$);
SELECT lf_check($$ SELECT id FROM lf_inh WHERE owner_id = 5 AND kind = 3 ORDER BY id $$);
SELECT lf_check($$ SELECT id FROM ONLY lf_inh WHERE owner_id = 5 AND kind = 3 ORDER BY id $$);
DROP TABLE lf_inh CASCADE;
