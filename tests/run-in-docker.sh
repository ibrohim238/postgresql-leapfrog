#!/usr/bin/env bash
# Build the images, start PostgreSQL 18 with leapfrog preloaded and run the
# regression and isolation suites inside the test container.
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

mkdir -p results tests/isolation/results

docker compose up -d --build --wait postgres
status=0
docker compose --profile test run --rm --build test || status=$?

if [ "$keep" -eq 0 ]; then
	docker compose down -v
fi

exit $status
