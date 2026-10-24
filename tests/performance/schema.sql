-- Benchmark schema and data generator.
--
-- Variables (psql -v):
--   rows          number of rows
--   seed          setseed() argument, fixed for reproducibility
--   distribution  'uniform'  : owners and deletions spread evenly
--                 'skewed'   : a few owners hold most rows, deletions among
--                              the oldest ids only (typical soft-delete shape)
--   deleted_pct   share of deleted rows, percent
--
-- Three index strategies are created side by side; a benchmark run disables
-- the ones that do not belong to the strategy under test by dropping and
-- recreating them (see run.sh), so every strategy sees the same heap.
\set ON_ERROR_STOP on

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
	id bigint NOT NULL,
	customer_id bigint NOT NULL,
	product_id bigint NOT NULL,
	deleted_at timestamptz,
	amount bigint NOT NULL,
	payload text
);

SELECT setseed(:seed) \gset

INSERT INTO orders (id, customer_id, product_id, deleted_at, amount, payload)
SELECT g,
	CASE :'distribution'
		WHEN 'skewed' THEN
			-- 10 owners hold 50% of the rows, 1000 owners the rest
			CASE WHEN random() < 0.5 THEN floor(random() * 10)::bigint
				 ELSE 10 + floor(random() * 1000)::bigint END
		ELSE floor(random() * 1000)::bigint
	END,
	floor(random() * 5000)::bigint,
	CASE :'distribution'
		WHEN 'skewed' THEN
			-- deletions among the oldest 40% of ids only
			CASE WHEN g < :rows * 0.4 AND random() * 100 < :deleted_pct * 2.5
				 THEN '2026-01-01'::timestamptz + g * interval '1 second' END
		ELSE
			CASE WHEN random() * 100 < :deleted_pct
				 THEN '2026-01-01'::timestamptz + g * interval '1 second' END
	END,
	floor(random() * 100000)::bigint,
	repeat('x', 40)
FROM generate_series(1, :rows) g;

ALTER TABLE orders ADD PRIMARY KEY (id);
VACUUM ANALYZE orders;
