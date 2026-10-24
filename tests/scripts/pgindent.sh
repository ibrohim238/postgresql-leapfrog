#!/usr/bin/env bash
# Check (or apply) the PostgreSQL core code style with pgindent.
#
#   bash tests/scripts/pgindent.sh          fail and print a diff when the code
#                                           is not pgindent-clean
#   bash tests/scripts/pgindent.sh --fix    reformat the sources in place
#
# pgindent and pg_bsd_indent are fetched from the PostgreSQL REL_18_STABLE
# branch and built against the installed server headers (pg_config); the
# typedefs of this extension are appended to the core typedefs list.
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

# shellcheck disable=SC2086
perl "$work/postgres/src/tools/pgindent/pgindent" $mode \
	--indent="$work/pg_bsd_indent" \
	--typedefs="$work/typedefs.list" \
	src/*.c src/*.h
