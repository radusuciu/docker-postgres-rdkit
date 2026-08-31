ARG debian_version=bookworm
ARG PG_IMAGE_TAG=17.2
ARG PG_MAJOR_VERSION=17
ARG RDKIT_VERSION=2024_09_5
ARG RDKIT_REPO=https://github.com/rdkit/rdkit.git
ARG RDKIT_BRANCH_NAME="Release_${RDKIT_VERSION}"
ARG SOURCE_DIR=/tmp/rdkit
ARG BUILD_DIR=/tmp/rdkit-build
ARG INSTALL_DIR=/opt/rdkit
ARG CMAKE_VERSION=3.28.3
ARG CMAKE_INSTALL_DIR=/opt/cmake
ARG NUM_BUILD_CORES=4
ARG DEBIAN_FRONTEND=noninteractive


################################################################################
# Building the RDKit postgres cartridge
################################################################################
FROM docker.io/postgres:${PG_IMAGE_TAG}-${debian_version} AS builder
ARG PG_MAJOR_VERSION
ARG RDKIT_REPO
ARG RDKIT_BRANCH_NAME
ARG SOURCE_DIR
ARG BUILD_DIR
ARG INSTALL_DIR
ARG CMAKE_VERSION
ARG CMAKE_INSTALL_DIR
ARG NUM_BUILD_CORES
ARG DEBIAN_FRONTEND

# pgdg is needed for the -dev packages matching this image's server version.
RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        lsb-release \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt-archive.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg-archive main" >> /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -yq --no-install-recommends --no-install-suggests --allow-downgrades \
        build-essential \
        libeigen3-dev \
        libfreetype6-dev \
        postgresql-server-dev-${PG_MAJOR_VERSION}=$(postgres -V | awk '{print $3}')\* \
        libpq5=$(postgres -V | awk '{print $3}')\* \
        libpq-dev=$(postgres -V | awk '{print $3}')\* \
        zlib1g-dev \
        libbz2-dev

# Clone first: the Boost floor is read from the cloned source (R2).
# Chown here rather than in test-build, where the recursive chown was slow.
RUN git clone --depth=1 --branch=${RDKIT_BRANCH_NAME} ${RDKIT_REPO} ${SOURCE_DIR} \
    && chown -R postgres:postgres ${SOURCE_DIR}

COPY scripts/install_boost.sh /usr/local/bin/install_boost.sh
RUN install_boost.sh ${SOURCE_DIR} > /tmp/boost-version.txt \
    && cat /tmp/boost-version.txt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN <<-EOF
    set -eux
    curl -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh -o /tmp/cmake.sh

    mkdir -p ${CMAKE_INSTALL_DIR}
    sh /tmp/cmake.sh --skip-license --prefix=${CMAKE_INSTALL_DIR}
    ln -s ${CMAKE_INSTALL_DIR}/bin/cmake /usr/local/bin/cmake
    ln -s ${CMAKE_INSTALL_DIR}/bin/ctest /usr/local/bin/ctest
    rm -f /tmp/cmake.sh

    # make install (run as postgres, below) writes here; /opt is root:root 0755
    # in the base image, so postgres cannot mkdir under it without this.
    mkdir -p ${INSTALL_DIR}
    chown postgres:postgres ${INSTALL_DIR}
EOF

USER postgres

# Cache mount persists build artifacts between failed builds.
# If the build crashes, the next attempt resumes from compiled objects.
# uid=999 is the postgres user in official postgres images.
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    cmake \
    -D RDK_BUILD_CAIRO_SUPPORT=OFF \
    -D RDK_BUILD_INCHI_SUPPORT=ON \
    -D RDK_BUILD_AVALON_SUPPORT=ON \
    -D RDK_BUILD_PYTHON_WRAPPERS=OFF \
    -D RDK_BUILD_COORDGEN_SUPPORT=OFF \
    -D RDK_BUILD_MAEPARSER_SUPPORT=OFF \
    -D RDK_BUILD_DESCRIPTORS3D=OFF \
    -D RDK_BUILD_FREESASA_SUPPORT=OFF \
    -D RDK_BUILD_MOLINTERCHANGE_SUPPORT=OFF \
    -D RDK_BUILD_YAEHMOP_SUPPORT=OFF \
    -D RDK_BUILD_STRUCTCHECKER_SUPPORT=OFF \
    -D RDK_INSTALL_COMIC_FONTS=OFF \
    -D RDK_USE_URF=OFF \
    -D RDK_BUILD_PGSQL=ON \
    -D RDK_PGSQL_STATIC=ON \
    -D PostgreSQL_CONFIG=pg_config \
    -D PostgreSQL_INCLUDE_DIR=`pg_config --includedir` \
    -D PostgreSQL_TYPE_INCLUDE_DIR=`pg_config --includedir-server` \
    -D PostgreSQL_LIBRARY_DIR=`pg_config --libdir` \
    -D RDK_INSTALL_INTREE=OFF \
    -D CMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -D CMAKE_BUILD_TYPE=Release \
    -S ${SOURCE_DIR} \
    -B ${BUILD_DIR}

