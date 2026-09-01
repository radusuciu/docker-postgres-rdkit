# All build args are lowercase_with_underscores (SPEC R5). The Dockerfile, the
# Makefile and .github/workflows/build.yml must agree on these names.
ARG debian_version=bookworm
ARG postgres_major_version=17
ARG rdkit_version=2026_03_6

# Resolved by scripts/resolve_pg.sh (R4). The default reconstructs the moving
# major tag so that a bare `docker build .` still works.
ARG postgres_base_image=docker.io/postgres:${postgres_major_version}-${debian_version}
ARG postgres_point_version=
ARG postgres_base_digest=

# The published, PostgreSQL-independent RDKit compile whose tree the builder
# reuses (R7) instead of cloning and compiling RDKit itself. Same ARG-in-ARG-
# default shape as postgres_base_image just above, consumed by a FROM below --
# confirmed empirically (not assumed) to expand correctly at this scope; see
# docs/spikes/2026-08-31-rdkit-core-reuse.md and task-18-report.md's C3
# section. `make core`/`make runtime` etc. (Makefile) always override this
# with a local `rdkit-core:<rdkit>-<debian>` tag; the default here only
# matters for a bare `docker build .`.
ARG rdkit_core_image=ghcr.io/radusuciu/docker-postgres-rdkit/rdkit-core:${rdkit_version}-${debian_version}

# Label inputs only, produced by the label-values-export stage (R9). NOTHING in
# the build reads boost_version to select a package; the Boost family is chosen
# by scripts/install_boost.sh from RDKit's declared floor (R2).
ARG rdkit_pickle_version=
ARG rdkit_cartridge_version=
ARG boost_version=
ARG vcs_ref=

# source_dir/build_dir/install_dir/cmake_install_dir must stay byte-identical
# to Dockerfile.rdkit-core's own ARG defaults of the same names: CMake caches
# absolute paths, and any difference invalidates the whole reused tree (R7).
# rdkit_repo/rdkit_branch_name/cmake_version are no longer used here -- the
# clone and the CMake toolchain download both moved to Dockerfile.rdkit-core;
# the builder now gets both via COPY --from=rdkit-core-provider, below.
ARG source_dir=/tmp/rdkit
ARG build_dir=/tmp/rdkit-build
ARG install_dir=/opt/rdkit
ARG cmake_install_dir=/opt/cmake
ARG num_build_cores=4

# Ruling 47: NOT one of the four paths above that must match
# Dockerfile.rdkit-core byte-for-byte -- this is only where the builder
# reads the finished tree FROM in the core image. It gets copied INTO
# ${build_dir} below, which is what keeps CMake's cached absolute paths
# (still /tmp/rdkit-build in both files) valid. Must match
# Dockerfile.rdkit-core's own `build_export_dir` default (where that image
# actually exports the tree to -- see its comments for why it isn't
# ${build_dir} itself there either).
ARG build_export_dir=/tmp/rdkit-build-export

# Default OFF, identical to the previously hardcoded value: every matrix
# build and a bare `docker build .` produce an unchanged artifact. The
# override exists as a local/on-demand lever only -- RDKit 2025_03_* and
# 2025_09_1/_2 call Descriptors::GETAWAY outside their own
# `#ifdef RDK_BUILD_DESCRIPTORS3D` guard and cannot compile with it off (see
# the cmake invocation below for the rest of that history). CI must never
# set this: scripts/build_key.sh does not include it, so two different
# artifacts built from the same key would be indistinguishable under R6.
ARG rdk_build_descriptors3d=OFF
ARG DEBIAN_FRONTEND=noninteractive


# The PostgreSQL-independent RDKit compile (R7): source tree, Boost-toggled
# build tree and CMake toolchain, shared across every PostgreSQL major. See
# Dockerfile.rdkit-core and docs/spikes/2026-08-31-rdkit-core-reuse.md.
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
ARG rdk_build_descriptors3d
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

