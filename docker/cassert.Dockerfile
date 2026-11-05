# PostgreSQL 18 built from source with assertions (--enable-cassert), and
# the extension built against it.  The container starts a server with the
# library preloaded and runs the regression and isolation suites:
#
#   docker build -f docker/cassert.Dockerfile -t leapfrog-cassert .
#   docker run --rm leapfrog-cassert
#
# Build arguments:
#   PG_BRANCH   PostgreSQL git branch or tag (REL_18_STABLE)
#   UID, GID    ids of the user running the server and the tests (1000),
#               the host user's when the sources are mounted over the copy

FROM debian:bookworm-slim
ARG PG_BRANCH=REL_18_STABLE

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git gcc make bison flex perl libipc-run-perl \
        libreadline-dev zlib1g-dev pkg-config libicu-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${PG_BRANCH} \
        https://github.com/postgres/postgres.git /usr/src/postgresql \
    && cd /usr/src/postgresql \
    && ./configure --prefix=/usr/local/pgsql --enable-cassert --enable-debug \
        CFLAGS='-O1 -fno-omit-frame-pointer' \
    && make -j"$(nproc)" -s \
    && make -s install \
    && make -s -C src/test/isolation install \
    && cd / && rm -rf /usr/src/postgresql

ENV PATH=/usr/local/pgsql/bin:$PATH \
    PGDATA=/var/lib/postgresql/data \
    PGHOST=/tmp \
    PGUSER=postgres

ARG UID=1000
ARG GID=1000
RUN groupadd -o -g "${GID}" postgres \
    && useradd -o -m -u "${UID}" -g "${GID}" postgres \
    && mkdir -p /var/lib/postgresql /src/leapfrog \
    && chown -R postgres /var/lib/postgresql /src/leapfrog

WORKDIR /src/leapfrog
COPY --chown=postgres Makefile leapfrog.control leapfrog--*.sql ./
COPY --chown=postgres src ./src
RUN make WERROR=1 && make install

COPY --chown=postgres tests ./tests

USER postgres
ENTRYPOINT ["bash", "tests/scripts/run-cassert.sh"]