WORKDIR ${BUILD_DIR}
# -j${NUM_BUILD_CORES} on the command line, not via a MAKEFLAGS ARG: Docker
# does not expand ${...} references inside another ARG's default value (only
# inside RUN/etc. instruction text), so `ARG MAKEFLAGS='-j${NUM_BUILD_CORES}'`
# reached the shell as the literal string "-j${NUM_BUILD_CORES}" -- which GNU
# make parses as bare `-j`, i.e. unlimited parallel jobs, not the throttled
# value this Dockerfile is supposed to enforce. Passing -j on the command
# line also gives nested `make` invocations a real shared jobserver, which
# the environment-variable form never provided.
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    make -j${NUM_BUILD_CORES}
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    make -j${NUM_BUILD_CORES} install

# pgsql_install.sh copies into /usr/share/postgresql/.../extension and
# /usr/lib/postgresql/.../lib, both root:root 0755 in the base image --
# postgres cannot write there.
USER root
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    /bin/bash ./Code/PgSQL/rdkit/pgsql_install.sh

COPY scripts/runtime_packages.sh /usr/local/bin/runtime_packages.sh
RUN runtime_packages.sh \
        /usr/lib/postgresql/${PG_MAJOR_VERSION}/lib/rdkit.so \
        /tmp/runtime-packages.txt
USER postgres


################################################################################
# Testing that the build was successful by running the test suite
################################################################################
FROM builder AS test-build
ARG SOURCE_DIR
ARG BUILD_DIR
ARG NUM_BUILD_CORES

USER postgres

# test-build is the full compile-tree regression run: every RDKit C++ test
# binary, dynamically linked against the build tree's libs, exercised here
# because this stage still has the builder's full toolchain (unlike
# runtime). ctest must run from the build tree (CTestTestfile.cmake lives in
# ${BUILD_DIR}, not ${SOURCE_DIR}) and ${BUILD_DIR} is only populated inside
# the cache mount, so this RUN mounts the same cache the builder used to
# compile it. LD_LIBRARY_PATH points at the build tree's lib/ (out-of-tree
# build, RDK_INSTALL_INTREE=OFF) where the not-yet-installed .so files live;
# RDBASE stays the source checkout, which is where RDKit's tests look for
# their data files.
#
# -E testRascalMCES: RDKit registers this Catch2 binary as a single CTest
# test with no per-case CTest entries, so excluding just its failing case
# without a CMakeLists patch isn't possible -- this drops the whole binary,
# including 30 other passing RascalMCES test cases, as a deliberate,
# documented tradeoff. The one failure in it (mces_catch.cpp:803, a Catch2
# "benchmarks" case) is `REQUIRE( timings[i] < ref_time )` -- a hardcoded
# wall-clock threshold, not a correctness check -- and is flaky under the
# throttled/shared-host build this Dockerfile deliberately runs with. Revisit
# if RDKit ever makes that benchmark opt-in.
#
# --no-tests=error: without it, a ctest filter that matches nothing (a typo,
# a renamed test, a future RDKit reshuffle) silently exits 0 having run
# zero tests. This flag is what makes "the suite ran" a checked property
# instead of an assumption.
#
# PRECONDITION this RUN depends on and cannot itself verify: the cache mount
# must actually be warm. Cache-mount contents never enter an image layer, so
# they don't travel with BuildKit's layer cache the way COPY/RUN outputs do.
# Within one build this is safe -- builder populates the mount and this
# stage reads it back in the same invocation. The failure mode is a *layer*-
# cache hit on builder's make/make install steps (e.g. a restored CI cache)
# combined with an empty or pruned `id=rdkit-build` cache mount: make is
# skipped as a cache hit, the mount stays empty, and this RUN fails on a
# missing CTestTestfile.cmake. If that happens, the `--no-tests=error`
# failure here means "the build cache and the cache mount fell out of sync,"
# not "the code broke" -- check whether Task 14's CI cache export/import
# carries the cache mount alongside the layer cache before assuming a
# regression.
WORKDIR ${BUILD_DIR}
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999,sharing=locked \
    initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${SOURCE_DIR}" LD_LIBRARY_PATH="${BUILD_DIR}/lib" ctest --no-tests=error -j${NUM_BUILD_CORES} --output-on-failure -E testRascalMCES


################################################################################
# The minimal runtime -- copy the cartridge in, install exactly the shared
# libraries it links (list derived in the builder, R3), and add a script to
# enable the extension in the folder that the postgres container auto-executes
# scripts from.
################################################################################
FROM docker.io/postgres:${PG_IMAGE_TAG}-${debian_version} AS runtime
ARG PG_MAJOR_VERSION
ARG DEBIAN_FRONTEND