# R7: reuse the core image's already-cloned source tree, already-compiled
# (RDK_BUILD_PGSQL=OFF) build tree and CMake toolchain instead of cloning and
# building them again here -- this is the change this Dockerfile makes for
# R7. --chown=postgres:postgres on source_dir/build_dir mirrors what the
# pre-R7 git-clone chown and the cache mount's uid=999/gid=999 respectively
# used to provide; nothing here previously ran as postgres before this point,
# so both need it explicitly now. cmake_install_dir is intentionally NOT
# chowned to postgres (nothing writes into it) and is put on PATH instead of
# symlinked into /usr/local/bin, matching the same COPY --from=builder +
# ENV PATH pattern the test-runtime stage below already uses for the same
# reason: no lineage this COPY is used in already has cmake symlinked in.
#
# C4 (six cache mounts): every `--mount=type=cache,target=${build_dir}` in
# this file is REMOVED, on all six of the RUN lines that used it (the two
# below plus test-build's and test-runtime's ctest RUN). Dockerfile.rdkit-core
# proved (spike) that the tree reaching THIS stage must be a normal image
# layer, not a cache mount, for `COPY --from=` to reach it at all -- a cache
# mount on ${build_dir} in a later RUN would silently shadow whatever COPY
# just wrote, reproducing "R7 works but every build is still slow" with no
# error. The mount's original benefit (resume a crashed build without
# recompiling) is also far smaller post-R7: the tree arriving via COPY is
# already built, and the only compilation ${build_dir} sees from here on is
# the ~15-object cartridge relink the spike measured -- not worth
# reintroducing the shadowing hazard here to save what is now a roughly
# one-minute retry.
#
# Ruling 47 restores a cache mount, but inside Dockerfile.rdkit-core, not
# here: that image's own ~25-minute compile still needs crash-resumability,
# and can have it without this stage's shadowing hazard, because it exports
# the finished tree to a DIFFERENT path (${build_export_dir}) that is never
# itself mounted over. The COPY below reads from that export path and writes
# to ${build_dir} -- a rename during the copy, not a mismatch: CMake's
# cached absolute paths are still /tmp/rdkit-build on both sides, which is
# the invariant that actually matters (verified empirically below, not
# assumed -- see task-18-report.md's Ruling 47 section).
COPY --from=rdkit-core-provider --chown=postgres:postgres ${source_dir} ${source_dir}
COPY --from=rdkit-core-provider --chown=postgres:postgres ${build_export_dir} ${build_dir}
COPY --from=rdkit-core-provider ${cmake_install_dir} ${cmake_install_dir}
ENV PATH=${cmake_install_dir}/bin:$PATH

# FALLBACK proven necessary by the spike (attempt 2): a plain COPY of Boost's
# headers/CMake-config from the core image is not sufficient to LINK against
# Boost -- the .so runtime libraries themselves were never copied. Installing
# Boost again here, in the same Debian suite the core image used, selects the
# same family (scripts/install_boost.sh reads RDKit's declared floor, R2) so
# the reconfigure below links against a byte-compatible library.
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

