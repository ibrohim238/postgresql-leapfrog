# postgresql-leapfrog: PostgreSQL 18 with the leapfrog extension built in.
#
#   docker build -t leapfrog .                     runtime image
#   docker build --target test -t leapfrog-test .  image with pg_regress
#
# Build arguments:
#   PG_MAJOR   PostgreSQL major version (18)
#   PG_IMAGE   base image tag (postgres:18)

ARG PG_IMAGE=postgres:18

# -- build stage -------------------------------------------------------------
FROM ${PG_IMAGE} AS build
ARG PG_MAJOR=18

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        gcc make postgresql-server-dev-${PG_MAJOR} libipc-run-perl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/leapfrog
COPY Makefile leapfrog.control leapfrog--*.sql ./
COPY src ./src
RUN make with_llvm=no WERROR=1 && make with_llvm=no install

# -- test stage: build tools kept, sources and tests present ----------------
FROM build AS test
COPY sql ./sql
COPY expected ./expected
COPY tests ./tests
ENTRYPOINT ["bash", "tests/scripts/run-tests.sh"]

# -- runtime stage: plain postgres image plus the installed extension -------
FROM ${PG_IMAGE} AS runtime
ARG PG_MAJOR=18
COPY --from=build /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so \
    /usr/lib/postgresql/${PG_MAJOR}/lib/leapfrog.so
COPY --from=build /usr/share/postgresql/${PG_MAJOR}/extension/leapfrog* \
    /usr/share/postgresql/${PG_MAJOR}/extension/
COPY docker/initdb.d /docker-entrypoint-initdb.d

# The planner hook needs the library in every backend.
CMD ["postgres", "-c", "shared_preload_libraries=leapfrog"]
