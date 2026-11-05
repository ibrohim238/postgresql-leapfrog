# docker build -f docker/cassert.Dockerfile -t leapfrog-cassert . && docker run --rm leapfrog-cassert; see docs/docker.md.

# -- pg ---------------------------------------------------------------------
FROM debian:bookworm-slim AS pg
ARG PG_BRANCH=REL_18_STABLE
ARG SANITIZE=

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git gcc make bison flex perl libipc-run-perl \
        libreadline-dev zlib1g-dev pkg-config libicu-dev \
        ${SANITIZE:+clang llvm libclang-rt-dev} \
    && rm -rf /var/lib/apt/lists/*

# pg_config would fail at exit on its leaks, and PGXS needs it
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

# -- leapfrog ---------------------------------------------------------------
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
# the compiler and flags, sanitizers included, come from pg_config
RUN make clean && make WERROR=1 && make install

COPY --chown=postgres tests ./tests

USER postgres
ENTRYPOINT ["bash", "tests/scripts/run-cassert.sh"]
