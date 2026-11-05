#!/usr/bin/env bash
# Run one regression test or isolation spec, N times, against a running
# server ("make test-one"), after Citus's run_test.py -r and TimescaleDB's
# TESTS=.  Stops at the first failure, prints its diff and the number of runs
# that passed before it.
#
# Usage: run-one.sh <name> [-r N] [--isolation]
#   <name>        tests/regress/sql/<name>.sql, or with --isolation
#                 tests/isolation/specs/<name>.spec
#   -r N          run it N times (default 1)
#   --isolation   an isolation spec instead of a regression test
#
# Every run gets a fresh database, created here the way pg_regress creates
# one (template0, the same ALTER DATABASE settings, CREATE EXTENSION
# leapfrog) and passed with --use-existing, so pg_regress never creates or
# drops a database itself.  A regression test other than leapfrog_setup runs
# after leapfrog_setup in the same database: that test creates the helpers
# (lf_check, lf_plan, ...) the others use, and its own output is checked as in
# the full suite, so no expected file changes.
#
# Environment: PGHOST/PGPORT/PGUSER (a superuser, as for make installcheck);
# PG_REGRESS, PG_ISOLATION_REGRESS, PG_BINDIR (set by the Makefile; default:
# the PGXS tree of PG_CONFIG).  Scratch database: lf_one_<name>_<pid>,
# recognised by its comment and dropped after every run; a database of that
# name without the comment is not touched, and the script fails.
set -euo pipefail

cd "$(dirname "$0")/../.."

usage() {
	echo "usage: $0 <name> [-r N] [--isolation]" >&2
	exit 2
}

name=
repeats=1
isolation=false
while [ $# -gt 0 ]; do
	case "$1" in
		-r)
			[ $# -ge 2 ] || usage
			repeats=$2
			shift 2
			;;
		-r*)
			repeats=${1#-r}
			shift
			;;
		--isolation)
			isolation=true
			shift
			;;
		-h | --help) usage ;;
		-*) usage ;;
		*)
			[ -z "$name" ] || usage
			name=$1
			shift
			;;
	esac
done
[ -n "$name" ] || usage
[[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || { echo "run-one: bad test name '$name'" >&2; exit 2; }
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo "run-one: -r needs a positive number, not '$repeats'" >&2; exit 2; }

PG_CONFIG=${PG_CONFIG:-pg_config}
pgxs=$("$PG_CONFIG" --pkglibdir)/pgxs
PG_BINDIR=${PG_BINDIR:-$("$PG_CONFIG" --bindir)}

if $isolation; then
	kind=isolation
	runner=${PG_ISOLATION_REGRESS:-$pgxs/src/test/isolation/pg_isolation_regress}
	inputdir=tests/isolation
	source=$inputdir/specs/$name.spec
	tests=("$name")
else
	kind=regress
	runner=${PG_REGRESS:-$pgxs/src/test/regress/pg_regress}
	inputdir=tests/regress
	source=$inputdir/sql/$name.sql
	if [ "$name" = leapfrog_setup ]; then
		tests=("$name")
	else
		tests=(leapfrog_setup "$name")
	fi
fi
[ -f "$source" ] || { echo "run-one: no $source" >&2; exit 2; }
[ -x "$runner" ] || { echo "run-one: no $runner (PGXS of $PG_CONFIG)" >&2; exit 2; }

PSQL="psql -X -q -v ON_ERROR_STOP=1 -d ${RUN_ONE_ADMIN_DB:-postgres}"
db=lf_one_${name}_$$
db=${db:0:63}
mark="leapfrog run-one scratch database (pid $$)"
out=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-run-one-$name.XXXXXX")
keep_out=false

# 1 when the database exists, empty when not
db_exists() {
	$PSQL -tA -v db="$db" <<< "SELECT 1 FROM pg_database WHERE datname = :'db'"
}

# drop the scratch database if it carries this run's comment
drop_db() {
	local mine
	mine=$($PSQL -tA -v db="$db" -v mark="$mark" <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
	)
	case "$mine" in
		t) $PSQL -v db="$db" <<< 'DROP DATABASE :"db" WITH (FORCE)' ;;
		f)
			echo "run-one: database $db is not this script's (no comment '$mark'); not dropped" >&2
			return 1
			;;
	esac
}

cleanup() {
	drop_db || true
	$keep_out || rm -rf "$out"
}
trap cleanup EXIT

# a database as pg_regress's create_database() makes it, with the comment
create_db() {
	if [ -n "$(db_exists)" ]; then
		echo "run-one: database $db exists and is not this run's; not touched" >&2
		exit 1
	fi
	$PSQL -v db="$db" -v mark="$mark" <<-'SQL'
		CREATE DATABASE :"db" TEMPLATE template0;
		COMMENT ON DATABASE :"db" IS :'mark';
		ALTER DATABASE :"db" SET lc_messages TO 'C';
		ALTER DATABASE :"db" SET lc_monetary TO 'C';
		ALTER DATABASE :"db" SET lc_numeric TO 'C';
		ALTER DATABASE :"db" SET lc_time TO 'C';
		ALTER DATABASE :"db" SET bytea_output TO 'hex';
		ALTER DATABASE :"db" SET timezone_abbreviations TO 'Default';
	SQL
	psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c 'CREATE EXTENSION IF NOT EXISTS leapfrog'
}

passed=0
for ((run = 1; run <= repeats; run++)); do
	create_db
	rundir=$out/run-$run
	mkdir -p "$rundir"
	status=0
	"$runner" --use-existing --dbname="$db" --bindir="$PG_BINDIR" \
		--load-extension=leapfrog --inputdir="$inputdir" \
		--outputdir="$rundir" "${tests[@]}" > "$rundir/log" 2>&1 || status=$?
	drop_db
	if [ "$status" -ne 0 ]; then
		keep_out=true
		cat "$rundir/log"
		if [ -s "$rundir/regression.diffs" ]; then
			cat "$rundir/regression.diffs"
		fi
		echo "run-one: $kind $name: FAILED on run $run of $repeats," \
			"$passed passed before it; output in $rundir"
		exit 1
	fi
	passed=$((passed + 1))
	echo "run-one: $kind $name: run $run of $repeats ok"
done
echo "run-one: $kind $name: $passed of $repeats runs passed"
