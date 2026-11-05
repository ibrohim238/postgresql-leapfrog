#!/usr/bin/env bash
# Static checks of the tree that neither the compiler nor pgindent make.
#
#   bash tests/scripts/lint.sh          run every check, fail when one fails
#   bash tests/scripts/lint.sh --fix    first fix what can be fixed mechanically:
#                                       trailing whitespace, the final newline,
#                                       CHANGELOG.md lines that are too long
#
# The checks are taken from Citus (ci/banned.h.sh,
# ci/check_gucs_are_alphabetically_sorted.sh, ci/sort_and_group_includes.sh,
# ci/disallow_long_changelog_entries.sh, ci/check_all_ci_scripts_are_run.sh)
# and TimescaleDB (the [f]ixme grep of its code_style workflow).  Each one
# prints its findings and a line with the reason, and the script goes on with
# the next one.  Needs bash, grep, sed, sort and python3 (no modules beyond
# the standard library).
#
# External tools, as in TimescaleDB's code_style and shellcheck workflows:
# the shellcheck, actionlint, yamllint (.yamllint) and codespell
# (.codespellrc) commands.  One that is not installed is skipped with a
# notice; LINT_STRICT=1 makes a missing tool a failure, for CI.
set -euo pipefail

cd "$(dirname "$0")/../.."

fix=0
case "${1:-}" in
	"") ;;
	--fix) fix=1 ;;
	*)
		echo "usage: $0 [--fix]" >&2
		exit 2
		;;
esac

export LC_ALL=C

failed=()

# Print the reason of a failed check.
reason() {
	echo "lint: $*" >&2
}

# The files of the repository: the tracked ones in a git checkout, otherwise
# (a copy without .git, as in a container) every file but the build and test
# output that .gitignore lists.
list_files() {
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git ls-files
		return
	fi
	find . \( -name .git -o -name .claude -o -name .idea -o -name .vscode \
		-o -path ./tests/regress/results -o -path ./tests/isolation/results \
		-o -path ./tests/isolation/output_iso -o -path ./tests/performance/results \
		-o -path ./log -o -path ./tmp_check -o -path ./tmp_check_iso \) -prune -o \
		-type f ! -name '*.o' ! -name '*.so' ! -name '*.so.*' ! -name '*.bc' \
		! -name '*.swp' ! -name regression.diffs ! -name regression.out \
		-print | sed 's#^\./##' | sort
}

# Text files subject to the whitespace rules: expected test output is compared
# byte for byte and keeps what the server prints.
whitespace_files() {
	list_files | grep -v -E '^tests/(.*/)?expected/[^/]*\.out$' |
		while IFS= read -r f; do
			# binary files and empty ones are skipped
			if [ -f "$f" ] && grep -Iq . "$f"; then
				printf '%s\n' "$f"
			fi
		done
}

