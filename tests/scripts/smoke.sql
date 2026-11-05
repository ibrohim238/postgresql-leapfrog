-- Smoke check of a fresh test server (start-cluster.sh), in a database of its own
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
DROP DATABASE IF EXISTS leapfrog_smoke;
CREATE DATABASE leapfrog_smoke;
\c leapfrog_smoke
CREATE EXTENSION leapfrog;
SELECT leapfrog_version(), leapfrog_is_loaded();
CREATE TABLE orders (id bigint PRIMARY KEY, customer_id bigint NOT NULL, deleted_at timestamptz);
INSERT INTO orders SELECT g, g % 100, CASE WHEN g % 7 = 0 THEN now() END FROM generate_series(1, 50000) g;
CREATE INDEX idx_orders_customer_id ON orders (customer_id, id);
CREATE INDEX idx_orders_active_id ON orders (id) WHERE deleted_at IS NULL;
ANALYZE orders;

CREATE FUNCTION smoke_plan(setting text, value text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
	plan text := '';
BEGIN
	PERFORM set_config(setting, value, true);
	FOR line IN EXPLAIN (COSTS OFF)
		SELECT * FROM orders WHERE customer_id = 42 AND deleted_at IS NULL
		ORDER BY id DESC LIMIT 100
	LOOP
		plan := plan || line || E'\n';
	END LOOP;
	RETURN plan;
END
$$;

SELECT smoke_plan('leapfrog.force', 'on');
SELECT count(*) FROM (SELECT * FROM orders WHERE customer_id = 42 AND deleted_at IS NULL ORDER BY id DESC LIMIT 100) s;
SELECT smoke_plan('leapfrog.enabled', 'off');

-- One transaction each: smoke_plan's setting lasts until its end.
DO $$
BEGIN
	IF smoke_plan('leapfrog.force', 'on') NOT LIKE '%Custom Scan (Index Merge Intersect)%' THEN
		RAISE EXCEPTION 'smoke: no Index Merge Intersect node under leapfrog.force';
	END IF;
END
$$;
DO $$
BEGIN
	IF smoke_plan('leapfrog.enabled', 'off') LIKE '%Custom Scan%' THEN
		RAISE EXCEPTION 'smoke: a Custom Scan with leapfrog.enabled off';
	END IF;
END
$$;

\c postgres
DROP DATABASE leapfrog_smoke;
