#!/usr/bin/env bash
# Build the images and run the suites in a Compose project of its own.
# Usage: run-in-docker.sh [--keep]   (--keep: leave the server running)
# Environment: PG_MAJOR, COMPOSE_TEST_PROJECT.  See docs/docker.md.
set -euo pipefail

cd "$(dirname "$0")/.."

keep=0
for arg in "$@"; do
	case "$arg" in
		--keep) keep=1 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

version=$(docker compose version --short)
if [ "$(printf '%s\n' 2.24.4 "$version" | sort -V | head -1)" != 2.24.4 ]; then
	echo "run-in-docker.sh: needs Docker Compose 2.24.4 or later," \
		"found $version" >&2
	exit 2
fi

project=${COMPOSE_TEST_PROJECT:-leapfrog-test-$$-$RANDOM}
if [ "$project" = leapfrog ]; then
	echo "run-in-docker.sh: COMPOSE_TEST_PROJECT must not be" \
		"the default project leapfrog" >&2
	exit 2
fi
label=com.docker.compose.project=$project
if [ -n "$(docker ps -aq --filter "label=$label")" ] ||
	[ -n "$(docker volume ls -q --filter "label=$label")" ]; then
	echo "run-in-docker.sh: Compose project $project already exists;" \
		"the run would remove it at the end, choose another name" >&2
	exit 2
fi
compose() {
	docker compose -p "$project" -f compose.yaml -f tests/compose.test.yaml "$@"
}

if [ "$keep" -eq 0 ]; then
	trap 'compose down -v' EXIT
fi

# the test container writes into the mounted tree as this user
LEAPFROG_UID=$(id -u)
LEAPFROG_GID=$(id -g)
export LEAPFROG_UID LEAPFROG_GID

compose up -d --build --wait postgres
status=0
compose --profile test run --rm --build test || status=$?

if [ "$keep" -eq 1 ]; then
	port=$(compose port postgres 5432 | sed 's/.*://')
	echo "server kept running: 127.0.0.1:$port;" \
		"stop it with: docker compose -p $project down -v"
fi

exit $status
