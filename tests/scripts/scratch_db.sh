# shellcheck shell=bash
# Sourced by the scripts that need a database of their own (run-one.sh,
# upgrade-check.sh, bench-smoke.sh, tests/performance/bench_db.sh); functions
# only.
#
# A scratch database carries a comment, its mark, that says whose it is.  It
# is created with the mark, dropped only when it carries the mark, and a
# database of that name without the mark is never touched: the caller stops
# instead, so that a name that happens to be a database with real data loses
# nothing.
#
# Environment: PGHOST/PGPORT/PGUSER for the server; SCRATCH_ADMIN_DB, the
# database the commands run from (default BENCH_ADMIN_DB, then postgres);
# SCRATCH_DB_OPTIONS, read by scratch_db_create only: text that follows
# CREATE DATABASE <name> as it is, such as "TEMPLATE template0" (default
# none).
#
# Return codes: 0 on success; 4 (SCRATCH_DB_FOREIGN) when the database exists
# without the mark, with nothing printed, so that the caller says what it
# refuses in its own words; otherwise psql's own status (1 to 3), after psql
# has printed its error.  psql never returns 4.

SCRATCH_DB_FOREIGN=4

# scratch_db_psql <name> <mark> [psql arguments]: psql in the admin database,
# with :"db" and :'mark' set; the commands come from the standard input.
scratch_db_psql() {
	local db=$1 mark=$2
	shift 2
	psql -X -q -tA -v ON_ERROR_STOP=1 \
		-d "${SCRATCH_ADMIN_DB:-${BENCH_ADMIN_DB:-postgres}}" \
		-v db="$db" -v mark="$mark" "$@"
}

# scratch_db_state <name> <mark>: prints "t" when the database exists with
# the mark, "f" when it exists without it, nothing when it does not exist.
scratch_db_state() {
	scratch_db_psql "$1" "$2" <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
}

# scratch_db_exists <name>: 0 when a database of that name exists, with a
# mark or without, 1 when it does not.
scratch_db_exists() {
	local state
	state=$(scratch_db_state "$1" '') || return
	[ -n "$state" ]
}

# scratch_db_refuse_foreign <name> <mark>: 4 when the database exists
# without the mark, 0 when it carries the mark or does not exist.
scratch_db_refuse_foreign() {
	local state
	state=$(scratch_db_state "$1" "$2") || return
	[ "$state" != f ] || return "$SCRATCH_DB_FOREIGN"
}

# scratch_db_create <name> <mark> [<setting>=<value> ...]: create the
# database with the mark, CREATE DATABASE followed by SCRATCH_DB_OPTIONS, and
# ALTER DATABASE ... SET each setting, in one psql session.  The database
# must not exist: check with scratch_db_exists, or drop it first.
scratch_db_create() {
	local db=$1 mark=$2 setting sql i=0
	local -a vars=()
	shift 2
	sql=$'CREATE DATABASE :"db" :options;\nCOMMENT ON DATABASE :"db" IS :\'mark\';\n'
	for setting in "$@"; do
		if [[ "$setting" != ?*=* ]]; then
			echo "scratch_db_create: '$setting' is not <setting>=<value>" >&2
			return 2
		fi
		i=$((i + 1))
		vars+=(-v "name$i=${setting%%=*}" -v "value$i=${setting#*=}")
		sql+="ALTER DATABASE :\"db\" SET :\"name$i\" TO :'value$i';"$'\n'
	done
	scratch_db_psql "$db" "$mark" -v options="${SCRATCH_DB_OPTIONS:-}" \
		"${vars[@]}" <<< "$sql"
}

# scratch_db_drop <name> <mark> [--no-force]: drop the database when it
# carries the mark, WITH (FORCE) unless --no-force is given (then the drop
# fails while a session is connected to it); nothing when it does not exist;
# 4, and nothing dropped, when it exists without the mark.
scratch_db_drop() {
	local state drop='DROP DATABASE :"db" WITH (FORCE)'
	[ "${3:-}" != --no-force ] || drop='DROP DATABASE :"db"'
	state=$(scratch_db_state "$1" "$2") || return
	case $state in
		t) scratch_db_psql "$1" "$2" <<< "$drop" ;;
		f) return "$SCRATCH_DB_FOREIGN" ;;
	esac
}
