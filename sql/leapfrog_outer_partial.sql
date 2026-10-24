--
-- leapfrog_outer_partial
--
-- A partial index on the outer side.  The node keeps only the inner index
-- predicate; the conditions implied by the outer predicate are never
-- removed from the node's Filter (intersect_scan_qual drops only the
-- equalities of both sides and what the inner predicate implies), so they
-- are evaluated on every row and again under EvalPlanQual
-- (tests/isolation/specs/leapfrog_outer_partial.spec).
--
LOAD 'leapfrog';
SET max_parallel_workers_per_gather = 0;

CREATE TABLE lf_outer_partial (
	id bigint PRIMARY KEY,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	kind integer NOT NULL,
	deleted_at timestamptz
);
INSERT INTO lf_outer_partial
SELECT g, g % 20, g % 7, g % 3,
	CASE WHEN g % 4 = 0 THEN '2026-01-01'::timestamptz END
FROM generate_series(1, 20000) g;
-- outer: partial, ends with id
CREATE INDEX lf_outer_partial_live_customer_id ON lf_outer_partial (customer_id, id)
	WHERE deleted_at IS NULL;
-- inner: id is not its last column, so it cannot be the outer side
CREATE INDEX lf_outer_partial_product_id_kind ON lf_outer_partial (product_id, id, kind);
ANALYZE lf_outer_partial;

-- The outer predicate's condition stays in the Filter.
SELECT * FROM lf_plan($$
SELECT * FROM lf_outer_partial
WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id $$);

-- The same for a target relation of SELECT FOR UPDATE.
SELECT * FROM lf_plan($$
SELECT * FROM lf_outer_partial
WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 FOR UPDATE $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 FOR UPDATE $$);

-- Rows that left the outer index: soft-deleted after their entries were
-- made, the dead entries stay until VACUUM.
-- (id % 280 = 123: every other row of customer 3, product 4)
UPDATE lf_outer_partial SET deleted_at = now() WHERE id % 280 = 123;
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC $$);

DROP TABLE lf_outer_partial;
