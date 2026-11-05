#!/usr/bin/env bash
# Check the test lists and expected files; no server.
# Usage: check-tests.sh
# See docs/testing.md.
set -euo pipefail

# shellcheck source=tests/scripts/makevars.sh
. "$(dirname "${BASH_SOURCE[0]}")/makevars.sh"
cd "$(dirname "$0")/../.."

errors=0

error() {
	echo "check-tests: $*" >&2
	errors=$((errors + 1))
}

# header <file> <marker>: the leading comment and blank lines
header() {
	awk -v marker="$2" '
		index($0, marker) == 1 || /^[[:space:]]*$/ { print; next }
		{ exit }
	' "$1"
}

# check_suite <variable> <directory> <source subdirectory> <extension> <comment marker>
check_suite() {
	local var=$1 dir=$2 src=$2/$3 ext=$4 marker=$5
	local listed name f base n files

	listed=$(make_var "$var")
	[ -n "$listed" ] || error "no $var in the Makefile"

	# (a) every test file is listed
	for f in "$src"/*."$ext"; do
		[ -e "$f" ] || continue
		name=$(basename "$f" ".$ext")
		grep -qxF "$name" <<<"$listed" ||
			error "$f is not in $var in the Makefile; add it, or remove the file"
	done

	# (b) every listed test has a file
	for name in $listed; do
		[ -f "$src/$name.$ext" ] ||
			error "$name is in $var but $src/$name.$ext does not exist"
		[ -f "$dir/expected/$name.out" ] ||
			error "$name is in $var but $dir/expected/$name.out does not exist"
	done

	# (c), (d), (e) the expected files
	for f in "$dir/expected"/*.out; do
		[ -e "$f" ] || continue
		base=$(basename "$f" .out)
		if [ -f "$src/$base.$ext" ]; then
			continue
		fi
		if [[ $base =~ ^(.+)_([0-9]+)$ ]] &&
			[ -f "$src/${BASH_REMATCH[1]}.$ext" ]; then
			name=${BASH_REMATCH[1]}
		else
			error "$f belongs to no test (no $src/$base.$ext); remove it"
			continue
		fi

		if [ -f "$dir/expected/$name.out" ] && cmp -s "$f" "$dir/expected/$name.out"; then
			error "$f is identical to $name.out; remove the unnecessary alternative"
		fi

		# not a pipe: grep -q may exit first, a SIGPIPE under pipefail
		if ! grep -qE "^$marker alternative output ${base}\\.out: .+; remove when .+" \
			<<<"$(header "$src/$name.$ext" "$marker")"; then
			error "$f is not explained in the header comment of $src/$name.$ext;" \
				"add a line \"$marker alternative output $base.out: <why>; remove when <condition>\""
		fi
	done

	# (e) the header explains only alternatives that exist
	for f in "$src"/*."$ext"; do
		[ -e "$f" ] || continue
		files=$(grep -oE "^$marker alternative output [^ :]+" "$f" | sed 's/.* //') || true
		for n in $files; do
			[ -f "$dir/expected/$n" ] ||
				error "$f explains an alternative output $n that does not exist in $dir/expected"
		done
	done

	return 0
}

check_suite REGRESS tests/regress sql sql --
check_suite ISOLATION tests/isolation specs spec '#'

if [ "$errors" -gt 0 ]; then
	echo "check-tests: $errors problem(s)" >&2
	exit 1
fi
