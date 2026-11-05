#!/usr/bin/env bash
# Entry point of docker/cassert.Dockerfile: start a server, run the suites,
# fail on an assertion, a crash or a sanitizer report.  See docs/docker.md.
set -euo pipefail

cd "$(dirname "$0")/../.."

# one report file per process; leaks are off: the server frees at exit
export ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:quarantine_size_mb=4:log_path=/tmp/asan
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:log_path=/tmp/ubsan
rm -f /tmp/asan.* /tmp/ubsan.*

# instrumented frames are larger: raise max_stack_depth only where the
# stack limit can be raised to hold it
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
