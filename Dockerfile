# Build args are lowercase_with_underscores. The Dockerfile, the Makefile and
# .github/workflows/build.yml must agree on these names.
ARG debian_version=bookworm
ARG postgres_major_version=17
ARG rdkit_version=2026_03_6

# Resolved by scripts/resolve_matrix.py. The default reconstructs the moving
# major tag so that a bare `docker build .` still works.
ARG postgres_base_image=docker.io/postgres:${postgres_major_version}-${debian_version}
ARG postgres_point_version=
ARG postgres_base_digest=

# The PostgreSQL-independent RDKit compile (Dockerfile.rdkit-core) whose
# source tree, build tree and CMake toolchain the builder reuses instead of
# cloning and compiling RDKit itself. The default is the local tag `make core`
# produces, so a bare `docker build .` needs `make core` first and never pulls
# another repository's core image. The workflow passes the GHCR tag it just
# pushed.
ARG rdkit_core_image=rdkit-core:${rdkit_version}-${debian_version}

# Label inputs only, produced by the label-values-export stage. Nothing in the
# build reads boost_version to select a package; the Boost family is chosen by
# scripts/install_boost.sh from RDKit's declared floor.
ARG rdkit_pickle_version=
ARG rdkit_cartridge_version=
ARG boost_version=
ARG vcs_ref=

# source_dir, build_dir, install_dir and cmake_install_dir must stay identical
# to Dockerfile.rdkit-core's defaults of the same names: CMake caches absolute
# paths, and any difference invalidates the whole reused build tree.
ARG source_dir=/tmp/rdkit
ARG build_dir=/tmp/rdkit-build
ARG install_dir=/opt/rdkit
ARG cmake_install_dir=/opt/cmake
ARG num_build_cores=4

# Where the core image exports its finished build tree. It is copied into
# ${build_dir} below, which is what keeps CMake's cached paths valid. Must
# match Dockerfile.rdkit-core's build_export_dir default.
ARG build_export_dir=/tmp/rdkit-build-export
ARG DEBIAN_FRONTEND=noninteractive


FROM ${rdkit_core_image} AS rdkit-core-provider

################################################################################
# Building the RDKit postgres cartridge
################################################################################
FROM ${postgres_base_image} AS builder
ARG postgres_major_version
ARG rdkit_version
ARG source_dir
ARG build_dir
ARG build_export_dir
ARG install_dir
ARG cmake_install_dir
ARG num_build_cores
ARG debian_version
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
        postgresql-server-dev-${postgres_major_version}=$(postgres -V | awk '{print $3}')\* \
        libpq5=$(postgres -V | awk '{print $3}')\* \
        libpq-dev=$(postgres -V | awk '{print $3}')\* \
        zlib1g-dev \
        libbz2-dev

# Reuse the core image's cloned source, compiled (RDK_BUILD_PGSQL=OFF) build
# tree and CMake toolchain. The build tree is copied as a normal layer, not
# mounted as a cache: a cache mount on ${build_dir} in a later RUN would
# silently shadow what this COPY wrote. The tree is owned by postgres because
# the configure and make steps below run as that user. cmake is put on PATH
# rather than symlinked; nothing writes into it.
COPY --from=rdkit-core-provider --chown=postgres:postgres ${source_dir} ${source_dir}
COPY --from=rdkit-core-provider --chown=postgres:postgres ${build_export_dir} ${build_dir}
COPY --from=rdkit-core-provider ${cmake_install_dir} ${cmake_install_dir}
ENV PATH=${cmake_install_dir}/bin:$PATH

# Boost's headers alone are not enough to link; the .so files have to be
# installed here too. Same suite and the same floor-driven choice as the core
# image, so the family is byte-compatible with the tree being reused.
COPY scripts/install_boost.sh /usr/local/bin/install_boost.sh
RUN install_boost.sh ${source_dir} > /tmp/boost-version.txt \
    && cat /tmp/boost-version.txt \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/rdkit_labels.sh /usr/local/bin/rdkit_labels.sh
RUN rdkit_labels.sh ${source_dir} > /tmp/rdkit-labels.txt && cat /tmp/rdkit-labels.txt

