#!/usr/bin/env bash
# Check (or apply) the PostgreSQL core code style with pgindent.
#
#   bash tests/scripts/pgindent.sh          fail and print a diff when the code
#                                           is not pgindent-clean
#   bash tests/scripts/pgindent.sh --fix    reformat the sources in place
#
# pgindent and pg_bsd_indent are fetched from the PostgreSQL REL_18_STABLE
# branch and built against the installed server headers (pg_config); the
# typedefs of this extension are appended to the core typedefs list.  Before
# that, find_typedef from the same branch checks src/typedefs.list against
# the built objects (src/*.o, so run make first).
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$(pwd)

mode="--check --diff"
if [ "${1:-}" = "--fix" ]; then
	mode=
fi

PG_CONFIG=${PG_CONFIG:-pg_config}
work=${PGINDENT_WORKDIR:-${TMPDIR:-/tmp}/leapfrog-pgindent}

if [ ! -x "$work/pg_bsd_indent" ]; then
	rm -rf "$work"
	git clone -q --depth 1 --filter=blob:none --sparse -b REL_18_STABLE \
		https://github.com/postgres/postgres.git "$work/postgres"
	git -C "$work/postgres" sparse-checkout set src/tools/pgindent src/tools/pg_bsd_indent

	inc=$($PG_CONFIG --includedir-server)
	find_lib() {
		local dir
		for dir in "$($PG_CONFIG --pkglibdir)" "$($PG_CONFIG --libdir)"; do
			if [ -f "$dir/$1" ]; then
				echo "$dir/$1"
				return
			fi
		done
		echo "$1 not found next to $PG_CONFIG" >&2
		exit 1
	}
	commonlib=$(find_lib libpgcommon.a)
	portlib=$(find_lib libpgport.a)

	src="$work/postgres/src/tools/pg_bsd_indent"
	${CC:-gcc} -O1 -I"$src" -I"$inc" -o "$work/pg_bsd_indent" \
		"$src"/args.c "$src"/err.c "$src"/indent.c "$src"/io.c \
		"$src"/lexi.c "$src"/parse.c "$src"/pr_comment.c \
		"$commonlib" "$portlib"
fi

cat "$work/postgres/src/tools/pgindent/typedefs.list" "$root/src/typedefs.list" \
	> "$work/typedefs.list"

# Is NAME defined by a typedef in src/: "} NAME;" closing a struct, union or
# enum, or "typedef ... NAME;" for a plain one.
defined_here() {
	grep -q -E "^\}[[:space:]]*$1[[:space:]]*;|^typedef[^;{]*[^[:alnum:]_]$1[[:space:]]*;" \
		src/*.c src/*.h
}

# src/typedefs.list against the objects, as PostgreSQL makes its own list:
# src/tools/find_typedef reads the typedef names from the debugging symbols
# (pg_config's CFLAGS carry -g).  A typedef defined in src/ that the objects
# use and the list lacks fails the check, since pgindent would misformat the
# code that uses it; the objects also name the typedefs of PostgreSQL and
# the system headers, left out by the core list and by defined_here.  An
# entry of the list that src/ no longer has is only reported.  find_typedef
# misses a typedef that declares nothing (see its header), so the reverse
# check looks at the sources, not the objects.
check_typedefs() {
	local find_typedef="$work/postgres/src/tools/find_typedef" found name
	local status=0 objects=0 obj
	for obj in src/*.o; do
		[ -f "$obj" ] && objects=$((objects + 1))
		if [ -f "$obj" ] && [ "${obj%.o}.c" -nt "$obj" ]; then
			echo "pgindent.sh: $obj is older than its source; run make first" >&2
		fi
	done
	if [ "$objects" = 0 ]; then
		echo "pgindent.sh: no src/*.o, typedefs not checked (run make first)" >&2
		return 0
	fi
	if ! command -v objdump >/dev/null 2>&1 || [ ! -f "$find_typedef" ]; then
		echo "pgindent.sh: objdump (binutils) or find_typedef missing," \
			"typedefs not checked" >&2
		return 0
	fi
	# objdump complains about the sources next to the objects
	found=$(sh "$find_typedef" src 2>/dev/null || true)
	if [ -z "$found" ]; then
		echo "pgindent.sh: no typedefs in the debugging symbols of src/*.o" \
			"(built without -g?), typedefs not checked" >&2
		return 0
	fi
	while IFS= read -r name; do
		if defined_here "$name"; then
			echo "src/typedefs.list lacks $name, a typedef of src/ the objects use" >&2
			status=1
		fi
	done < <(printf '%s\n' "$found" | LC_ALL=C sort -u |
		LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$work/typedefs.list"))
	while IFS= read -r name; do
		if ! defined_here "$name"; then
			echo "pgindent.sh: warning: src/typedefs.list has $name," \
				"which src/ does not define" >&2
		fi
	done <"$root/src/typedefs.list"
	return "$status"
}

typedefs_ok=1
check_typedefs || typedefs_ok=0
status=0

# $mode is two options or none, split on purpose
# shellcheck disable=SC2086
perl "$work/postgres/src/tools/pgindent/pgindent" $mode \
	--indent="$work/pg_bsd_indent" \
	--typedefs="$work/typedefs.list" \
	src/*.c src/*.h || status=$?

if [ "$typedefs_ok" = 0 ]; then
	echo "pgindent.sh: add the missing typedefs to src/typedefs.list" \
		"(sorted), or pgindent misformats the code that uses them" >&2
	[ "$status" != 0 ] || status=1
fi
exit "$status"
