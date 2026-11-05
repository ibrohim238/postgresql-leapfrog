#!/usr/bin/env bash
# Run one regression test or isolation spec N times ("make test-one").
# Usage: run-one.sh <name> [-r N] [--isolation]
# Environment: PGHOST/PGPORT/PGUSER, PG_REGRESS, PG_ISOLATION_REGRESS,
# PG_BINDIR, SCRATCH_ADMIN_DB.  See docs/testing.md.
set -euo pipefail

# shellcheck source=tests/scripts/scratch_db.sh
. "$(dirname "${BASH_SOURCE[0]}")/scratch_db.sh"
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

# NAMEDATALEN: the pid must survive the cut
pid=$$
db="lf_one_${name:0:$((62 - 7 - ${#pid}))}_$pid"
mark="leapfrog run-one scratch database (pid $$)"
out=$(mktemp -d "${TMPDIR:-/tmp}/leapfrog-run-one-$name.XXXXXX")
keep_out=false

drop_db() {
	local status=0
	scratch_db_drop "$db" "$mark" || status=$?
	if [ "$status" -eq "$SCRATCH_DB_FOREIGN" ]; then
		echo "run-one: database $db is not this script's (no comment '$mark'); not dropped" >&2
	fi
	return "$status"
}

cleanup() {
	drop_db || true
	$keep_out || rm -rf "$out"
}
trap cleanup EXIT

# a database as pg_regress's create_database() makes it, with the comment
create_db() {
	if scratch_db_exists "$db"; then
		echo "run-one: database $db exists and is not this run's; not touched" >&2
		exit 1
	fi
	SCRATCH_DB_OPTIONS='TEMPLATE template0' scratch_db_create "$db" "$mark" \
		lc_messages=C lc_monetary=C lc_numeric=C lc_time=C \
		bytea_output=hex timezone_abbreviations=Default
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
