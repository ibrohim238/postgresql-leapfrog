# PostgreSQL 18 built from source with assertions (--enable-cassert), and
# the extension built against it.  The container starts a server with the
# library preloaded and runs the regression and isolation suites:
#
#   docker build -f docker/cassert.Dockerfile -t leapfrog-cassert .
#   docker run --rm leapfrog-cassert
#
# With sanitizers (clang; the server and the extension both instrumented):
#
#   docker build --build-arg SANITIZE=address,undefined \
#       -f docker/cassert.Dockerfile -t leapfrog-san .
#   docker run --rm leapfrog-san
#
# Two stages: "pg", PostgreSQL alone (it depends on PG_BRANCH and SANITIZE
# only, so it can be built once and pushed to a registry: --target pg), and
# the extension built on top of it.
#
# Build arguments:
#   PG_BRANCH   PostgreSQL git branch or tag (REL_18_STABLE)
#   SANITIZE    empty (default: gcc, no sanitizer), or a -fsanitize= list
#               such as address,undefined: clang, -fsanitize=$SANITIZE
#               -fno-omit-frame-pointer -fno-sanitize-recover=all, for
#               PostgreSQL and the extension; tests/scripts/run-cassert.sh
#               fails on any report (ASAN_OPTIONS, UBSAN_OPTIONS there;
#               leak detection is off)
#   UID, GID    ids of the user running the server and the tests (1000),
#               the host user's when the sources are mounted over the copy

# -- pg stage: PostgreSQL from git, with assertions -------------------------
FROM debian:bookworm-slim AS pg
ARG PG_BRANCH=REL_18_STABLE
ARG SANITIZE=

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git gcc make bison flex perl libipc-run-perl \
        libreadline-dev zlib1g-dev pkg-config libicu-dev \
        ${SANITIZE:+clang llvm libclang-rt-dev} \
    && rm -rf /var/lib/apt/lists/*

# Under AddressSanitizer every instrumented program, pg_config included,
# fails at exit on memory it never freed; PGXS asks pg_config for its paths,
# so leak detection is off image-wide (run-cassert.sh keeps it off).
ENV ASAN_OPTIONS=detect_leaks=0

RUN git clone --depth 1 --branch ${PG_BRANCH} \
        https://github.com/postgres/postgres.git /usr/src/postgresql \
    && cd /usr/src/postgresql \
    && cflags='-O1 -fno-omit-frame-pointer' cc=gcc ldflags= \
    && if [ -n "${SANITIZE}" ]; then \
        cc=clang; \
        cflags="$cflags -fsanitize=${SANITIZE} -fno-sanitize-recover=all"; \
        ldflags="-fsanitize=${SANITIZE}"; \
    fi \
    && ./configure --prefix=/usr/local/pgsql --enable-cassert --enable-debug \
        CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags" \
    && make -j"$(nproc)" -s \
    && make -s install \
    && make -s -C src/test/isolation install \
    && cd / && rm -rf /usr/src/postgresql

ENV PATH=/usr/local/pgsql/bin:$PATH \
    PGDATA=/var/lib/postgresql/data \
    PGHOST=/tmp \
    PGUSER=postgres

# -- the extension, built against it ----------------------------------------
FROM pg AS leapfrog
ARG UID=1000
ARG GID=1000

RUN groupadd -o -g "${GID}" postgres \
    && useradd -o -m -u "${UID}" -g "${GID}" postgres \
    && mkdir -p /var/lib/postgresql /src/leapfrog \
    && chown -R postgres /var/lib/postgresql /src/leapfrog

WORKDIR /src/leapfrog
COPY --chown=postgres Makefile leapfrog.control leapfrog--*.sql ./
COPY --chown=postgres src ./src
# pg_config gives the compiler and the flags PostgreSQL was built with, the
# sanitizer ones included.
RUN make clean && make WERROR=1 && make install

COPY --chown=postgres tests ./tests

USER postgres
ENTRYPOINT ["bash", "tests/scripts/run-cassert.sh"]