# RDK_BUILD_CHEMDRAW_SUPPORT: new in 2025_09_2, default ON upstream (absent
# entirely from 2024_09_5's CMakeLists.txt). The ChemDraw library itself
# builds fine -- External/ChemDraw/CMakeLists.txt fetches Glysade/chemdraw
# from codeload.github.com at configure time -- but RDKit's own FileParsers
# target (Code/GraphMol/FileParsers/CDXMLParser.cpp) `#include`s
# <ChemDraw/chemdraw.h> without that target having External/ on its include
# path, an upstream build-system bug (External/ChemDraw/CMakeLists.txt's own
# comment: "For builds, we currently need a target_include_directories and
# will need to be fixed in the future"). Turning it OFF restores exactly the
# configuration 2024_09_5 already had (the option didn't exist), matches the
# other nine optional-feature flags this list already disables, and drops an
# unpinned third-party tarball fetch from every configure step.
# CDXMLParser.cpp falls back to the legacy boost property_tree CDXML parser
# via its `#ifndef RDK_BUILD_CHEMDRAW_SUPPORT` guard, so CDXML parsing still
# works with this off.
#
# CMAKE_CXX_FLAGS=-I${source_dir}/External: upstream only puts External/ on
# the include path inside three unrelated feature-flag guards
# (RDK_BUILD_COORDGEN_SUPPORT / RDK_BUILD_MAEPARSER_SUPPORT /
# RDK_BUILD_XYZ2MOL_SUPPORT, none of which this Dockerfile enables) or inside
# the PgSQL cartridge's own CMakeLists.txt when RDK_BUILD_INCHI_SUPPORT is on
# (Code/PgSQL/rdkit/CMakeLists.txt already does this for adapter.cpp, so the
# cartridge itself is unaffected either way). Code/Bench/inchi.cpp -- pulled
# into the default `all` target by RDK_BUILD_CPP_TESTS=ON -- assumes
# External/ is on the path regardless and `#include`s <INCHI-API/inchi.h>
# without it, so this flag supplies exactly the include path upstream itself
# already grants in those other configurations, without flipping any feature
# flag or patching source.
#
# RDK_BUILD_DESCRIPTORS3D=${rdk_build_descriptors3d}: default OFF, identical
# to the value this was previously hardcoded to, so every matrix build and a
# bare `docker build .` produce an unchanged artifact. Exposed as a build
# arg (not hardcoded) purely as a local/on-demand lever: RDKit 2025_03_* and
# 2025_09_1/_2 call Descriptors::GETAWAY in
# Code/GraphMol/Descriptors/catch_tests.cpp outside their own
# `#ifdef RDK_BUILD_DESCRIPTORS3D` guard and cannot compile with it off (see
# the round-2 GETAWAY blocker this project hit against 2025_09_2 -- fixed
# there by moving the matrix to 2026_03_6/2025_09_6, which upstream patched).
# CI must never set this: scripts/build_key.sh does not key on it, so two
# differently-configured images built from the same key would be
# indistinguishable under R6.
# No cache mount (C4, above): the cmake cache under ${build_dir} is a normal
# image layer here, inherited from rdkit-core-provider via COPY. This
# reconfigure toggles RDK_BUILD_PGSQL on (the only flag that differs from
# Dockerfile.rdkit-core's configure) against that already-populated cache --
# the mechanism the spike proved: CMake sees almost everything as already
# built and only the cartridge's own sources need compiling.
RUN cmake \
    -D RDK_BUILD_CAIRO_SUPPORT=OFF \
    -D RDK_BUILD_INCHI_SUPPORT=ON \
    -D RDK_BUILD_AVALON_SUPPORT=ON \
    -D RDK_BUILD_PYTHON_WRAPPERS=OFF \
    -D RDK_BUILD_COORDGEN_SUPPORT=OFF \
    -D RDK_BUILD_MAEPARSER_SUPPORT=OFF \
    -D RDK_BUILD_DESCRIPTORS3D=${rdk_build_descriptors3d} \
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
# -j${num_build_cores} on the command line, not via a MAKEFLAGS ARG: an ARG
# default only sees ARGs already in scope AT THAT POINT in the file --
# postgres_base_image (line 9) and rdkit_core_image (line 21) show that an
# ARG default CAN reference another ARG's value, because both are global ARGs
# and the referenced one is declared earlier. The original
# `ARG MAKEFLAGS='-j${num_build_cores}'` was declared before this stage's own
# `ARG num_build_cores` re-declaration above, so at that point in the file
# num_build_cores was out of scope and the default expanded to the literal
# string "-j${num_build_cores}" -- which GNU make parses as bare `-j`, i.e.
# unlimited parallel jobs, not the throttled value this Dockerfile is
# supposed to enforce. Passing -j on the command line also gives nested
# `make` invocations a real shared jobserver, which the environment-variable
# form never provided.
RUN make -j${num_build_cores}
RUN make -j${num_build_cores} install

