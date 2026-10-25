# Sourced by the benchmark scripts: the database they run in.
#
# The benchmarks drop and recreate tables with common names (orders), so they
# never run in PGDATABASE.  They run in BENCH_DB (default leapfrog_bench), a
# database of their own: created when missing, with a comment that marks it
# as a benchmark database, and refused when it exists without that mark, so
# that BENCH_DB naming a database with real data stops the run before
# anything is dropped.  The server is reached through PGHOST/PGPORT/PGUSER;
# CREATE DATABASE runs from BENCH_ADMIN_DB (default postgres).
#
# The database is kept after a run (types_bench.sh reuses its table across
# builds); drop it with bench_db_drop or dropdb.
#
# One benchmark at a time per database: two would drop each other's tables,
# and their timings would disturb each other anyway.  A run holds an
# advisory lock in BENCH_DB, taken by a psql session in the background that
# reads its commands from a pipe this shell keeps open; when the script ends,
# however it ends, the pipe closes, that psql exits and the lock goes with
# it.  A second run in the same database is refused; set BENCH_DB to run one
# elsewhere.

BENCH_DB_MARK='leapfrog benchmark scratch database'
BENCH_DB_LOCK_KEY='1818650210, 1'

bench_admin_psql() {
	psql -X -q -tA -v ON_ERROR_STOP=1 -d "${BENCH_ADMIN_DB:-postgres}" \
		-v db="$BENCH_DB" -v mark="$BENCH_DB_MARK" "$@"
}

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
	state=$(bench_admin_psql <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
	)
	case $state in
		t) ;;
		f)
			echo "$(basename "$0"): database $BENCH_DB exists and is not" \
				"a benchmark database (no comment '$BENCH_DB_MARK');" \
				"set BENCH_DB to another name" >&2
			exit 1 ;;
		*)
			bench_admin_psql <<-'SQL'
				CREATE DATABASE :"db";
				COMMENT ON DATABASE :"db" IS :'mark';
			SQL
			;;
	esac
	export PGDATABASE=$BENCH_DB
	psql -X -q -v ON_ERROR_STOP=1 -c "SET client_min_messages = warning" \
		-c "CREATE EXTENSION IF NOT EXISTS leapfrog"
}

# bench_db_lock: take the benchmark lock in PGDATABASE, or exit.
bench_db_lock() {
	# the session is recognised by its application name: a random token,
	# since $$ repeats across containers (a script run as their entrypoint
	# is PID 1 in each), first because PostgreSQL cuts the name at 63 bytes
	local token app state i
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
	for i in $(seq 1 100); do
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

# bench_db_unlock: release the lock and wait until it is gone, so that a
# run started right after this one does not find it still held.
bench_db_unlock() {
	local i state
	[ -n "${BENCH_DB_LOCK_FD:-}" ] || return 0
	exec {BENCH_DB_LOCK_FD}>&-
	BENCH_DB_LOCK_FD=
	wait "$BENCH_DB_LOCK_PID" 2>/dev/null || true
	for i in $(seq 1 100); do
		state=$(bench_lock_holders "a.application_name = '$BENCH_DB_LOCK_APP'")
		[ -z "$state" ] && return 0
		sleep 0.1
	done
}

# bench_lock_holders <condition>: the sessions holding the benchmark lock
# in PGDATABASE that satisfy the condition, by application name.
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
	local state
	state=$(bench_admin_psql <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
	)
	if [ "$state" = t ]; then
		bench_admin_psql <<< 'DROP DATABASE :"db"'
	fi
}