# make install (run as postgres, below) writes here; /opt is root:root 0755
# in the base image, so postgres cannot mkdir under it without this.
RUN mkdir -p ${install_dir} && chown postgres:postgres ${install_dir}

USER postgres

# The flag list must match Dockerfile.rdkit-core's except for RDK_BUILD_PGSQL
# and the PostgreSQL_* variables, so that this reconfigure only turns the
# cartridge on against the already-built tree and compiles just its sources.
#
# RDK_BUILD_CHEMDRAW_SUPPORT=OFF: new in 2025_09_2 and ON by default upstream,
# but RDKit's FileParsers target includes <ChemDraw/chemdraw.h> without having
# External/ on its include path (an upstream build-system bug, acknowledged in
# External/ChemDraw/CMakeLists.txt). OFF is the configuration older releases
# had, and drops an unpinned third-party tarball fetch at configure time.
# CDXML parsing still works through the legacy boost property_tree parser.
#
# CMAKE_CXX_FLAGS=-I${source_dir}/External: Code/Bench/inchi.cpp (built by
# RDK_BUILD_CPP_TESTS=ON) includes <INCHI-API/inchi.h> assuming External/ is
# on the include path, which upstream only arranges under feature flags this
# build does not enable. This supplies that path without patching source.
RUN cmake \
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
    -D RDK_BUILD_CHEMDRAW_SUPPORT=OFF \
    -D RDK_INSTALL_COMIC_FONTS=OFF \
    -D RDK_USE_URF=OFF \
    -D RDK_BUILD_PGSQL=ON \
    -D RDK_PGSQL_STATIC=ON \
    -D PostgreSQL_CONFIG=pg_config \
    -D PostgreSQL_INCLUDE_DIR=`pg_config --includedir` \
    -D PostgreSQL_TYPE_INCLUDE_DIR=`pg_config --includedir-server` \
    -D PostgreSQL_LIBRARY_DIR=`pg_config --libdir` \
    -D RDK_INSTALL_INTREE=OFF \
    -D CMAKE_INSTALL_PREFIX=${install_dir} \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_CXX_FLAGS=-I${source_dir}/External \
    -S ${source_dir} \
    -B ${build_dir}

WORKDIR ${build_dir}
# -j on the command line rather than through a MAKEFLAGS ARG: a global ARG
# default cannot see a later stage's ARG, so `MAKEFLAGS='-j${num_build_cores}'`
# reaches make as a literal, which it parses as an unlimited `-j`. The
# command-line form also gives nested make invocations a shared jobserver.
RUN make -j${num_build_cores}
RUN make -j${num_build_cores} install

# pgsql_install.sh copies into /usr/share/postgresql/.../extension and
# /usr/lib/postgresql/.../lib, both root:root 0755 in the base image.
USER root
RUN /bin/bash ./Code/PgSQL/rdkit/pgsql_install.sh

COPY scripts/runtime_packages.sh /usr/local/bin/runtime_packages.sh
RUN runtime_packages.sh \
        /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so \
        /tmp/runtime-packages.txt
USER postgres


################################################################################
# Exports the source-derived label values so the caller can pass them back in as
# build args. LABEL cannot read a file, and these values are only knowable after
# the source is cloned and Boost is installed.
#   docker build --target label-values-export --output type=local,dest=DIR .
################################################################################
FROM builder AS label-values
USER root
RUN mkdir -p /out \
    && cat /tmp/rdkit-labels.txt > /out/labels.env \
    && echo "boost_version=$(cat /tmp/boost-version.txt)" >> /out/labels.env \
    && cat /out/labels.env

FROM scratch AS label-values-export
COPY --from=label-values /out/labels.env /labels.env


################################################################################
# Testing that the build was successful by running the test suite
################################################################################
FROM builder AS test-build
ARG source_dir
ARG build_dir
ARG num_build_cores
ARG rdkit_version
ARG postgres_major_version
ARG debian_version

USER postgres

