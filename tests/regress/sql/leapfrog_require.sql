-- leapfrog_require: leapfrog.require_node errors when a plan lacks the node (require) or has it (forbid)
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_req (
    id          bigint NOT NULL,
    customer_id bigint NOT NULL,
    deleted_at  timestamptz,
    payload     text
);
INSERT INTO lf_req
SELECT g, g % 10, CASE WHEN g % 3 = 0 THEN '2026-01-01'::timestamptz END, 'x'
FROM generate_series(1, 2000) g;
CREATE INDEX lf_req_customer_id ON lf_req (customer_id, id);
CREATE INDEX lf_req_live_id ON lf_req (id) WHERE deleted_at IS NULL;
VACUUM ANALYZE lf_req;

SHOW leapfrog.require_node;

SET leapfrog.force = on;

SET leapfrog.require_node = allow;
EXPLAIN (COSTS OFF)
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
EXPLAIN (COSTS OFF)
SELECT id FROM lf_req WHERE customer_id = 2 ORDER BY id LIMIT 3;

-- require: a query the node serves runs, under EXPLAIN as well.
SET leapfrog.require_node = require;
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
EXPLAIN (COSTS OFF)
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
-- the node inside a subquery and an InitPlan counts
SELECT count(*) FROM (SELECT id FROM lf_req
    WHERE customer_id = 2 AND deleted_at IS NULL ORDER BY id LIMIT 3) s;
SELECT (SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
    ORDER BY id LIMIT 1) AS first_id;

-- require: no usable set of indexes, even under force.
SELECT id FROM lf_req WHERE customer_id = 2 ORDER BY id LIMIT 3;
EXPLAIN (COSTS OFF)
SELECT id FROM lf_req WHERE customer_id = 2 ORDER BY id LIMIT 3;
SELECT 1 AS one;
SET leapfrog.enabled = off;
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
RESET leapfrog.enabled;

-- forbid: a query the node would take under force errors.
SET leapfrog.require_node = forbid;
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
EXPLAIN (COSTS OFF)
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
-- and runs with the node switched off, or without a usable set
SET leapfrog.enabled = off;
SELECT id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
RESET leapfrog.enabled;
SELECT id FROM lf_req WHERE customer_id = 2 ORDER BY id LIMIT 3;

-- A prepared statement is checked whenever it is planned.
SET plan_cache_mode = force_custom_plan;
SET leapfrog.require_node = require;
PREPARE lf_req_q(bigint) AS
SELECT id FROM lf_req WHERE customer_id = $1 AND deleted_at IS NULL
ORDER BY id LIMIT 3;
EXECUTE lf_req_q(2);
SET leapfrog.require_node = forbid;
EXECUTE lf_req_q(2);
DEALLOCATE lf_req_q;
RESET plan_cache_mode;

-- plpgsql queries are checked when planned; the outer SELECT has no node, so it passes "forbid".
CREATE FUNCTION lf_req_first(c bigint) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
	RETURN (SELECT id FROM lf_req WHERE customer_id = c AND deleted_at IS NULL
		ORDER BY id LIMIT 1);
END
$$;
SET leapfrog.require_node = forbid;
SELECT lf_req_first(2);
SET leapfrog.require_node = require;
DO $$
BEGIN
	PERFORM id FROM lf_req WHERE customer_id = 2 AND deleted_at IS NULL
	ORDER BY id LIMIT 3;
END
$$;
DO $$
BEGIN
	PERFORM id FROM lf_req WHERE customer_id = 2 ORDER BY id LIMIT 3;
END
$$;

RESET leapfrog.require_node;
RESET leapfrog.force;
SELECT lf_req_first(2);
DROP FUNCTION lf_req_first(bigint);
DROP TABLE lf_req;
