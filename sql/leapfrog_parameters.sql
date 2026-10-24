--
-- leapfrog_parameters
--
-- Equality values that are not constants: query parameters of prepared
-- statements, nestloop parameters from LATERAL and from join clauses, and
-- repeated rescans of the node.
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_param (
	id bigint PRIMARY KEY,
	owner_id bigint NOT NULL,
	kind_id bigint NOT NULL,
	deleted_at timestamptz,
	payload text
);
INSERT INTO lf_param (id, owner_id, kind_id, deleted_at, payload)
SELECT g, g % 10, g % 3,
	CASE WHEN g % 4 = 0 THEN '2026-01-01'::timestamptz END, 'p' || g
FROM generate_series(1, 20000) g
ORDER BY (g * 7919) % 20000;
CREATE INDEX lf_param_owner_id ON lf_param (owner_id, id);
CREATE INDEX lf_param_owner_kind_id ON lf_param (owner_id, kind_id, id);
CREATE INDEX lf_param_live_id ON lf_param (id) WHERE deleted_at IS NULL;
ANALYZE lf_param;

CREATE TABLE lf_owners (owner_id bigint PRIMARY KEY, name text);
INSERT INTO lf_owners SELECT g, 'owner ' || g FROM generate_series(0, 12) g;
ANALYZE lf_owners;

SET leapfrog.force = on;

--
-- Prepared statement with a generic plan: the value is a Param.
--
SET plan_cache_mode = force_generic_plan;
PREPARE lf_by_owner (bigint) AS
	SELECT id, owner_id FROM lf_param WHERE owner_id = $1 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 5;
EXPLAIN (COSTS OFF) EXECUTE lf_by_owner(3);
EXECUTE lf_by_owner(3);
EXECUTE lf_by_owner(4);
-- NULL parameter: no row can match, no error
EXECUTE lf_by_owner(NULL);
-- a value with no rows
EXECUTE lf_by_owner(12345);
EXECUTE lf_by_owner(3);
DEALLOCATE lf_by_owner;

-- integer parameter against the bigint column
PREPARE lf_by_owner_int4 (integer) AS
	SELECT id, owner_id FROM lf_param WHERE owner_id = $1 AND deleted_at IS NULL
	ORDER BY id LIMIT 3;
EXPLAIN (COSTS OFF) EXECUTE lf_by_owner_int4(3);
EXECUTE lf_by_owner_int4(3);
DEALLOCATE lf_by_owner_int4;
RESET plan_cache_mode;

--
-- LATERAL: the value is a column of the outer relation, the path is
-- parameterized and the node is rescanned for every outer row.
--
EXPLAIN (COSTS OFF)
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (5), (12345), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 3) s;
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (5), (12345), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 3) s;

-- the same against the standard plan, with and without LIMIT
SELECT lf_check($$
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (5), (12345), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 3) s $$);
SELECT lf_check($$
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (5), (12345), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id) s $$);

-- NULL outer value among the rows: that iteration yields nothing.
SELECT lf_check($$
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (NULL), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id LIMIT 2) s $$);

-- Two nestloop parameters from two outer relations on the three-column index.
EXPLAIN (COSTS OFF)
SELECT o.owner_id, k.kind_id, s.id
FROM (VALUES (2::bigint), (3)) o (owner_id),
	(VALUES (0::bigint), (2)) k (kind_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = o.owner_id AND kind_id = k.kind_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 2) s;
SELECT lf_check($$
SELECT o.owner_id, k.kind_id, s.id
FROM (VALUES (2::bigint), (3)) o (owner_id),
	(VALUES (0::bigint), (2)) k (kind_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = o.owner_id AND kind_id = k.kind_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 2) s $$);

-- The counters are summed over all rescans: 4 outer rows, 3 with matches.
SELECT * FROM lf_counters($$
SELECT v.owner_id, s.id
FROM (VALUES (1::bigint), (5), (12345), (7)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id DESC LIMIT 3) s $$);

--
-- A join clause: the equality comes from the equivalence class of
-- lf_owners.owner_id = lf_param.owner_id, the node is the inner side of a
-- nested loop.
--
EXPLAIN (COSTS OFF)
SELECT o.name, s.id
FROM lf_owners o
	JOIN LATERAL (SELECT id FROM lf_param
				  WHERE owner_id = o.owner_id AND deleted_at IS NULL
				  ORDER BY id DESC LIMIT 2) s ON true
