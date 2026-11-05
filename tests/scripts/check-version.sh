#!/usr/bin/env bash
# Version consistency ("make check-version"), after TimescaleDB's
# release_sanity.yml, Citus's ci/check_migration_files.sh and pgaudit, where
# the control file is the source of truth.  Checks that:
#
#   - EXTVERSION in the Makefile equals default_version in leapfrog.control;
#   - leapfrog--EXTVERSION.sql exists and is in DATA;
#   - an update script from the newest release tag below EXTVERSION,
#     leapfrog--PREV--EXTVERSION.sql, exists and is in DATA, and EXTVERSION
#     is not older than the newest tag (skipped with a notice without tags,
#     e.g. in a shallow clone);
#   - every leapfrog--*.sql of the tree is in DATA and every file of DATA
#     exists;
#   - tests/regress/expected/leapfrog_setup.out shows EXTVERSION;
#   - CHANGELOG.md has "## [Unreleased]"; when EXTVERSION is newer than the
#     newest tag, either Unreleased has entries or "## [EXTVERSION]" exists;
#     every released section has its link at the bottom, and the
#     "[Unreleased]:" link compares from the newest released section.
#
# With --release (RELEASE=1 through make), the state of a release, checked
# after "git tag -a vX -m 'leapfrog X'" and before pushing the tag:
#
#   - Unreleased has no entries and "## [EXTVERSION] — YYYY-MM-DD" exists;
#   - vEXTVERSION is an annotated tag on HEAD with the message
#     "leapfrog EXTVERSION".
#
# Needs no server; the tag checks need the git history (git fetch --tags).
set -euo pipefail

# shellcheck source=tests/scripts/makevars.sh
. "$(dirname "${BASH_SOURCE[0]}")/makevars.sh"
cd "$(dirname "$0")/../.."

release=
case "${1:-}" in
	--release) release=1 ;;
	"") ;;
	*)
		echo "usage: $0 [--release]" >&2
		exit 2
		;;
esac

errors=0

error() {
	echo "check-version: $*" >&2
	errors=$((errors + 1))
}

notice() {
	echo "check-version: notice: $*" >&2
}

