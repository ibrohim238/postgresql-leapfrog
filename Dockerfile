# docker build [--target test] -t leapfrog[-test] .; see docs/docker.md.

ARG PG_MAJOR=18
ARG PG_IMAGE=postgres:${PG_MAJOR}

# -- tools ------------------------------------------------------------------
FROM ${PG_IMAGE} AS tools
ARG PG_MAJOR

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc make postgresql-server-dev-${PG_MAJOR} libipc-run-perl \
    && rm -rf /var/lib/apt/lists/*

# -- build ------------------------------------------------------------------
FROM tools AS build

WORKDIR /src/leapfrog
COPY Makefile leapfrog.control leapfrog--*.sql ./
COPY src ./src
RUN make clean && make with_llvm=no WERROR=1 && make with_llvm=no install

# -- test -------------------------------------------------------------------
FROM tools AS test
ARG PG_MAJOR
ARG UID=1000
ARG GID=1000

# git and certificates for "make pgindent", which fetches the core tools.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# the test user owns the install directories; -o: the ids may be taken
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

# -- runtime ----------------------------------------------------------------
FROM ${PG_IMAGE} AS runtime
ARG PG_MAJOR
COPY --from=build /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so \
    /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/leapfrog* \
    /usr/share/postgresql/${PG_MAJOR}/extension/
COPY docker/initdb.d /docker-entrypoint-initdb.d

COPY tests/scripts/temp.conf /tmp/leapfrog-temp.conf
RUN { echo; echo '# leapfrog: tests/scripts/temp.conf'; cat /tmp/leapfrog-temp.conf; } \
        >>/usr/share/postgresql/postgresql.conf.sample \
    && rm /tmp/leapfrog-temp.conf

# The planner hook needs the library in every backend.
CMD ["postgres", "-c", "shared_preload_libraries=leapfrog"]
