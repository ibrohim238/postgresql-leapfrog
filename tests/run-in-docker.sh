#!/usr/bin/env bash
# Build the images, start PostgreSQL 18 with leapfrog preloaded and run the
# regression and isolation suites inside the test container.
#
# Everything runs in a Compose project of its own, leapfrog-test-<pid>-<random>
# (or COMPOSE_TEST_PROJECT), not in the default project leapfrog: the
# containers and the pgdata volume removed afterwards are this run's own, so
# a server started with "docker compose up", or kept by an earlier run with
# --keep, keeps running with its data.  A COMPOSE_TEST_PROJECT that already
# has containers or volumes is refused, since the run removes them at the
# end.  Needs Docker Compose 2.24.4 or later (!override in the overlay).
#
#   bash tests/run-in-docker.sh            run the tests
#   bash tests/run-in-docker.sh --keep     leave the server running afterwards
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

mkdir -p results tests/isolation/results

compose up -d --build --wait postgres
status=0
compose --profile test run --rm --build test || status=$?

if [ "$keep" -eq 1 ]; then
	port=$(compose port postgres 5432 | sed 's/.*://')
	echo "server kept running: 127.0.0.1:$port;" \
		"stop it with: docker compose -p $project down -v"
fi

exit $status
