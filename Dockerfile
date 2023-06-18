FROM docker.io/postgres:${postgres_image_version}-bullseye AS builder
LABEL org.opencontainers.image.source https://github.com/radusuciu/docker-postgres-rdkit
ARG postgres_version
ARG boost_version=1.74
ARG cmake_version=3.26.4
ARG rdkit_git_url=https://github.com/rdkit/rdkit.git
ARG rdkit_git_ref=Release_2023_03_1

RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
    && curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        build-essential \
        git \
        libboost-iostreams${boost_version}-dev \
        libboost-regex${boost_version}-dev \
        libboost-serialization${boost_version}-dev \
        libboost-system${boost_version}-dev \
        libeigen3-dev \
        libfreetype6-dev \
        postgresql-server-dev-${postgres_version}=$(postgres -V | awk '{print $3}')\* \
        zlib1g-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN curl -L https://github.com/Kitware/CMake/releases/download/v${cmake_version}/cmake-${cmake_version}-linux-x86_64.sh -o cmake.sh
RUN mkdir -p /opt/cmake
RUN sh cmake.sh --skip-license --prefix=/opt/cmake
RUN ln -s /opt/cmake/bin/cmake /usr/local/bin/cmake
RUN ln -s /opt/cmake/bin/ctest /usr/local/bin/ctest
RUN rm -rf /tmp/*

RUN mkdir -p /opt/RDKit-build \
    && chown postgres:postgres /opt/RDKit-build

USER postgres
WORKDIR /opt/RDKit-build

RUN git clone ${rdkit_git_url}
WORKDIR /opt/RDKit-build/rdkit
RUN git checkout ${rdkit_git_ref}

RUN cmake \
    -D RDK_BUILD_CAIRO_SUPPORT=OFF \
    -D RDK_BUILD_INCHI_SUPPORT=ON \
    -D RDK_BUILD_AVALON_SUPPORT=ON \
    -D RDK_BUILD_PYTHON_WRAPPERS=OFF \
    -D RDK_BUILD_DESCRIPTORS3D=OFF \
    -D RDK_BUILD_FREESASA_SUPPORT=OFF \
    -D RDK_BUILD_COORDGEN_SUPPORT=ON \
    -D RDK_BUILD_MOLINTERCHANGE_SUPPORT=OFF \
    -D RDK_BUILD_YAEHMOP_SUPPORT=OFF \
    -D RDK_BUILD_STRUCTCHECKER_SUPPORT=OFF \
    -D RDK_USE_URF=OFF \
    -D RDK_BUILD_PGSQL=ON \
    -D RDK_PGSQL_STATIC=ON \
    -D PostgreSQL_CONFIG=pg_config \
    -D PostgreSQL_INCLUDE_DIR=`pg_config --includedir` \
    -D PostgreSQL_TYPE_INCLUDE_DIR=`pg_config --includedir-server` \
    -D PostgreSQL_LIBRARY_DIR=`pg_config --libdir` \
    -D RDK_INSTALL_INTREE=OFF \
    -D CMAKE_INSTALL_PREFIX=/opt/RDKit \
    -D CMAKE_BUILD_TYPE=Release \
    .
RUN make

USER root
WORKDIR /opt/RDKit-build/rdkit

RUN make install
RUN /bin/bash /opt/RDKit-build/rdkit/Code/PgSQL/rdkit/pgsql_install.sh

USER postgres
WORKDIR /opt/RDKit-build/rdkit

RUN initdb -D /opt/RDKit-build/pgdata \
  && pg_ctl -D /opt/RDKit-build/pgdata -l /opt/RDKit-build/pgdata/log.txt start \
  && RDBASE="$PWD" LD_LIBRARY_PATH="$PWD/lib" ctest -j10 --output-on-failure \
  && pg_ctl -D /opt/RDKit-build/pgdata stop; exit 0


FROM docker.io/postgres:${postgres_image_version}-bullseye
LABEL org.opencontainers.image.source https://github.com/radusuciu/chompounddb
ARG postgres_version
ARG boost_version

RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        libboost-iostreams${boost_version} \
        libboost-regex${boost_version} \
        libboost-serialization${boost_version} \
        libboost-system${boost_version} \
        libfreetype6 \
        zlib1g \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/share/postgresql/${postgres_version}/extension/*rdkit* /usr/share/postgresql/${postgres_version}/extension/
COPY --from=builder /usr/lib/postgresql/${postgres_version}/lib/rdkit.so /usr/lib/postgresql/${postgres_version}/lib/rdkit.so
