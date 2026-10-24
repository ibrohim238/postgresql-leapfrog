#!/usr/bin/env bash
# Summarise a results.csv produced by run.sh: median execution time, buffers
# and the plan node per (size, distribution, deleted%, owner, predicate,
# limit) for every strategy, side by side.  Uses psql with a temporary table
# so that no extra tooling is required.
set -euo pipefail

csv=${1:?usage: summarize.sh results.csv}
csv=$(realpath "$csv")

psql -X -q -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE r (
	size bigint, distribution text, deleted_pct int, strategy text, forced int,
	owner_label text, owner_id bigint, owner_rows bigint, owner_deleted bigint,
	predicate text, "limit" int, run int, plan_node text, exec_ms numeric,
	plan_ms numeric, shared_hit bigint, shared_read bigint, rows_out numeric,
	outer_read bigint, inner_read bigint, heap_fetches bigint, rows_removed bigint,
	index_bytes bigint);
\\copy r FROM '$csv' WITH (FORMAT csv, HEADER true, NULL '')

\\pset format aligned
\\pset footer off

WITH m AS (
	SELECT size, distribution, deleted_pct, owner_label, owner_rows, owner_deleted, predicate, "limit",
		strategy || CASE WHEN forced = 1 THEN '*' ELSE '' END AS strat,
		percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS med_ms,
		percentile_cont(0.5) WITHIN GROUP (ORDER BY shared_hit + shared_read) AS med_buf,
		max(rows_out) AS rows_out,
		min(plan_node) AS plan_node,
		max(index_bytes) AS index_bytes
	FROM r
	GROUP BY 1,2,3,4,5,6,7,8,9
)
SELECT size, distribution AS dist, deleted_pct AS del, owner_label AS owner, owner_rows, owner_deleted, predicate AS pred, "limit",
	strat, round(med_ms::numeric, 3) AS med_ms, med_buf::bigint AS med_buf, rows_out,
	plan_node, pg_size_pretty(index_bytes) AS indexes
FROM m
ORDER BY size, distribution, deleted_pct, owner_rows DESC, predicate, "limit", strat;

\\echo
\\echo 'Speed-up of B (leapfrog, planner choice) and B* (forced) over A and C, median execution time:'
WITH m AS (
	SELECT size, distribution, deleted_pct, owner_label, predicate, "limit",
		strategy || CASE WHEN forced = 1 THEN '*' ELSE '' END AS strat,
		percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms) AS med_ms
	FROM r GROUP BY 1,2,3,4,5,6,7
), p AS (
	SELECT size, distribution, deleted_pct, owner_label, predicate, "limit",
		max(med_ms) FILTER (WHERE strat = 'A') AS a,
		max(med_ms) FILTER (WHERE strat = 'B') AS b,
		max(med_ms) FILTER (WHERE strat = 'B*') AS bf,
		max(med_ms) FILTER (WHERE strat = 'C') AS c
	FROM m GROUP BY 1,2,3,4,5,6
)
SELECT size, distribution AS dist, deleted_pct AS del, owner_label AS owner, predicate AS pred, "limit",
	round(a::numeric, 2) AS a_ms, round(b::numeric, 2) AS b_ms, round(bf::numeric, 2) AS bforced_ms, round(c::numeric, 2) AS c_ms,
	round((a / nullif(b, 0))::numeric, 2) AS "A/B", round((a / nullif(bf, 0))::numeric, 2) AS "A/B*", round((c / nullif(b, 0))::numeric, 2) AS "C/B"
FROM p
ORDER BY size, distribution, deleted_pct, owner_label, predicate, "limit";
SQL