# The full RDKit C++ test suite, run here because this stage still has the
# builder's toolchain. ctest runs from the build tree, where
# CTestTestfile.cmake lives; LD_LIBRARY_PATH points at the not-yet-installed
# .so files and RDBASE at the source checkout where the tests find their data.
#
# -E testRascalMCES: RDKit registers this Catch2 binary as one CTest test, so
# its single failing case cannot be excluded on its own. That case is a
# hardcoded wall-clock benchmark threshold, flaky on a shared runner, not a
# correctness check. Revisit if RDKit ever makes the benchmark opt-in.
#
# --no-tests=error: without it, a filter that matches nothing (a typo, a
# renamed test) silently exits 0 having run zero tests.
WORKDIR ${build_dir}
RUN initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${source_dir}" LD_LIBRARY_PATH="${build_dir}/lib" ctest --no-tests=error -j${num_build_cores} --output-on-failure -E testRascalMCES


################################################################################
# The minimal runtime: copy the cartridge in, install exactly the shared
# libraries it links (list derived in the builder), and add a script to enable
# the extension in the folder the postgres container auto-executes scripts from.
################################################################################
FROM ${postgres_base_image} AS runtime
ARG postgres_major_version
ARG DEBIAN_FRONTEND

COPY --from=builder /usr/share/postgresql/${postgres_major_version}/extension/*rdkit* /usr/share/postgresql/${postgres_major_version}/extension/
COPY --from=builder /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so
COPY --from=builder /tmp/runtime-packages.txt /tmp/runtime-packages.txt
COPY ./enable_extension.sql /docker-entrypoint-initdb.d/

# test -s guards against an empty runtime-packages.txt: xargs exits 0 on empty
# input, which would let a broken package list produce a green build of an
# image missing its dependencies.
RUN apt-get update \
    && test -s /tmp/runtime-packages.txt \
    && xargs -a /tmp/runtime-packages.txt apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt

ARG debian_version
ARG postgres_point_version
ARG postgres_base_digest
ARG rdkit_version
ARG rdkit_pickle_version
ARG rdkit_cartridge_version
ARG boost_version
ARG vcs_ref

LABEL org.opencontainers.image.source=https://github.com/radusuciu/docker-postgres-rdkit
LABEL org.opencontainers.image.revision=${vcs_ref}
LABEL org.rdkit.version=${rdkit_version}
LABEL org.rdkit.pickle-version=${rdkit_pickle_version}
LABEL org.rdkit.cartridge-version=${rdkit_cartridge_version}
LABEL org.postgresql.version=${postgres_point_version}
LABEL org.postgresql.base-digest=${postgres_base_digest}
LABEL org.boost.version=${boost_version}
LABEL org.debian.suite=${debian_version}


################################################################################
# Verifies that the runtime image's derived package set is sufficient to load
# and exercise the cartridge inside a real postgres server.
################################################################################
FROM runtime AS test-runtime
ARG source_dir
ARG build_dir
ARG cmake_install_dir
ARG num_build_cores
ARG rdkit_version
ARG postgres_major_version
ARG debian_version

USER postgres
# A different lineage from builder (FROM runtime), so the trees are copied in.
COPY --from=builder --chown=postgres ${source_dir} ${source_dir}
COPY --from=builder --chown=postgres ${build_dir} ${build_dir}
COPY --from=builder ${cmake_install_dir} ${cmake_install_dir}
ENV PATH=${cmake_install_dir}/bin:$PATH

# Only testPgSQL runs here. RDKit's general C++ test binaries link Boost
# components dynamically that rdkit.so itself never needs (RDK_PGSQL_STATIC=ON),
# so they fail to load in the minimal runtime image by design. testPgSQL starts
# a real server, LOADs rdkit.so and exercises the cartridge, which is exactly
# what the derived package list has to support. scripts/smoke_test.sh adds
# functional checks against the built image on top of this.
#
# The captured ctest exit status is what fails the RUN; pg_ctl stop still runs
# so a postmaster is not orphaned. --no-tests=error keeps a filter that
# matches nothing from passing silently.
WORKDIR ${build_dir}
RUN initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${source_dir}" LD_LIBRARY_PATH="${build_dir}/lib" ctest --no-tests=error -R '^testPgSQL$' --output-on-failure; \
    status=$?; \
    pg_ctl -D /tmp/pgdata stop; \
    exit $status
