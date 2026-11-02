--
-- The cost model charges the clauses the node evaluates, the same list its
-- Filter is made from.
--
CREATE TABLE lf_cost (
	id bigint NOT NULL,
	owner_id bigint NOT NULL,
	coded_id bigint NOT NULL,
	kind integer NOT NULL,
	flag integer NOT NULL
);
INSERT INTO lf_cost
SELECT g, g % 10, g % 7, (g / 10) % 10, (g / 100) % 2 FROM generate_series(1, 10000) g;

-- A qual whose cost can be changed, and is not inlined.
CREATE FUNCTION lf_cost_flag(integer) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN $1 = 0; END $$;

-- An equality whose cost can be changed, of an operator class of its own.
CREATE FUNCTION lf_cost_eq(bigint, bigint) RETURNS boolean
LANGUAGE internal IMMUTABLE STRICT AS 'int8eq';
CREATE OPERATOR === (LEFTARG = bigint, RIGHTARG = bigint,
	FUNCTION = lf_cost_eq, RESTRICT = eqsel, JOIN = eqjoinsel);
CREATE OPERATOR CLASS lf_cost_ops FOR TYPE bigint USING btree AS
	OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 ===, OPERATOR 4 >=, OPERATOR 5 >,
	FUNCTION 1 btint8cmp(bigint, bigint);

CREATE INDEX lf_cost_owner ON lf_cost (owner_id, id);
CREATE INDEX lf_cost_coded ON lf_cost (coded_id lf_cost_ops, id);
CREATE INDEX lf_cost_flagged ON lf_cost (id) WHERE lf_cost_flag(flag);
CREATE INDEX lf_cost_kind ON lf_cost (kind, id);
ANALYZE lf_cost;

-- The node's total cost and estimated rows.  Not under leapfrog.force, which
-- scales the costs down to zero in EXPLAIN: the stock plans are disabled.
CREATE FUNCTION lf_cost_node(query text, OUT total float8, OUT plan_rows float8)
LANGUAGE plpgsql AS $$
DECLARE
	plan jsonb;
	node jsonb;
BEGIN
	EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
	node := jsonb_path_query_first(plan,
		'$.** ? (@."Custom Plan Provider" == "Index Merge Intersect")');
	IF node IS NULL THEN
		RAISE EXCEPTION 'no Index Merge Intersect in: %', plan;
	END IF;
	total := (node->>'Total Cost')::float8;
	plan_rows := (node->>'Plan Rows')::float8;
END
$$;

-- Does the node's cost depend on the cost of the function?
CREATE FUNCTION lf_cost_depends(func regprocedure, query text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
	cheap float8;
	dear float8;
BEGIN
	EXECUTE format('ALTER FUNCTION %s COST 1', func);
	SELECT total INTO cheap FROM lf_cost_node(query);
	EXECUTE format('ALTER FUNCTION %s COST 1000000', func);
	SELECT total INTO dear FROM lf_cost_node(query);
	EXECUTE format('ALTER FUNCTION %s COST 1', func);
	RETURN dear > cheap;
END
$$;

SET enable_seqscan = off;
SET enable_indexscan = off;
SET enable_bitmapscan = off;
SET enable_sort = off;

-- An equality the scan keys enforce: not in the Filter, not charged.
SELECT * FROM lf_plan($$
SELECT * FROM lf_cost WHERE coded_id === 5 AND owner_id = 5 ORDER BY id LIMIT 5 $$);
SELECT lf_cost_depends('lf_cost_eq(bigint, bigint)', $$
SELECT * FROM lf_cost WHERE coded_id === 5 AND owner_id = 5 ORDER BY id LIMIT 5 $$);

-- A clause implied by an inner predicate: not in the Filter, not charged.
SELECT * FROM lf_plan($$
SELECT * FROM lf_cost WHERE owner_id = 5 AND lf_cost_flag(flag) ORDER BY id LIMIT 5 $$);
SELECT lf_cost_depends('lf_cost_flag(integer)', $$
SELECT * FROM lf_cost WHERE owner_id = 5 AND lf_cost_flag(flag) ORDER BY id LIMIT 5 $$);

-- The same clause of a FOR UPDATE stays in the Filter for EvalPlanQual: charged.
SELECT * FROM lf_plan($$
SELECT * FROM lf_cost WHERE owner_id = 5 AND lf_cost_flag(flag) ORDER BY id LIMIT 5 FOR UPDATE $$);
SELECT lf_cost_depends('lf_cost_flag(integer)', $$
SELECT * FROM lf_cost WHERE owner_id = 5 AND lf_cost_flag(flag) ORDER BY id LIMIT 5 FOR UPDATE $$);

-- A clause no stream enforces: in the Filter, charged.
SELECT * FROM lf_plan($$
SELECT * FROM lf_cost WHERE owner_id = 5 AND kind = 5 AND lf_cost_flag(flag + 1) ORDER BY id LIMIT 5 $$);
SELECT lf_cost_depends('lf_cost_flag(integer)', $$
SELECT * FROM lf_cost WHERE owner_id = 5 AND kind = 5 AND lf_cost_flag(flag + 1) ORDER BY id LIMIT 5 $$);

RESET enable_seqscan;
RESET enable_indexscan;
RESET enable_bitmapscan;
RESET enable_sort;
DROP TABLE lf_cost;
DROP OPERATOR CLASS lf_cost_ops USING btree;
DROP OPERATOR FAMILY lf_cost_ops USING btree;
DROP OPERATOR === (bigint, bigint);
DROP FUNCTION lf_cost_eq(bigint, bigint);
DROP FUNCTION lf_cost_depends(regprocedure, text);
DROP FUNCTION lf_cost_node(text);
DROP FUNCTION lf_cost_flag(integer);
