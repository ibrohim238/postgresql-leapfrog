-- Planner choices of a run.sh results.csv run with BENCH_FORCE=1:
--
--   psql -v csv=tests/performance/results/<run>/results.csv -f tests/performance/choices.sql
--
-- For every query (size, distribution, deleted share, customer, live or
-- deleted rows, LIMIT) the median execution time of A, of B as the planner
-- chose it and of B* (leapfrog.force), and:
--   chosen   the planner chose the node for B
--   wrong    chosen, and more than 15 % slower than the faster of A and B*
--   miss     not chosen, though B* is more than 15 % faster than both B and
--            A (A's index is one of B's, so A's plan is open to B's
--            planner too; a B slower than A is the stock planner's miss)
\set ON_ERROR_STOP on
CREATE TEMP TABLE r (
	size bigint, distribution text, deleted_pct int, strategy text,
	forced int, owner_label text, owner_id bigint, owner_rows bigint,
	owner_deleted bigint, predicate text, "limit" int, run int,
	plan_node text, exec_ms numeric, plan_ms numeric, shared_hit bigint,
	shared_read bigint, rows_out numeric, outer_read bigint,
	inner_read bigint, heap_fetches bigint, rows_removed bigint,
	index_bytes bigint
);
\set copy '\\copy r FROM ' :'csv' ' WITH (FORMAT csv, HEADER)'
:copy

CREATE TEMP VIEW q AS
SELECT size, distribution, deleted_pct, owner_label, predicate, "limit",
	percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)
		FILTER (WHERE strategy = 'A') AS a_ms,
	percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)
		FILTER (WHERE strategy = 'B' AND forced = 0) AS b_ms,
	percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)
		FILTER (WHERE strategy = 'B' AND forced = 1) AS bf_ms,
	bool_or(plan_node LIKE '%Merge Intersect%')
		FILTER (WHERE strategy = 'B' AND forced = 0) AS chosen
FROM r
GROUP BY 1, 2, 3, 4, 5, 6;

SELECT count(*) AS queries,
	count(*) FILTER (WHERE chosen) AS chosen,
	count(*) FILTER (WHERE chosen AND b_ms > least(a_ms, bf_ms) * 1.15) AS wrong,
	count(*) FILTER (WHERE NOT chosen AND bf_ms * 1.15 < least(a_ms, b_ms)) AS miss
FROM q;

-- the misses and wrong choices, largest first
SELECT distribution, deleted_pct, owner_label, predicate, "limit",
	round(a_ms::numeric, 2) AS a, round(b_ms::numeric, 2) AS b,
	round(bf_ms::numeric, 2) AS b_forced, chosen,
	CASE WHEN chosen THEN 'wrong' ELSE 'miss' END AS verdict
FROM q
WHERE (chosen AND b_ms > least(a_ms, bf_ms) * 1.15)
	OR (NOT chosen AND bf_ms * 1.15 < least(a_ms, b_ms))
ORDER BY greatest(least(a_ms, b_ms) / bf_ms, b_ms / least(a_ms, bf_ms)) DESC
LIMIT 15;
