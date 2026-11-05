# postgresql-leapfrog: PostgreSQL 18 with the leapfrog extension built in.
#
#   docker build -t leapfrog .                     runtime image
#   docker build --target test -t leapfrog-test .  image with pg_regress
#   docker run --rm -v "$PWD:/src/leapfrog" leapfrog-test
#                                   the suites against a server of its own
#
# The runtime image is self-contained: the sources are copied in and built.
# The test image has the build tools and no sources: the repository is
# bind-mounted at /src/leapfrog (compose.yaml, tests/run-in-docker.sh), and
# its entrypoint builds and installs the extension from there before running
# the suites, as the user UID:GID, so that what it writes into the mounted
# tree (objects, tests/regress/results) belongs to the user on the host.
# Without PGHOST it starts a server of its own (tests/scripts/start-cluster.sh)
# instead of using the Compose one.  The runtime image has the settings of
# tests/scripts/temp.conf in the configuration initdb writes.
#
# Build arguments:
#   PG_MAJOR   PostgreSQL major version (18)
#   PG_IMAGE   base image tag (postgres:$PG_MAJOR)
#   UID, GID   ids of the test user, the host user's (1000)

ARG PG_MAJOR=18
ARG PG_IMAGE=postgres:${PG_MAJOR}

# -- tools stage: the server headers and the build tools ---------------------
FROM ${PG_IMAGE} AS tools
ARG PG_MAJOR

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc make postgresql-server-dev-${PG_MAJOR} libipc-run-perl \
    && rm -rf /var/lib/apt/lists/*

# -- build stage: the extension built from a copy of the sources ------------
FROM tools AS build

WORKDIR /src/leapfrog
COPY Makefile leapfrog.control leapfrog--*.sql ./
COPY src ./src
RUN make clean && make with_llvm=no WERROR=1 && make with_llvm=no install

# -- test stage: build tools, a user with the host's ids, sources mounted ----
FROM tools AS test
ARG PG_MAJOR
ARG UID=1000
ARG GID=1000

# git and certificates for "make pgindent", which fetches the core tools.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# The test user installs the extension itself: it owns the two directories
# "make install" writes into (not their contents).  -o: the ids may be taken
# in the image already (999 is postgres).
RUN groupadd -o -g "${GID}" leapfrog \
    && useradd -o -m -u "${UID}" -g "${GID}" -s /bin/bash leapfrog \
    && chown leapfrog:leapfrog \
        /usr/lib/postgresql/${PG_MAJOR}/lib \
        /usr/share/postgresql/${PG_MAJOR}/extension \
    && git config --system --add safe.directory /src/leapfrog

COPY docker/test-entrypoint.sh /usr/local/bin/leapfrog-test
WORKDIR /src/leapfrog
USER leapfrog
ENTRYPOINT ["leapfrog-test"]

# -- runtime stage: plain postgres image plus the installed extension -------
FROM ${PG_IMAGE} AS runtime
ARG PG_MAJOR
COPY --from=build /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so \
    /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/leapfrog* \
    /usr/share/postgresql/${PG_MAJOR}/extension/
COPY docker/initdb.d /docker-entrypoint-initdb.d

# The settings of the test servers (tests/scripts/temp.conf: deterministic
# plans and output) go into the sample initdb copies, so that a new data
# directory has them without restating them on the command line.
COPY tests/scripts/temp.conf /tmp/leapfrog-temp.conf
RUN { echo; echo '# leapfrog: tests/scripts/temp.conf'; cat /tmp/leapfrog-temp.conf; } \
        >>/usr/share/postgresql/postgresql.conf.sample \
    && rm /tmp/leapfrog-temp.conf

# The planner hook needs the library in every backend.
CMD ["postgres", "-c", "shared_preload_libraries=leapfrog"]
