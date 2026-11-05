# shellcheck shell=bash
# Sourced: the benchmarks' marked database BENCH_DB and its advisory lock.
# Environment: BENCH_DB, BENCH_ADMIN_DB, PGHOST/PGPORT/PGUSER.
# See docs/testing.md.

BENCH_DB_MARK='leapfrog benchmark scratch database'
BENCH_DB_LOCK_KEY='1818650210, 1'

# shellcheck source=tests/scripts/scratch_db.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/scratch_db.sh"

# bench_db_use: bench_db_prepare and bench_db_lock, released at exit.
bench_db_use() {
	bench_db_prepare
	bench_db_lock
	trap bench_db_unlock EXIT
}

# bench_db_prepare: create or check BENCH_DB, then point PGDATABASE at it.
bench_db_prepare() {
	BENCH_DB=${BENCH_DB:-leapfrog_bench}
	local state
	state=$(scratch_db_state "$BENCH_DB" "$BENCH_DB_MARK")
	case $state in
		t) ;;
		f)
			echo "$(basename "$0"): database $BENCH_DB exists and is not" \
				"a benchmark database (no comment '$BENCH_DB_MARK');" \
				"set BENCH_DB to another name" >&2
			exit 1 ;;
		*) scratch_db_create "$BENCH_DB" "$BENCH_DB_MARK" ;;
	esac
	export PGDATABASE=$BENCH_DB
	psql -X -q -v ON_ERROR_STOP=1 -c "SET client_min_messages = warning" \
		-c "CREATE EXTENSION IF NOT EXISTS leapfrog"
}

# bench_db_lock: take the benchmark lock in PGDATABASE, or exit.
bench_db_lock() {
	# a random token, since $$ repeats across containers; first, as the name
	# is cut at 63 bytes
	local token app state
	token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	app="lf_bench $token $(basename "$0")"
	app=${app:0:63}
	exec {BENCH_DB_LOCK_FD}> >(PGAPPNAME=$app psql -X -q -tA \
		-v ON_ERROR_STOP=1 >/dev/null 2>&1)
	BENCH_DB_LOCK_PID=$!
	BENCH_DB_LOCK_APP=$app
	cat >&"$BENCH_DB_LOCK_FD" <<-SQL
		SELECT pg_try_advisory_lock($BENCH_DB_LOCK_KEY) AS locked \gset
		\if :locked
		\else
		\quit
		\endif
	SQL
	for _ in $(seq 1 100); do
		state=$(bench_lock_holders "a.application_name = '$app'")
		[ -n "$state" ] && return 0
		kill -0 "$BENCH_DB_LOCK_PID" 2>/dev/null || break
		sleep 0.1
	done
	exec {BENCH_DB_LOCK_FD}>&-
	BENCH_DB_LOCK_FD=
	state=$(bench_lock_holders true)
	echo "$(basename "$0"): another benchmark is running in $BENCH_DB" \
		"(${state:-could not take its lock}); wait for it or set BENCH_DB" \
		"to another name" >&2
	exit 1
}

# bench_db_unlock: release the lock and wait until it is gone.
bench_db_unlock() {
	local state
	[ -n "${BENCH_DB_LOCK_FD:-}" ] || return 0
	exec {BENCH_DB_LOCK_FD}>&-
	BENCH_DB_LOCK_FD=
	wait "$BENCH_DB_LOCK_PID" 2>/dev/null || true
	for _ in $(seq 1 100); do
		state=$(bench_lock_holders "a.application_name = '$BENCH_DB_LOCK_APP'")
		[ -z "$state" ] && return 0
		sleep 0.1
	done
}

# bench_lock_holders <condition>: application names of the lock holders.
bench_lock_holders() {
	psql -X -q -tA -c "SELECT string_agg(a.application_name, ', ')
		FROM pg_locks l JOIN pg_stat_activity a USING (pid)
		WHERE l.locktype = 'advisory' AND l.granted
			AND l.database = (SELECT oid FROM pg_database
							  WHERE datname = current_database())
			AND (l.classid, l.objid, l.objsubid) = ($BENCH_DB_LOCK_KEY, 2)
			AND $1" 2>/dev/null || true
}

# bench_db_drop: drop BENCH_DB if it carries the mark.
bench_db_drop() {
	scratch_db_drop "$BENCH_DB" "$BENCH_DB_MARK" --no-force ||
		[ $? -eq "$SCRATCH_DB_FOREIGN" ]
}
