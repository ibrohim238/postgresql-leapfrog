#!/usr/bin/env bash
# Entrypoint of the test image: the repository is mounted at /src/leapfrog
# and built there (tests/scripts/run-tests.sh --build).  The script lives in
# the image so that a run without the mount can say what is missing.
set -eu
if [ ! -f /src/leapfrog/tests/scripts/run-tests.sh ]; then
	echo "leapfrog-test: no sources at /src/leapfrog: mount the repository" \
		"(docker run --rm -v \"\$PWD:/src/leapfrog\" leapfrog-test:18)" >&2
	exit 2
fi
cd /src/leapfrog
exec bash tests/scripts/run-tests.sh --build "$@"
