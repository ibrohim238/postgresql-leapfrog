#!/usr/bin/env bash
# Extension upgrade test ("make installcheck-upgrade"): install an earlier
# release with CREATE EXTENSION leapfrog VERSION 'PREV', update it with
# ALTER EXTENSION leapfrog UPDATE, and check that the result is the current
# version with the same objects as a fresh CREATE EXTENSION.  The
# leapfrog_setup regression test then runs against the updated database.
#
# A release renames the install script, so leapfrog--PREV.sql exists only in
# the git history, at tag vPREV.  It is taken from there with git show and put,
# with the control file and every script of the source tree, into a scratch
# directory that the server reads through extension_control_path (PostgreSQL
# 18): nothing is written into the installation, but the server must run on
# this machine and see the scratch directory.  The shared library must be
# installed (make install) and match the source tree.
#
# Environment (set by the Makefile):
#   EXTVERSION    the current version
#   PG_REGRESS    the pg_regress binary of PGXS
#   PG_BINDIR     the directory of psql, for pg_regress --bindir
#   UPGRADE_FROM  the versions to update from, separated by spaces; default:
#                 the newest release tag below EXTVERSION, and every older one
#                 the source tree still has an update script from
#   SCRATCH_ADMIN_DB  the database the scratch databases are created and
#                 dropped from (default postgres; see scratch_db.sh)
#
# Connection: PGHOST/PGPORT/PGUSER, a superuser (extension_control_path is a
# superuser setting).  Scratch databases: leapfrog_upgrade_*, recognised by
# their comment and dropped; one of those names without the comment is not
# touched, and the test fails (see scratch_db.sh).
set -euo pipefail

# shellcheck source=tests/scripts/scratch_db.sh
. "$(dirname "${BASH_SOURCE[0]}")/scratch_db.sh"
cd "$(dirname "$0")/../.."

: "${EXTVERSION:?EXTVERSION is not set; run make installcheck-upgrade}"
: "${PG_REGRESS:?PG_REGRESS is not set; run make installcheck-upgrade}"
: "${PG_BINDIR:?PG_BINDIR is not set; run make installcheck-upgrade}"

PSQL="psql -X -q -v ON_ERROR_STOP=1"
mark='leapfrog installcheck-upgrade scratch database'

fail() {
	echo "installcheck-upgrade: $*" >&2
	exit 1
}

# -- the versions to update from ---------------------------------------------

if [ -z "${UPGRADE_FROM:-}" ]; then
	tags=$(git tag --list 'v[0-9]*' 2>/dev/null | sed 's/^v//') ||
		fail "git tag failed; the test needs the git history"
	older=$(printf '%s\n' $tags "$EXTVERSION" | sort -uV |
		sed -n "/^${EXTVERSION//./\\.}\$/q;p")
	[ -n "$older" ] ||
		fail "no release tag below $EXTVERSION (a shallow clone? git fetch --tags)"
	newest=$(printf '%s\n' $older | tail -n 1)
	UPGRADE_FROM=
	for v in $older; do
		if [ "$v" = "$newest" ] || compgen -G "leapfrog--$v--*.sql" >/dev/null; then
			UPGRADE_FROM="$UPGRADE_FROM $v"
		fi
	done
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-upgrade.XXXXXX")
dbs=()

create_db() {
	local status=0
	scratch_db_drop "$1" "$mark" || status=$?
	[ "$status" -ne "$SCRATCH_DB_FOREIGN" ] ||
		fail "database $1 exists and is not this test's (no comment '$mark')"
	[ "$status" -eq 0 ] || exit "$status"
	SCRATCH_DB_OPTIONS='TEMPLATE template0' scratch_db_create "$1" "$mark" \
		"extension_control_path=$tmp"
	dbs+=("$1")
}

cleanup() {
	local db
	for db in "${dbs[@]}"; do
		scratch_db_drop "$db" "$mark" >/dev/null 2>&1 || true
	done
	rm -rf "$tmp"
}
trap cleanup EXIT

# -- the scratch extension directory -----------------------------------------

mkdir -p "$tmp/extension"
cp leapfrog.control leapfrog--*.sql "$tmp/extension/"
for v in $UPGRADE_FROM; do
	git show "v$v:leapfrog--$v.sql" > "$tmp/extension/leapfrog--$v.sql" ||
		fail "no leapfrog--$v.sql at tag v$v"
done
chmod -R a+rX "$tmp"

# The extension's member objects with their definitions and comments.
objects_sql="
SELECT pg_describe_object(d.classid, d.objid, d.objsubid),
	CASE WHEN d.classid = 'pg_proc'::regclass
		THEN pg_get_functiondef(d.objid) END,
	obj_description(d.objid, d.classid::regclass::text)
FROM pg_depend d
	JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass
		AND d.refobjid = e.oid
WHERE e.extname = 'leapfrog' AND d.deptype = 'e'
ORDER BY 1"

# -- the reference: a fresh installation of the current version --------------

fresh=leapfrog_upgrade_fresh
create_db "$fresh"
$PSQL -d "$fresh" -c "CREATE EXTENSION leapfrog"
$PSQL -tA -d "$fresh" -c "$objects_sql" > "$tmp/fresh.objects"
[ -s "$tmp/fresh.objects" ] || fail "CREATE EXTENSION leapfrog created no objects"

# -- every version to update from --------------------------------------------

status=0
for v in $UPGRADE_FROM; do
	db=leapfrog_upgrade_${v//[^0-9a-zA-Z]/_}
	echo "== $v -> $EXTVERSION"
	create_db "$db"

	if ! $PSQL -d "$db" -v v="$v" <<-'SQL'
		CREATE EXTENSION leapfrog VERSION :'v';
		ALTER EXTENSION leapfrog UPDATE;
	SQL
	then
		echo "not ok: ALTER EXTENSION leapfrog UPDATE from $v failed"
		status=1
		continue
	fi

	got=$($PSQL -tA -d "$db" -c "SELECT extversion FROM pg_extension WHERE extname = 'leapfrog'")
	if [ "$got" != "$EXTVERSION" ]; then
		echo "not ok: extversion after the update from $v is $got, not $EXTVERSION"
		status=1
		continue
	fi

	got=$($PSQL -tA -d "$db" -c "SELECT leapfrog_version()")
	if [ "$got" != "$EXTVERSION" ]; then
		echo "not ok: leapfrog_version() is $got, not $EXTVERSION (make install?)"
		status=1
		continue
	fi

	$PSQL -tA -d "$db" -c "$objects_sql" > "$tmp/$v.objects"
	if ! diff -u "$tmp/fresh.objects" "$tmp/$v.objects"; then
		echo "not ok: the objects after the update from $v differ from a fresh CREATE EXTENSION (diff above)"
		status=1
		continue
	fi

	mkdir -p "$tmp/regress-$v"
	if ! "$PG_REGRESS" --inputdir=tests/regress --bindir="$PG_BINDIR" --use-existing \
		--dbname="$db" --outputdir="$tmp/regress-$v" leapfrog_setup; then
		cat "$tmp/regress-$v/regression.diffs" 2>/dev/null || true
		echo "not ok: leapfrog_setup after the update from $v"
		status=1
		continue
	fi

	echo "ok: $v -> $EXTVERSION"
done

[ $status -eq 0 ] && echo "installcheck-upgrade: all updates to $EXTVERSION passed"
exit $status
