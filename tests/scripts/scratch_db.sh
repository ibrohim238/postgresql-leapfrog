# shellcheck shell=bash
# Sourced: scratch databases marked by a comment; an unmarked one is never touched.
# Environment: SCRATCH_ADMIN_DB (default BENCH_ADMIN_DB, then postgres),
# SCRATCH_DB_OPTIONS.  See docs/testing.md.

SCRATCH_DB_FOREIGN=4

# scratch_db_psql <name> <mark> [psql arguments]: psql with :"db" and :'mark'
scratch_db_psql() {
	local db=$1 mark=$2
	shift 2
	psql -X -q -tA -v ON_ERROR_STOP=1 \
		-d "${SCRATCH_ADMIN_DB:-${BENCH_ADMIN_DB:-postgres}}" \
		-v db="$db" -v mark="$mark" "$@"
}

# scratch_db_state <name> <mark>: t marked, f unmarked, nothing missing
scratch_db_state() {
	scratch_db_psql "$1" "$2" <<-'SQL'
		SELECT shobj_description(oid, 'pg_database') IS NOT DISTINCT FROM :'mark'
		FROM pg_database WHERE datname = :'db'
	SQL
}

# scratch_db_exists <name>
scratch_db_exists() {
	local state
	state=$(scratch_db_state "$1" '') || return
	[ -n "$state" ]
}

# scratch_db_refuse_foreign <name> <mark>: 4 when it exists unmarked
scratch_db_refuse_foreign() {
	local state
	state=$(scratch_db_state "$1" "$2") || return
	[ "$state" != f ] || return "$SCRATCH_DB_FOREIGN"
}

# scratch_db_create <name> <mark> [<setting>=<value> ...]: must not exist
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

# scratch_db_drop <name> <mark> [--no-force]: 4 when it exists unmarked
scratch_db_drop() {
	local state drop='DROP DATABASE :"db" WITH (FORCE)'
	[ "${3:-}" != --no-force ] || drop='DROP DATABASE :"db"'
	state=$(scratch_db_state "$1" "$2") || return
	case $state in
		t) scratch_db_psql "$1" "$2" <<< "$drop" ;;
		f) return "$SCRATCH_DB_FOREIGN" ;;
	esac
}
