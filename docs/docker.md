# Docker

Three images and a Compose file. The test scripts they run:
[testing.md](testing.md).

| Image | Built from | Contents |
|---|---|---|
| `leapfrog:<tag>` | `Dockerfile`, target `runtime` | `postgres:$PG_MAJOR` plus the installed extension |
| `leapfrog-test:<tag>` | `Dockerfile`, target `test` | build tools and pg_regress, no sources |
| `leapfrog-cassert`, `leapfrog-san` | `docker/cassert.Dockerfile` | PostgreSQL from git with `--enable-cassert`, optionally sanitizers |

## Dockerfile

| Stage | From | Does |
|---|---|---|
| `tools` | `PG_IMAGE` | `gcc`, `make`, `postgresql-server-dev-$PG_MAJOR`, `libipc-run-perl` |
| `build` | `tools` | copies `Makefile`, the control and SQL files, `src/`; `make clean`, build with `WERROR=1`, install |
| `test` | `tools` | `git` and certificates (for `make pgindent`), a user `leapfrog` with `UID`/`GID`, entrypoint `docker/test-entrypoint.sh` |
| `runtime` | `PG_IMAGE` | the library and SQL files from `build`, `docker/initdb.d`; stock settings, `CMD postgres -c shared_preload_libraries=leapfrog` |

| Argument | Default | Meaning |
|---|---|---|
| `PG_MAJOR` | `18` | PostgreSQL major version |
| `PG_IMAGE` | `postgres:$PG_MAJOR` | base image |
| `UID`, `GID` | `1000` | ids of the test user |

- The test image has no sources: the repository is bind-mounted at
  `/src/leapfrog`. The entrypoint checks the mount (exit 2 with a hint without
  it) and runs `tests/scripts/run-tests.sh --build`: `make clean` (the mounted
  tree may hold objects of another build), build with `WERROR=1`, install,
  then the suites. Without `PGHOST` it starts a server of its own with
  `start-cluster.sh` and stops it at the end.
- The test user has the host user's ids, so what it writes into the tree
  (objects, `tests/regress/results`) belongs to the host user. It owns the two
  directories `make install` writes into, so it installs without root;
  `useradd -o` because the ids may be taken (999 is `postgres`).

```bash
docker build -t leapfrog .
docker build --target test -t leapfrog-test .
docker run --rm -v "$PWD:/src/leapfrog" leapfrog-test   # a server of its own
```

## Compose

`compose.yaml`, project `leapfrog`:

| Service | Image | Does |
|---|---|---|
| `postgres` | runtime | the server with `tests/scripts/temp.conf` on its command line, `shared_buffers=$LEAPFROG_SHARED_BUFFERS` (512MB), volume `pgdata`; healthy once the extension exists |
| `test` (profile `test`) | test | the suites against `postgres`, repository mounted |
| `bench` (profile `bench`) | test | `tests/performance/list_bench.sh` (`SIZE`, `REPEATS`), in its own database |

| Variable | Default | Meaning |
|---|---|---|
| `PG_MAJOR` | `18` | PostgreSQL major version of the images |
| `LEAPFROG_TAG` | `PG_MAJOR` | image tag |
| `LEAPFROG_PORT` | `5433` | host port of the server |
| `LEAPFROG_BIND` | `127.0.0.1` | host address; the password is well known, `0.0.0.0` for every interface |
| `LEAPFROG_UID`, `LEAPFROG_GID` | `1000` | ids of the test user |
| `POSTGRES_PASSWORD` | `leapfrog` | |

```bash
docker compose up -d --build --wait
docker compose --profile test run --rm test
docker compose --profile bench run --rm bench
```

`tests/run-in-docker.sh [--keep]` (`make docker-test`) builds the images,
starts the server and runs the test service in a Compose project of its own,
`leapfrog-test-<pid>-<random>` or `COMPOSE_TEST_PROJECT`, with the overlay
`tests/compose.test.yaml` (a free host port on 127.0.0.1), and removes its
containers and volume at the end unless `--keep`. The default project and its
data are never touched; a `COMPOSE_TEST_PROJECT` that exists, or named
`leapfrog`, is refused. Needs Docker Compose 2.24.4 (`!override`).

`make docker-build PG_MAJOR=18` builds the Compose images with the caller's
ids; `make docker-test` runs `run-in-docker.sh` with them.

## cassert.Dockerfile

| Stage | Does |
|---|---|
| `pg` | PostgreSQL `PG_BRANCH` from git, `--enable-cassert --enable-debug`, `-O1 -fno-omit-frame-pointer`, plus the isolation tester; depends on `PG_BRANCH` and `SANITIZE` only, so `--target pg` can be built once and pushed |
| `leapfrog` | the extension built with `WERROR=1` against it (compiler and flags from `pg_config`), `tests/` copied; entrypoint `tests/scripts/run-cassert.sh` |

| Argument | Default | Meaning |
|---|---|---|
| `PG_BRANCH` | `REL_18_STABLE` | PostgreSQL branch or tag |
| `SANITIZE` | empty | a `-fsanitize=` list, e.g. `address,undefined`: clang, `-fsanitize=$SANITIZE -fno-sanitize-recover=all` for PostgreSQL and the extension; empty: gcc, none |
| `UID`, `GID` | `1000` | ids of the user running the server and the tests |

```bash
docker build -f docker/cassert.Dockerfile -t leapfrog-cassert . && docker run --rm leapfrog-cassert
docker build --build-arg SANITIZE=address,undefined -f docker/cassert.Dockerfile -t leapfrog-san .
docker run --rm leapfrog-san
```

`run-cassert.sh`:

- `ASAN_OPTIONS=abort_on_error=1:detect_leaks=0:quarantine_size_mb=4:log_path=/tmp/asan`,
  `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:log_path=/tmp/ubsan`: one
  report file per process, server and clients; the first error stops it.
  Leak detection is off image-wide too (`ENV ASAN_OPTIONS=detect_leaks=0`):
  the server leaves memory to process exit, and `pg_config`, which PGXS asks
  for its paths, would fail at exit. The quarantine of freed memory is cut
  to 4MB: it counts in the backend's RSS, which `leapfrog_memory` measures.
- Raises the soft stack limit (16 MB, or unlimited) and only then passes
  `-c max_stack_depth=8MB`: instrumented frames are larger, and the server
  refuses a depth the limit cannot hold.
- Starts the server with `start-cluster.sh`, checks `debug_assertions`, runs
  `run-tests.sh`, and fails on `TRAP:` or a crashed backend in the server log,
  or on any `/tmp/asan.*`/`/tmp/ubsan.*` report (printed).
- Under AddressSanitizer the peak RSS check of `leapfrog_memory` (growth below
  32MB) fails: shadow memory and the quarantine count in the backend's RSS.