COPY --from=builder /usr/share/postgresql/${PG_MAJOR_VERSION}/extension/*rdkit* /usr/share/postgresql/${PG_MAJOR_VERSION}/extension/
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR_VERSION}/lib/rdkit.so /usr/lib/postgresql/${PG_MAJOR_VERSION}/lib/rdkit.so
COPY --from=builder /tmp/runtime-packages.txt /tmp/runtime-packages.txt
COPY ./enable_extension.sql /docker-entrypoint-initdb.d/

# test -s guards against an empty runtime-packages.txt: `xargs` (even with
# -r) exits 0 on empty input, which would otherwise let a broken/empty
# derived package list produce a green build of an image missing its
# dependencies.
RUN apt-get update \
    && test -s /tmp/runtime-packages.txt \
    && xargs -a /tmp/runtime-packages.txt apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

LABEL org.opencontainers.image.source=https://github.com/radusuciu/docker-postgres-rdkit


################################################################################
# Verifies the runtime image's derived package set (R3) is sufficient to
# load and exercise the RDKit cartridge inside a real postgres server. This
# runs one test, testPgSQL, not the full RDKit suite -- see the comment
# above the RUN below for why.
################################################################################
FROM runtime AS test-runtime
ARG SOURCE_DIR
ARG BUILD_DIR
ARG CMAKE_INSTALL_DIR
ARG NUM_BUILD_CORES

USER postgres
COPY --from=builder --chown=postgres ${SOURCE_DIR} ${SOURCE_DIR}
COPY --from=builder ${CMAKE_INSTALL_DIR} ${CMAKE_INSTALL_DIR}
ENV PATH=${CMAKE_INSTALL_DIR}/bin:$PATH

# Unlike test-build (the full compile-tree regression run), test-runtime's
# job is narrower and different in kind: prove that the *runtime* image's
# derived package set (R3 -- installed from `ldd rdkit.so` alone, not a
# hand-maintained list) is sufficient for what that image actually ships,
# the cartridge. It does NOT run RDKit's general C++ test binaries: those
# are build-tree dev artifacts that link Boost components (e.g.
# libboost_iostreams) dynamically that rdkit.so itself never needs at
# runtime (RDK_PGSQL_STATIC=ON), so they fail to load in the minimal runtime
# image by design -- that failure would test a machine R3 explicitly
# declines to build, not the runtime image. testPgSQL is the one test that
# matters here: it starts a real postgres server, LOADs rdkit.so, and
# exercises the cartridge -- exactly the LOAD-time backstop R3 relies on.
# (Task 10's scripts/smoke_test.sh adds further functional checks on top of
# this against the built image, so narrowing this stage doesn't leave R8
# thin.)
#
# ctest needs ${BUILD_DIR} (cache-mounted, not an image layer) for
# CTestTestfile.cmake and the built .so files. This stage is a different
# lineage from builder (FROM runtime, not FROM builder), but BuildKit cache
# mounts are keyed by id at the daemon level, not by stage, so the same
# id=rdkit-build cache still has the compiled build tree in it.
#
# PRECONDITION this RUN depends on and cannot itself verify: the cache mount
# must actually be warm. Cache-mount contents never enter an image layer, so
# they don't travel with BuildKit's layer cache the way COPY/RUN outputs do
# -- a *layer*-cache hit on builder's make/make install steps (e.g. a
# restored CI cache) combined with an empty or pruned `id=rdkit-build` cache
# mount means make never actually ran to populate ${BUILD_DIR}, and this RUN
# fails on a missing CTestTestfile.cmake. If that happens, treat it as "the
# build cache and the cache mount fell out of sync" -- check Task 14's CI
# cache export/import for the cache mount, not as a code regression.
#
# No trailing "; exit 0": a failure in initdb/pg_ctl/ctest must fail this
# RUN. pg_ctl stop still runs via the trap-like sequencing below so a running
# postmaster doesn't get orphaned, but the captured ctest/setup exit status
# is what the RUN (and therefore the build) actually fails on.
#
# --no-tests=error: without it, `-R '^testPgSQL$'` matching nothing (a
# typo, a rename) would silently exit 0 having run zero tests -- exactly
# the "unfalsifiable" bug this whole stage was just fixed to not have.
# -E testRascalMCES is dropped here, not kept alongside -R: with an exact
# -R filter selecting only testPgSQL, an -E exclusion of a different test
# is redundant dead weight.
WORKDIR ${BUILD_DIR}
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999,sharing=locked \
    initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${SOURCE_DIR}" LD_LIBRARY_PATH="${BUILD_DIR}/lib" ctest --no-tests=error -R '^testPgSQL$' --output-on-failure; \
    status=$?; \
    pg_ctl -D /tmp/pgdata stop; \
    exit $status