# pgsql_install.sh copies into /usr/share/postgresql/.../extension and
# /usr/lib/postgresql/.../lib, both root:root 0755 in the base image --
# postgres cannot write there.
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

# test-build is the full compile-tree regression run: every RDKit C++ test
# binary, dynamically linked against the build tree's libs, exercised here
# because this stage still has the builder's full toolchain (unlike
# runtime). ctest must run from the build tree (CTestTestfile.cmake lives in
# ${build_dir}, not ${source_dir}). This stage is FROM builder (same
# lineage), and ${build_dir} is now a normal image layer, not a cache mount
# (C4, above) -- so it's already present here with no COPY or mount needed.
# LD_LIBRARY_PATH points at the build tree's lib/ (out-of-tree build,
# RDK_INSTALL_INTREE=OFF) where the not-yet-installed .so files live; RDBASE
# stays the source checkout, which is where RDKit's tests look for their data
# files.
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
# No cache-mount precondition to document here post-R7 (C4): ${build_dir}
# arrived as a normal COPY'd-then-compiled layer in builder, and this stage
# inherits that layer directly (FROM builder) the same way any other file
# builder produced would carry forward -- there is no separate cache-mount
# state that can fall out of sync with the layer cache anymore.
WORKDIR ${build_dir}
RUN initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${source_dir}" LD_LIBRARY_PATH="${build_dir}/lib" ctest --no-tests=error -j${num_build_cores} --output-on-failure -E testRascalMCES


################################################################################
# The minimal runtime -- copy the cartridge in, install exactly the shared
# libraries it links (list derived in the builder, R3), and add a script to
# enable the extension in the folder that the postgres container auto-executes
# scripts from.
################################################################################
FROM ${postgres_base_image} AS runtime
ARG postgres_major_version
ARG DEBIAN_FRONTEND

COPY --from=builder /usr/share/postgresql/${postgres_major_version}/extension/*rdkit* /usr/share/postgresql/${postgres_major_version}/extension/
COPY --from=builder /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so
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
# Verifies the runtime image's derived package set (R3) is sufficient to
# load and exercise the RDKit cartridge inside a real postgres server. This
# runs one test, testPgSQL, not the full RDKit suite -- see the comment
# above the RUN below for why.
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
COPY --from=builder --chown=postgres ${source_dir} ${source_dir}
# C4: ${build_dir} is no longer a cache mount, so it no longer reaches this
# stage "for free" via the shared mount id the way it used to -- this stage
# is a different lineage from builder (FROM runtime, not FROM builder) and
# must now COPY it explicitly, the same way source_dir and cmake_install_dir
# already were.
COPY --from=builder --chown=postgres ${build_dir} ${build_dir}
COPY --from=builder ${cmake_install_dir} ${cmake_install_dir}
ENV PATH=${cmake_install_dir}/bin:$PATH

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
# ctest needs ${build_dir} for CTestTestfile.cmake and the built .so files;
# the COPY --from=builder above (C4, post-R7) puts it here as a normal image
# layer -- no cache-mount precondition to document anymore (contrast the
# pre-R7 version of this comment: cache-mount contents never entered an image
# layer, so a layer-cache hit on builder's compile steps could leave the
# mount empty here even though the build looked done. A COPY doesn't have
# that failure mode -- if builder's layer exists, this COPY has the tree).
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
WORKDIR ${build_dir}
RUN initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${source_dir}" LD_LIBRARY_PATH="${build_dir}/lib" ctest --no-tests=error -R '^testPgSQL$' --output-on-failure; \
    status=$?; \
    pg_ctl -D /tmp/pgdata stop; \
    exit $status
