-- leapfrog_setup: the helpers every other test uses; runs first
-- LOAD installs the planner hook when the server does not preload the library.
LOAD 'leapfrog';

-- The extension itself is created by pg_regress --load-extension.
SELECT extname, extversion FROM pg_extension WHERE extname = 'leapfrog';
SELECT leapfrog_version(), leapfrog_is_loaded();

-- An installation of the previous release can be updated in place.
SELECT source, target, path FROM pg_extension_update_paths('leapfrog')
WHERE path IS NOT NULL ORDER BY source, target;

SHOW leapfrog.enabled;
SHOW leapfrog.force;
SHOW leapfrog.skip_after;

SET max_parallel_workers_per_gather = 0;

-- lf_plan(query): the plan under leapfrog.force
CREATE FUNCTION lf_plan(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
BEGIN
	PERFORM set_config('leapfrog.enabled', 'on', true);
	PERFORM set_config('leapfrog.force', 'on', true);
	FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
		RETURN NEXT line;
	END LOOP;
END
$$;

-- lf_plan_costs(query): the plan with costs, numbers masked
CREATE FUNCTION lf_plan_costs(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
	line text;
BEGIN
	PERFORM set_config('leapfrog.enabled', 'on', true);
	PERFORM set_config('leapfrog.force', 'off', true);
	FOR line IN EXECUTE 'EXPLAIN ' || query LOOP
		RETURN NEXT regexp_replace(line, '\d+(\.\d+)?', 'N', 'g');
	END LOOP;
END
$$;

-- lf_check(query, ordered): stock and forced results compared with EXCEPT ALL both ways (and by
-- position when ordered), whether the custom scan ran, and a canary that the runs' settings differ
CREATE FUNCTION lf_check(query text, ordered boolean DEFAULT true)
RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
	wrapped text;
	plan text := '';
	line text;
	expected_rows bigint;
	actual_rows bigint;
	missing bigint;
	extra bigint;
	stock_settings text;
	forced_settings text;
BEGIN
	IF ordered THEN
		wrapped := 'SELECT row_number() OVER () AS lf_position, q.* FROM (' ||
			query || ') q';
	ELSE
		wrapped := 'SELECT q.* FROM (' || query || ') q';
	END IF;

	PERFORM set_config('leapfrog.enabled', 'off', true);
	PERFORM set_config('leapfrog.force', 'off', true);
	EXECUTE 'CREATE TEMP TABLE lf_expected AS ' || wrapped;
	stock_settings := current_setting('leapfrog.enabled') || '/' ||
		current_setting('leapfrog.force');

	PERFORM set_config('leapfrog.enabled', 'on', true);
	PERFORM set_config('leapfrog.force', 'on', true);
	EXECUTE 'CREATE TEMP TABLE lf_actual AS ' || wrapped;
	forced_settings := current_setting('leapfrog.enabled') || '/' ||
		current_setting('leapfrog.force');
	IF stock_settings = forced_settings THEN
		RAISE EXCEPTION 'lf_check: the stock and forced runs both ran with leapfrog.enabled/force = %',
			stock_settings;
	END IF;
	FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
		plan := plan || line || E'\n';
	END LOOP;

	SELECT count(*) INTO expected_rows FROM lf_expected;
	SELECT count(*) INTO actual_rows FROM lf_actual;
	EXECUTE 'SELECT count(*) FROM (SELECT * FROM lf_expected EXCEPT ALL SELECT * FROM lf_actual) d'
		INTO missing;
	EXECUTE 'SELECT count(*) FROM (SELECT * FROM lf_actual EXCEPT ALL SELECT * FROM lf_expected) d'
		INTO extra;

	DROP TABLE lf_expected;
	DROP TABLE lf_actual;

	RETURN format('custom scan: %s, rows: %s/%s, missing: %s, extra: %s',
		plan LIKE '%Custom Scan (Index Merge Intersect)%',
		actual_rows, expected_rows, missing, extra);
END
$$;

-- lf_counters(query): the node's EXPLAIN ANALYZE counters under leapfrog.force
CREATE FUNCTION lf_counters(query text) RETURNS TABLE (counter text, value jsonb)
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
	node jsonb;
BEGIN
	PERFORM set_config('leapfrog.enabled', 'on', true);
	PERFORM set_config('leapfrog.force', 'on', true);
	EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF, FORMAT JSON) ' ||
		query INTO plan;

	FOR node IN
		SELECT n FROM jsonb_path_query(plan, 'strict $[0].Plan.**') AS n
		WHERE n->>'Custom Plan Provider' = 'Index Merge Intersect'
	LOOP
		-- the streams, named Outer, Inner, Inner 2, ... as the tests know them
		RETURN QUERY
			SELECT CASE WHEN s.i = 1 THEN 'Outer ' ELSE 'Inner ' END || k.name
					|| CASE WHEN s.i > 2 THEN ' ' || (s.i - 1) ELSE '' END,
				s.stream -> k.key
			FROM (VALUES (1, 'Index', 'Index Name'), (2, 'Entries Read', 'Entries Read'))
				AS k(ord, name, key),
				jsonb_array_elements(node -> 'Index Streams') WITH ORDINALITY AS s(stream, i)
			WHERE s.stream ? k.key
			ORDER BY k.ord, s.i;
		RETURN QUERY
			SELECT key, node->key FROM unnest(ARRAY[
				'Matched TIDs', 'Heap Fetches', 'Heap Prefetches', 'Skips', 'Short Skips',
				'Rows Checked by Predicate', 'Group Overflows',
				'Peak Group Memory', 'Actual Rows', 'Actual Loops',
				'Rows Removed by Filter']) AS key
			WHERE node ? key;
	END LOOP;
END
$$;
