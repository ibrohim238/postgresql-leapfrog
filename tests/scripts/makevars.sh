# shellcheck shell=bash
# Sourced: make_var, to read Makefile variables.

# make_var <variable>: its words in ./Makefile, one per line
make_var() {
	awk -v var="$1" '
		function take(line) {
			cont = sub(/\\[[:space:]]*$/, "", line)
			printf "%s ", line
		}
		cont { take($0); next }
		$0 ~ "^" var "[[:space:]]*[:+]?=" {
			sub("^" var "[[:space:]]*[:+]?=", "")
			take($0)
		}
	' Makefile | tr -s '[:blank:]' '\n' | sed '/^$/d'
}
