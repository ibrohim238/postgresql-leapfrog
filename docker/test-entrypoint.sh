#!/usr/bin/env bash
# Entrypoint of the test image: run-tests.sh --build in the mounted tree.
set -eu
if [ ! -f /src/leapfrog/tests/scripts/run-tests.sh ]; then
	echo "leapfrog-test: no sources at /src/leapfrog: mount the repository" \
		"(docker run --rm -v \"\$PWD:/src/leapfrog\" leapfrog-test:18)" >&2
	exit 2
fi
cd /src/leapfrog
exec bash tests/scripts/run-tests.sh --build "$@"
