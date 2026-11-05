#!/usr/bin/env bash
# Rerun the tests the last "make installcheck" failed.
# Usage: rerun-failed.sh [-r N]
# See docs/testing.md.
set -euo pipefail

cd "$(dirname "$0")/../.."

failed_in() {
	[ -f "$1" ] || return 0
	sed -nE 's/^not ok +[0-9]+ +[-+] +([A-Za-z0-9_]+).*/\1/p' "$1"
}

regress=$(failed_in tests/regress/regression.out)
isolation=$(failed_in tests/isolation/regression.out)

if [ ! -f tests/regress/regression.out ] && [ ! -f tests/isolation/regression.out ]; then
	echo "installcheck-rerun: no regression.out; run make installcheck first" >&2
	exit 2
fi
if [ -z "$regress$isolation" ]; then
	echo "installcheck-rerun: no failed tests"
	exit 0
fi

still_failing=()
for name in $regress; do
	bash tests/scripts/run-one.sh "$name" "$@" || still_failing+=("$name")
done
for name in $isolation; do
	bash tests/scripts/run-one.sh "$name" --isolation "$@" ||
		still_failing+=("isolation/$name")
done

if [ ${#still_failing[@]} -gt 0 ]; then
	echo "installcheck-rerun: still failing: ${still_failing[*]}"
	exit 1
fi
echo "installcheck-rerun: every failed test passed on rerun"
