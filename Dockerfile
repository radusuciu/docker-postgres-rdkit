ARG debian_version=bookworm
ARG boost_version=1.85.0
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
ARG MAKEFLAGS='-j${NUM_BUILD_CORES}'
ARG DEBIAN_FRONTEND=noninteractive


################################################################################
# Pre-built Boost libraries from separate Dockerfile.boost
# Build with: docker build -f Dockerfile.boost --build-arg debian_version=bookworm --build-arg boost_version=1.85.0 -t boost:bookworm-1.85.0 .
################################################################################
FROM boost:${debian_version}-${boost_version} AS boost-provider


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
ARG MAKEFLAGS
ARG DEBIAN_FRONTEND

COPY --from=boost-provider /tmp/boost_debs/* /tmp/boost_debs/
COPY --from=boost-provider /tmp/boost_dev_debs/* /tmp/boost_debs/

RUN dpkg -i /tmp/boost_debs/*.deb \
    && rm -rf /tmp/boost_debs \
    && apt-get update \
    && apt-get install -yq --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt-archive.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg-archive main" >> /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -yq --no-install-recommends --no-install-suggests --allow-downgrades \
        build-essential \
        git \
        libeigen3-dev \
        libfreetype6-dev \
        postgresql-server-dev-${PG_MAJOR_VERSION}=$(postgres -V | awk '{print $3}')\* \
        libpq5=$(postgres -V | awk '{print $3}')\* \
        libpq-dev=$(postgres -V | awk '{print $3}')\* \
        zlib1g-dev \
        libbz2-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN <<-EOF
    set -eux
    curl -L https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.sh -o /tmp/cmake.sh

    mkdir -p ${CMAKE_INSTALL_DIR}
    sh /tmp/cmake.sh --skip-license --prefix=${CMAKE_INSTALL_DIR}
    ln -s ${CMAKE_INSTALL_DIR}/bin/cmake /usr/local/bin/cmake
    ln -s ${CMAKE_INSTALL_DIR}/bin/ctest /usr/local/bin/ctest
    rm -rf /tmp/*
EOF

USER postgres
RUN git clone --depth=1 --branch=${RDKIT_BRANCH_NAME} ${RDKIT_REPO} ${SOURCE_DIR}

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
    # -D Boost_USE_STATIC_LIBS=ON \
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
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    make
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    make install
RUN --mount=type=cache,target=/tmp/rdkit-build,id=rdkit-build,uid=999,gid=999 \
    /bin/bash ./Code/PgSQL/rdkit/pgsql_install.sh


################################################################################
# Testing that the build was successful by running the test suite
################################################################################
FROM builder AS test-build
ARG SOURCE_DIR
ARG BUILD_DIR
ARG NUM_BUILD_CORES

# pg_ctl cannot be run as root
# we change ownership of the source dir so that ctest can log out here for convenience
# TODO: this is slow.. revert back to how we used to change to postgres here
RUN chown -R postgres ${SOURCE_DIR}
USER postgres

WORKDIR ${SOURCE_DIR}
RUN initdb -D /tmp/pgdata \
  && pg_ctl -D /tmp/pgdata -l /tmp/pgdata/log.txt start \
  && RDBASE="${SOURCE_DIR}" LD_LIBRARY_PATH=""${SOURCE_DIR}/lib" ctest -j${NUM_BUILD_CORES} --output-on-failure


################################################################################
# Grabbing the appropriate libpq5 deb (and all of its dependencies)
# The reason I do this is to avoid having to add the PPA to the runtime image
################################################################################
FROM builder AS deb-collector
ARG DEBIAN_FRONTEND

WORKDIR /tmp/debs
COPY --from=boost-provider /tmp/boost_debs/* .
USER root
RUN <<EOF
apt-get update
apt-get install -y apt-rdepends

# Fetch the full package name for libpq5
libpq5_full_name=$(
    apt-cache madison libpq5 | grep -F $(postgres -V | awk '{print $3}') |
    awk '{print $3}'
)

# Get the direct dependencies of libpq5
libpq5_deps=$(apt-cache depends libpq5 | awk '/Depends:/ {print $2}')

# Combine libpq5s direct dependencies, and other packages
packages="$libpq5_deps libfreetype6 zlib1g"

# Resolve recursive dependencies
resolved_packages=$(apt-rdepends $packages | grep -v "^ " | grep -v "debconf-2.0")

# Update package lists and download packages
apt-get download libpq5=$libpq5_full_name $resolved_packages
EOF


################################################################################
# The minimal runtime -- we just copy the debs, and add a script to enable
# the extension in the folder that the postgres container auto-executes scripts
# from.
################################################################################
FROM docker.io/postgres:${PG_IMAGE_TAG}-${debian_version} AS runtime
ARG PG_MAJOR_VERSION

COPY --from=deb-collector /tmp/debs/ /tmp/debs/
COPY --from=builder /usr/share/postgresql/${PG_MAJOR_VERSION}/extension/*rdkit* /usr/share/postgresql/${PG_MAJOR_VERSION}/extension/
COPY --from=builder /usr/lib/postgresql/${PG_MAJOR_VERSION}/lib/rdkit.so /usr/lib/postgresql/${PG_MAJOR_VERSION}/lib/rdkit.so
COPY ./enable_extension.sql /docker-entrypoint-initdb.d/
RUN dpkg --force-depends -i /tmp/debs/*.deb \
    && apt-get install --no-download --ignore-missing -f \
    && rm -rf /tmp/debs

LABEL org.opencontainers.image.source=https://github.com/radusuciu/docker-postgres-rdkit


################################################################################
# Just for safety, I like to run the tests again in the runtime image since
# the runtime dependencies are different from those that we had installed
# during the build
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

WORKDIR ${SOURCE_DIR}

RUN initdb -D ${BUILD_DIR}/pgdata \
  && pg_ctl -D ${BUILD_DIR}/pgdata -l ${BUILD_DIR}/pgdata/log.txt start \
  && RDBASE="$PWD" LD_LIBRARY_PATH="$PWD/lib" ctest -j${NUM_BUILD_CORES} --output-on-failure \
  && pg_ctl -D ${BUILD_DIR}/pgdata stop; exit 0
