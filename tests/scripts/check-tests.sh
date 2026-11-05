#!/usr/bin/env bash
# Consistency of the test lists and expected files ("make check-tests"), after
# Citus's ci/check_all_tests_are_run.sh and TimescaleDB's
# scripts/check_orphaned_test_output_files.sh.  Fails when:
#
#   - a tests/regress/sql/*.sql is not in REGRESS, or a
#     tests/isolation/specs/*.spec is not in ISOLATION (the Makefile);
#   - a name in REGRESS or ISOLATION has no .sql or .spec;
#   - an expected file, <name>.out or <name>_N.out, belongs to no test;
#   - an alternative output <name>_N.out is identical to <name>.out;
#   - an alternative output is not explained in the header comment of its
#     test, or the header explains one that does not exist.
#
# The header rule is Citus's (src/test/regress/README.md): every alternative
# output says why it exists and when it can go.  The header comment is the
# block of comment and blank lines at the top of the .sql or .spec file, and
# it holds, on one line, for every <name>_N.out:
#
#   -- alternative output <name>_N.out: <why>; remove when <condition>
#
# in a .sql file, and the same with "#" in place of "--" in a .spec file.
#
# Needs no server: it reads the Makefile and the files of the source tree.
set -euo pipefail

# shellcheck source=tests/scripts/makevars.sh
. "$(dirname "${BASH_SOURCE[0]}")/makevars.sh"
cd "$(dirname "$0")/../.."

errors=0

error() {
	echo "check-tests: $*" >&2
	errors=$((errors + 1))
}

# The header comment of a test file: the lines up to the first one that is
# neither a comment (with the given marker) nor blank.
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

		# not "header | grep -q": grep may exit first, and pipefail would
		# report the writer's SIGPIPE
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
