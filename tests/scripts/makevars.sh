# shellcheck shell=bash
# Sourced by the scripts that read the Makefile (check-tests.sh,
# check-version.sh); functions only.

# make_var <variable>: the words of a Makefile variable assigned with "=",
# ":=" or "+=", following backslash continuations, one per line.  Reads
# ./Makefile: the caller runs from the top of the source tree.
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