WHERE o.owner_id IN (2, 3);
SELECT lf_check($$
SELECT o.name, s.id
FROM lf_owners o
	JOIN LATERAL (SELECT id FROM lf_param
				  WHERE owner_id = o.owner_id AND deleted_at IS NULL
				  ORDER BY id DESC LIMIT 2) s ON true
WHERE o.owner_id IN (2, 3) $$);

-- Plain join without LATERAL.  With a constant on the other side the
-- equivalence class gives the scan a constant equality of its own.
EXPLAIN (COSTS OFF)
SELECT o.name, s.id
FROM lf_owners o JOIN lf_param s ON s.owner_id = o.owner_id
WHERE s.deleted_at IS NULL AND o.owner_id = 3
ORDER BY s.id DESC LIMIT 10;
SELECT lf_check($$
SELECT o.name, s.id
FROM lf_owners o JOIN lf_param s ON s.owner_id = o.owner_id
WHERE s.deleted_at IS NULL AND o.owner_id = 3
ORDER BY s.id DESC LIMIT 10 $$);

-- Without a constant the join clause lives in the equivalence class only;
-- the parameterized path is the inner side of a nested loop whose output
-- is in the outer's order, so a Sort follows.
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (COSTS OFF)
SELECT o.name, s.id
FROM lf_owners o JOIN lf_param s ON s.owner_id = o.owner_id
WHERE s.deleted_at IS NULL AND o.name IN ('owner 2', 'owner 3')
ORDER BY s.id;
SELECT lf_check($$
SELECT o.name, s.id
FROM lf_owners o JOIN lf_param s ON s.owner_id = o.owner_id
WHERE s.deleted_at IS NULL AND o.name IN ('owner 2', 'owner 3')
ORDER BY s.id $$);
RESET enable_hashjoin;
RESET enable_mergejoin;

-- Rescan with the same parameter twice in a row (duplicate outer values)
SELECT lf_check($$
SELECT v.owner_id, s.id
FROM (VALUES (5::bigint), (5), (5)) v (owner_id),
	LATERAL (SELECT id FROM lf_param
			 WHERE owner_id = v.owner_id AND deleted_at IS NULL
			 ORDER BY id LIMIT 4) s $$);

-- A subplan parameter (uncorrelated scalar subquery = InitPlan Param)
SELECT lf_check($$
SELECT id FROM lf_param
WHERE owner_id = (SELECT min(owner_id) + 2 FROM lf_owners) AND deleted_at IS NULL
ORDER BY id LIMIT 5 $$);
SELECT * FROM lf_plan($$
SELECT id FROM lf_param
WHERE owner_id = (SELECT min(owner_id) + 2 FROM lf_owners) AND deleted_at IS NULL
ORDER BY id LIMIT 5 $$);

-- A correlated subquery in the target list runs the node once per row.
SELECT lf_check($$
SELECT o.owner_id,
	(SELECT max(id) FROM (SELECT id FROM lf_param
						  WHERE owner_id = o.owner_id AND deleted_at IS NULL
						  ORDER BY id DESC LIMIT 10) t) AS top_id
FROM lf_owners o ORDER BY o.owner_id $$);

--
-- Plan invalidation: a cached plan that uses the pair is replanned when
-- one of its indexes is dropped.
--
SET plan_cache_mode = force_generic_plan;
PREPARE lf_cached (bigint) AS
	SELECT id FROM lf_param WHERE owner_id = $1 AND deleted_at IS NULL
	ORDER BY id DESC LIMIT 3;
EXPLAIN (COSTS OFF) EXECUTE lf_cached(3);
EXECUTE lf_cached(3);
DROP INDEX lf_param_live_id;
EXPLAIN (COSTS OFF) EXECUTE lf_cached(3);
EXECUTE lf_cached(3);
CREATE INDEX lf_param_live_id ON lf_param (id) WHERE deleted_at IS NULL;
EXPLAIN (COSTS OFF) EXECUTE lf_cached(3);
DEALLOCATE lf_cached;
RESET plan_cache_mode;

RESET leapfrog.force;
DROP TABLE lf_param;
DROP TABLE lf_owners;
