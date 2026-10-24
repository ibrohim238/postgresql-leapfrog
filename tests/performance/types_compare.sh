#!/usr/bin/env bash
# Compare two runs of types_bench.sh: for every case, limit and mode the node
# that ran, planning and execution medians and p90 of both builds, and the
# change of the execution median in percent.
#
#   bash types_compare.sh <dir of the baseline> <dir of the new build>
set -euo pipefail

if [ $# -ne 2 ]; then
	echo "usage: $0 <baseline dir> <new dir>" >&2
	exit 2
fi

awk -F, '
	FNR == 1 { next }
	NR == FNR {
		key = $2 "," $3 "," $4
		node[key] = $5; pm[key] = $7; em[key] = $9; e90[key] = $10
		hit[key] = $12; ent[key] = $14
		next
	}
	{
		key = $2 "," $3 "," $4
		if (!(key in em))
			next
		change = em[key] > 0 ? sprintf("%+.1f%%", ($9 - em[key]) / em[key] * 100) : "-"
		printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
			$2, $3, $4, node[key], $5, pm[key], $7, em[key], $9, change,
			e90[key], $10, hit[key], $12, ent[key], $14
	}
	BEGIN {
		print "case,limit,mode,node_old,node_new,plan_ms_old,plan_ms_new,exec_ms_old,exec_ms_new,exec_change,exec_p90_old,exec_p90_new,hit_old,hit_new,entries_old,entries_new"
	}
' "$1/summary.csv" "$2/summary.csv" | column -s, -t