# (a) C functions without a bound on the buffer they write; after Citus's
# ci/banned.h.sh.  A line with IGNORE-BANNED in a comment is allowed.
check_banned() {
	local hits
	hits=$(grep -n -E '\b(strcpy|strcat|sprintf|vsprintf|strncpy|strncat|gets|alloca)[[:space:]]*\(' \
		src/*.c src/*.h | grep -v IGNORE-BANNED || true)
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits"
		reason "banned functions: they do not bound the buffer they write (strncpy does" \
			"not terminate it); use strlcpy, strlcat, snprintf, psprintf or a StringInfo," \
			"or mark the line IGNORE-BANNED with a reason"
		return 1
	fi
}

# (b) Notes left for later; after TimescaleDB's [f]ixme grep.  The pattern is
# spelt with brackets so that this file does not match itself.
check_notes() {
	local hits
	hits=$(list_files | grep -E '^(src|tests)/' |
		xargs -d '\n' grep -nIw -E 'TO[D]O|FI[X]ME|X[X]X' -- || true)
	if [ -n "$hits" ]; then
		printf '%s\n' "$hits"
		reason "notes left for later in src/ or tests/: finish the work, or move" \
			"the plan into docs/roadmap.md"
		return 1
	fi
}

# (c) Trailing whitespace and the final newline, as .editorconfig asks.
check_whitespace() {
	local f status=0
	while IFS= read -r f; do
		if [ "$fix" = 1 ]; then
			if grep -q -E '[[:space:]]+$' "$f"; then
				sed -i -E 's/[[:space:]]+$//' "$f"
			fi
			if [ -n "$(tail -c 1 "$f")" ]; then
				echo >>"$f"
			fi
		fi
		if grep -n -E '[[:space:]]+$' "$f" | sed "s#^#$f:#" | grep .; then
			status=1
		fi
		if [ -n "$(tail -c 1 "$f")" ]; then
			echo "$f: no newline at the end of the file"
			status=1
		fi
	done < <(whitespace_files)
	if [ "$status" != 0 ]; then
		reason "trailing whitespace or a missing final newline (.editorconfig);" \
			"lint.sh --fix removes it"
	fi
	return "$status"
}

# (d) The include order of the PostgreSQL sources, after Citus's
# ci/sort_and_group_includes.sh: "postgres.h" first, then the system headers,
# then the PostgreSQL ones, then the extension's own (src/*.h); each group
# sorted by byte value.
check_includes() {
	if python3 - src <<-'PY'; then
		import os, re, sys

		src = sys.argv[1]
		own = {f for f in os.listdir(src) if f.endswith(".h")}
		names = ["postgres.h", "system", "PostgreSQL", "own"]
		bad = False
		for name in sorted(os.listdir(src)):
		    if not name.endswith(".c"):
		        continue
		    path = os.path.join(src, name)
		    prev = None
		    first = True
		    with open(path, encoding="utf-8") as f:
		        for lineno, line in enumerate(f, 1):
		            m = re.match(r'\s*#\s*include\s+([<"])([^>"]+)[>"]', line)
		            if not m:
		                continue
		            header = m.group(2)
		            if m.group(1) == '"' and header == "postgres.h":
		                group = 0
		            elif m.group(1) == "<":
		                group = 1
		            elif header in own:
		                group = 3
		            else:
		                group = 2
		            where = f"{path}:{lineno}: {header}"
		            if first and group != 0:
		                print(f'{where}: "postgres.h" must come first')
		                bad = True
		            first = False
		            if prev is not None:
		                if group < prev[0]:
		                    print(f"{where}: a {names[group]} header after "
		                          f"a {names[prev[0]]} one ({prev[1]})")
		                    bad = True
		                elif group == prev[0] and header.encode() < prev[1].encode():
		                    print(f"{where}: not sorted, comes before {prev[1]}")
		                    bad = True
		            prev = (group, header)
		sys.exit(1 if bad else 0)
	PY
		return 0
	fi
	reason "#include order: \"postgres.h\", then <system> headers, then PostgreSQL" \
		"headers, then the extension's own, each group sorted"
	return 1
}

# (e) GUCs defined in alphabetical order, as the README's Settings table lists
# them; after Citus's ci/check_gucs_are_alphabetically_sorted.sh.
check_gucs() {
	local f out status=0
	for f in src/*.c; do
		if ! out=$({ grep -o -E 'DefineCustom[A-Za-z]+Variable\("[^"]+"' "$f" || true; } |
			sed -E 's/^[^"]*"//; s/"$//' | sort -c 2>&1); then
			echo "$f: $out"
			status=1
		fi
	done
	if [ "$status" != 0 ]; then
		reason "GUCs not defined in alphabetical order: keep the DefineCustom*Variable" \
			"calls sorted by name, like the Settings table of the README"
	fi
	return "$status"
}

# (f) CHANGELOG.md lines of at most 100 characters, so that an entry reads in
# a terminal and in a diff; after Citus's ci/disallow_long_changelog_entries.sh.
check_changelog() {
	if python3 - CHANGELOG.md "$fix" <<-'PY'; then
		import sys

		path, fix, limit = sys.argv[1], sys.argv[2] == "1", 100
		with open(path, encoding="utf-8") as f:
		    lines = f.read().split("\n")

		def wrap(line):
		    # break at the last space within the limit; a continuation keeps the
		    # indentation of the text of a list item
		    body = line.lstrip(" ")
		    indent = " " * (len(line) - len(body))
		    cont = indent + ("  " if body.startswith(("- ", "* ")) else "")
		    out = []
		    while len(line) > limit:
		        cut = line.rfind(" ", len(cont) + 1, limit + 1)
		        if cut <= len(cont):
		            break
		        out.append(line[:cut].rstrip())
		        line = cont + line[cut:].lstrip()
		    return out + [line]

		if fix:
		    fixed, fence = [], False
		    for line in lines:
		        if line.lstrip().startswith("```"):
		            fence = not fence
		        if len(line) > limit and not fence and not line.lstrip().startswith("|"):
		            fixed.extend(wrap(line))
		        else:
		            fixed.append(line)
		    if fixed != lines:
		        lines = fixed
		        with open(path, "w", encoding="utf-8") as f:
		            f.write("\n".join(lines))
		bad = False
		for lineno, line in enumerate(lines, 1):
		    if len(line) > limit:
		        print(f"{path}:{lineno}: {len(line)} characters")
		        bad = True
		sys.exit(1 if bad else 0)
	PY
		return 0
	fi
	reason "CHANGELOG.md lines longer than 100 characters: wrap them" \
		"(lint.sh --fix wraps them at a space)"
	return 1
}

# (g) Every script in tests/scripts is run from somewhere: the Makefile, a
# workflow, a Dockerfile or compose file, or another script; after Citus's
# ci/check_all_ci_scripts_are_run.sh.  An orphan is reported, not removed.
check_scripts_run() {
	local script f name pattern status=0
	local -a callers others
	mapfile -t callers < <(list_files | grep -E \
		'^(Makefile|Dockerfile|docker/.*|(.*/)?compose[^/]*\.ya?ml|\.github/workflows/[^/]*\.ya?ml|.*\.sh)$')
	for script in tests/scripts/*.sh; do
		name=$(basename "$script")
		pattern="(^|[^[:alnum:]_.-])${name//./\\.}([^[:alnum:]_-]|$)"
		others=()
		for f in "${callers[@]}"; do
			if [ "$f" != "$script" ] && [ -f "$f" ]; then
				others+=("$f")
			fi
		done
		if ! grep -q -E "$pattern" "${others[@]}"; then
			echo "$script: not referenced from the Makefile, a workflow, a Dockerfile," \
				"a compose file or another script"
			status=1
		fi
	done
	if [ "$status" != 0 ]; then
		reason "a script in tests/scripts that nothing runs: wire it into the" \
			"Makefile or CI, or remove it"
	fi
	return "$status"
}

# A tool that is not installed: a notice, or with LINT_STRICT=1 a failure.
missing_tool() {
	if [ "${LINT_STRICT:-0}" = 1 ]; then
		reason "$1 is not installed (LINT_STRICT=1 needs it)"
		return 1
	fi
	echo "lint: $1 is not installed, skipped" >&2
}

have_tool() {
	command -v "$1" >/dev/null 2>&1
}

# Shell scripts: warnings and errors, not style.  A "shellcheck disable"
# in a script says why next to it.
check_shellcheck() {
	local -a scripts
	have_tool shellcheck || {
		missing_tool shellcheck
		return
	}
	mapfile -t scripts < <(list_files | grep -E '\.sh$')
	if ! shellcheck -S warning -x "${scripts[@]}"; then
		reason "shellcheck found problems in the shell scripts"
		return 1
	fi
}

# GitHub Actions workflows; the shell in their "run:" blocks is checked
# by shellcheck at the same severity as the scripts.
check_actionlint() {
	local -a workflows
	have_tool actionlint || {
		missing_tool actionlint
		return
	}
	mapfile -t workflows < <(list_files | grep -E '^\.github/workflows/[^/]*\.ya?ml$')
	if [ "${#workflows[@]}" = 0 ]; then
		return 0
	fi
	if ! SHELLCHECK_OPTS="-S warning" actionlint "${workflows[@]}"; then
		reason "actionlint found problems in the workflows"
		return 1
	fi
}

check_yamllint() {
	local -a files
	have_tool yamllint || {
		missing_tool yamllint
		return
	}
	mapfile -t files < <(list_files | grep -E '\.ya?ml$')
	if ! yamllint -c .yamllint "${files[@]}"; then
		reason "yamllint found problems in the YAML files (.yamllint)"
		return 1
	fi
}

check_codespell() {
	local -a files
	have_tool codespell || {
		missing_tool codespell
		return
	}
	mapfile -t files < <(list_files | grep -E '^(src|tests|docs)/|^[^/]*\.md$')
	if ! codespell --config .codespellrc "${files[@]}"; then
		reason "misspelt words (codespell): fix them, or add a term codespell does" \
			"not know to ignore-words-list in .codespellrc"
		return 1
	fi
}

# The C code through clang-tidy (.clang-tidy: bugprone-* and the static
# analyzer, less the checks that only flag PostgreSQL idioms), against the
# headers of the server pg_config names.
check_clang_tidy() {
	local tool=${CLANG_TIDY:-clang-tidy} pg_config=${PG_CONFIG:-pg_config}
	local version cppflags out status=0
	have_tool "$tool" || {
		missing_tool "$tool"
		return
	}
	have_tool "$pg_config" || {
		missing_tool "$pg_config (for clang-tidy)"
		return
	}
	version=$(sed -n -E 's/^EXTVERSION[[:space:]]*=[[:space:]]*//p' Makefile)
	cppflags=$("$pg_config" --cppflags)
	# shellcheck disable=SC2086 # pg_config --cppflags is a list of options
	out=$("$tool" --quiet src/*.c -- \
		-I"$("$pg_config" --includedir-server)" -I"$("$pg_config" --includedir)" \
		$cppflags -DLEAPFROG_VERSION="\"$version\"" -std=gnu11 2>&1) || status=$?
	# the progress lines and the count of warnings in PostgreSQL's headers,
	# which are not shown, say nothing
	printf '%s\n' "$out" |
		grep -v -E '^\[[0-9]+/[0-9]+\] Processing file |^[0-9]+ warnings? generated\.$|^$' || true
	if [ "$status" != 0 ]; then
		reason "clang-tidy found problems in src/ (.clang-tidy lists the checks" \
			"left out and why; a false positive gets a NOLINTNEXTLINE with the reason)"
		return 1
	fi
}

run() {
	local name=$1
	shift
	if ! "$@"; then
		failed+=("$name")
	fi
}

if ! command -v python3 >/dev/null 2>&1; then
	reason "python3 is required"
	exit 1
fi

run banned check_banned
run notes check_notes
run whitespace check_whitespace
run includes check_includes
run gucs check_gucs
run changelog check_changelog
run scripts-run check_scripts_run
run shellcheck check_shellcheck
run actionlint check_actionlint
run yamllint check_yamllint
run codespell check_codespell
run clang-tidy check_clang_tidy

if [ "${#failed[@]}" != 0 ]; then
	echo "lint: failed: ${failed[*]}" >&2
	exit 1
fi
echo "lint: all checks passed"
