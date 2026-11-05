#!/usr/bin/env bash
# Entry point of docker/cassert.Dockerfile: start an assert-enabled server
# with the library preloaded (tests/scripts/start-cluster.sh), run the
# regression and isolation suites, and fail if the server log has an
# assertion failure or a crashed backend, or if a sanitizer (the image built
# with SANITIZE=...) reported anything.
set -euo pipefail

cd "$(dirname "$0")/../.."

# Sanitizer reports go to /tmp/asan.<pid> and /tmp/ubsan.<pid>, one file per
# process, server and clients alike; the first error stops the process.
# Leak detection is off: the server leaves allocations to process exit.
export ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:quarantine_size_mb=4:log_path=/tmp/asan
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:log_path=/tmp/ubsan
rm -f /tmp/asan.* /tmp/ubsan.*

# Instrumented frames are larger; max_stack_depth must stay below the stack
# limit, so raise the soft limit first where the hard one allows it, and ask
# for the larger depth only then: the server refuses a depth the limit cannot
# hold.
stack_opts=()
if ulimit -s 16384 2>/dev/null || ulimit -s unlimited 2>/dev/null; then
	stack_opts=(-c max_stack_depth=8MB)
else
	echo "run-cassert: the stack limit stays at $(ulimit -s) kB; max_stack_depth not raised" >&2
fi

export PGLOG=/tmp/server.log
bash tests/scripts/start-cluster.sh "${stack_opts[@]}"

if [ "$(psql -tAc 'SHOW debug_assertions')" != on ]; then
	echo "the server is not built with --enable-cassert" >&2
	exit 1
fi

status=0
bash tests/scripts/run-tests.sh || status=1

pg_ctl -w stop >/dev/null || status=1

if grep -E 'TRAP:|terminated by signal|server process .* was terminated' "$PGLOG"; then
	echo "assertion failure or crashed backend in the server log" >&2
	status=1
fi

shopt -s nullglob
reports=(/tmp/asan.* /tmp/ubsan.*)
if [ ${#reports[@]} -gt 0 ]; then
	for f in "${reports[@]}"; do
		echo "== $f"
		cat "$f"
	done
	echo "sanitizer reports: ${#reports[@]} file(s)" >&2
	status=1
fi

exit $status