# "a is older than b" for versions like 0.0.5
version_lt() {
	[ "$1" != "$2" ] &&
		[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# -- the Makefile and the control file ---------------------------------------

version=$(make_var EXTVERSION | head -n 1)
if [ -z "$version" ]; then
	echo "check-version: no EXTVERSION in the Makefile" >&2
	exit 1
fi
qversion=${version//./\\.}

control=$(sed -nE "s/^[[:space:]]*default_version[[:space:]]*=[[:space:]]*'([^']*)'.*/\\1/p" leapfrog.control)
[ "$control" = "$version" ] ||
	error "default_version in leapfrog.control is '$control', EXTVERSION in the Makefile is '$version'"

data=$(make_var DATA | sed "s/\\\$(EXTVERSION)/$version/g")

in_data() {
	grep -qxF "$1" <<<"$data"
}

[ -f "leapfrog--$version.sql" ] ||
	error "leapfrog--$version.sql (the install script of EXTVERSION) does not exist"
in_data "leapfrog--$version.sql" ||
	error "leapfrog--$version.sql is not in DATA in the Makefile"

for f in leapfrog--*.sql; do
	[ -e "$f" ] || continue
	in_data "$f" || error "$f is not in DATA in the Makefile; add it, or remove the file"
done
for f in $data; do
	[ -f "$f" ] || error "$f is in DATA but does not exist"
done

# -- the release tags --------------------------------------------------------

tags=
readable=1
if git rev-parse --git-dir >/dev/null 2>&1; then
	tags=$(git tag --list 'v[0-9]*' | sed 's/^v//' | sort -V)
elif [ -e .git ]; then
	# a repository git refuses to read (ownership, a worktree whose main
	# repository is not there) must not look like one without tags
	git rev-parse --git-dir >&2 || true
	error "git cannot read the repository; the tags are not checked"
	readable=
fi

newest=
prev=
if [ -z "$tags" ]; then
	[ -z "$readable" ] || notice "no release tags (a shallow clone? git fetch --tags); the update script and the tag are not checked"
else
	newest=$(tail -n 1 <<<"$tags")
	prev=$(sed -n "/^$qversion\$/q;p" <<<"$tags" | tail -n 1)
	if version_lt "$version" "$newest"; then
		error "EXTVERSION $version is older than the newest release tag v$newest"
	fi
	if [ -n "$prev" ] && ! version_lt "$prev" "$version"; then
		prev=
	fi
	if [ -n "$prev" ]; then
		[ -f "leapfrog--$prev--$version.sql" ] ||
			error "leapfrog--$prev--$version.sql does not exist: an installation of v$prev cannot be updated to $version (an empty file when the SQL objects did not change)"
		in_data "leapfrog--$prev--$version.sql" ||
			error "leapfrog--$prev--$version.sql is not in DATA in the Makefile"
	fi
fi

# -- the expected output of leapfrog_setup -----------------------------------

grep -qE "(^|[^0-9.])$qversion([^0-9.]|\$)" tests/regress/expected/leapfrog_setup.out ||
	error "tests/regress/expected/leapfrog_setup.out does not show $version; run leapfrog_setup and update it"

# -- CHANGELOG.md ------------------------------------------------------------

# The list entries of a section, "## [<name>]" up to the next "## ".
entries() {
	awk -v head="## [$1]" '
		index($0, head) == 1 { inside = 1; next }
		inside && /^## / { exit }
		inside && /^[-*] / { print }
	' CHANGELOG.md
}

has_section() {
	grep -qE "^## \\[$1\\]" CHANGELOG.md
}

unreleased=
if ! grep -qxF '## [Unreleased]' CHANGELOG.md; then
	error "CHANGELOG.md has no '## [Unreleased]' section"
else
	unreleased=$(entries Unreleased)
fi

if [ -n "$newest" ] && version_lt "$newest" "$version" && [ -f "leapfrog--$version.sql" ] &&
	[ -z "$unreleased" ] && ! has_section "$qversion"; then
	error "EXTVERSION $version is newer than the tag v$newest, but CHANGELOG.md has neither entries under Unreleased nor a '## [$version]' section"
fi

# Links: one per released section, and Unreleased compared from the newest.
sections=$(sed -nE 's/^## \[([0-9][^]]*)\].*/\1/p' CHANGELOG.md)
for s in $sections; do
	grep -qE "^\\[${s//./\\.}\\]: " CHANGELOG.md ||
		error "CHANGELOG.md has a '## [$s]' section but no '[$s]: ' link at the bottom"
done
top=$(head -n 1 <<<"$sections")
if [ -n "$top" ] && ! grep -qE "^\\[Unreleased\\]: .*/compare/v${top//./\\.}\\.\\.\\.HEAD\$" CHANGELOG.md; then
	error "the '[Unreleased]: ' link of CHANGELOG.md does not compare v$top...HEAD"
fi

# -- --release ---------------------------------------------------------------

if [ -n "$release" ]; then
	[ -z "$unreleased" ] ||
		error "--release: Unreleased in CHANGELOG.md still has entries; move them into '## [$version] — <date>'"
	grep -qE "^## \\[$qversion\\] — [0-9]{4}-[0-9]{2}-[0-9]{2}\$" CHANGELOG.md ||
		error "--release: CHANGELOG.md has no '## [$version] — YYYY-MM-DD' section"

	if ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null 2>&1; then
		error "--release: no tag v$version (git tag -a v$version -m 'leapfrog $version')"
	else
		type=$(git for-each-ref --format='%(objecttype)' "refs/tags/v$version")
		message=$(git for-each-ref --format='%(contents:subject)' "refs/tags/v$version")
		[ "$type" = tag ] ||
			error "--release: v$version is a lightweight tag; it must be annotated (git tag -a)"
		[ "$type" != tag ] || [ "$message" = "leapfrog $version" ] ||
			error "--release: the message of tag v$version is '$message', not 'leapfrog $version'"
		[ "$(git rev-parse "v$version^{commit}")" = "$(git rev-parse HEAD)" ] ||
			error "--release: tag v$version is not on HEAD"
	fi
fi

if [ "$errors" -gt 0 ]; then
	echo "check-version: $errors problem(s)" >&2
	exit 1
fi
echo "check-version: $version${release:+ (release)}${prev:+, updated from v$prev}"
