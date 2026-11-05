-- leapfrog_outer_partial: a partial outer index; its predicate's conditions stay in the Filter.
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
CREATE INDEX lf_outer_partial_live_customer_id ON lf_outer_partial (customer_id, id)
	WHERE deleted_at IS NULL;
-- id is not its last column: that does not change the order it reads in
CREATE INDEX lf_outer_partial_product_id_kind ON lf_outer_partial (product_id, id, kind);
ANALYZE lf_outer_partial;

SELECT * FROM lf_plan($$
SELECT * FROM lf_outer_partial
WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id $$);

SELECT * FROM lf_plan($$
SELECT * FROM lf_outer_partial
WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL
ORDER BY id DESC LIMIT 20 FOR UPDATE $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC LIMIT 20 FOR UPDATE $$);

-- Rows soft-deleted after their entries were made: dead outer entries until VACUUM.
-- (id % 280 = 123: every other row of customer 3, product 4)
UPDATE lf_outer_partial SET deleted_at = now() WHERE id % 280 = 123;
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND deleted_at IS NULL ORDER BY id DESC $$);

-- A stream without a predicate becomes the outer one; with predicates on both sides one stays.
DROP INDEX lf_outer_partial_product_id_kind;
CREATE INDEX lf_outer_partial_product_two ON lf_outer_partial (product_id, id) WHERE kind = 1;
SELECT * FROM lf_plan($$
SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND kind = 1 AND deleted_at IS NULL ORDER BY id LIMIT 5 $$);
SELECT lf_check($$ SELECT * FROM lf_outer_partial WHERE customer_id = 3 AND product_id = 4 AND kind = 1 AND deleted_at IS NULL ORDER BY id $$);

DROP TABLE lf_outer_partial;
