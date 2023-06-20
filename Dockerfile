ARG postgres_image_version
ARG postgres_major_version
ARG boost_version=1.78
ARG DEBIAN_FRONTEND=noninteractive

FROM debian:bullseye as boost-builder
ARG boost_version
ARG DEBIAN_FRONTEND
ENV BOOST_LIBS_TO_BUILD=iostreams,regex,serialization,system

RUN apt-get update && apt-get install -y \
    build-essential \
    g++ \
    python-dev \
    autotools-dev \
    libicu-dev \
    libbz2-dev \
    wget \
    devscripts \
    debhelper \
    fakeroot \
    cdbs \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* 

# script modified from
#
# https://github.com/ulikoehler/deb-buildscripts
# authored by Uli Köhler and distributed under CC0 1.0 Universal
#
# I am including it as a heredoc because I want to keep it all in one
# Dockerfile, though I may reconsider in the future.
RUN <<EOF

export MAJORVERSION=$(echo $boost_version | cut -d. -f1)
export MINORVERSION=$(echo $boost_version | cut -d. -f2)
export PATCHVERSION=$(echo $boost_version | cut -d. -f3)
export PATCHVERSION=${PATCHVERSION:-0}
export FULLVERSION=${MAJORVERSION}.${MINORVERSION}.${PATCHVERSION}
export UNDERSCOREVERSION=${MAJORVERSION}_${MINORVERSION}_${PATCHVERSION}
export DEBVERSION=${FULLVERSION}-1

if [ ! -d "boost_${UNDERSCOREVERSION}" ]; then
    wget "https://boostorg.jfrog.io/artifactory/main/release/${FULLVERSION}/source/boost_${UNDERSCOREVERSION}.tar.bz2" -O boost-all_${FULLVERSION}.orig.tar.bz2
    tar xjvf boost-all_${FULLVERSION}.orig.tar.bz2
fi

cd boost_${UNDERSCOREVERSION}
#Build DEB
rm -rf debian
mkdir -p debian
#Use the LICENSE file from nodejs as copying file
touch debian/copying
#Create the changelog (no messages needed)
export DEBEMAIL="none@example.com"
dch --create -v $DEBVERSION --package boost-all ""
#Create copyright file
touch debian
#Create control file
cat > debian/control <<EOF_CONTROL
Source: boost-all
Maintainer: None <none@example.com>
Section: misc
Priority: optional
Standards-Version: 3.9.2
Build-Depends: debhelper (>= 8), cdbs, libbz2-dev, zlib1g-dev

Package: boost-all
Architecture: amd64
Depends: \${shlibs:Depends}, \${misc:Depends}, boost-all (= $DEBVERSION)
Description: Boost library, version $DEBVERSION (shared libraries)

Package: boost-all-dev
Architecture: any
Depends: boost-all (= $DEBVERSION)
Description: Boost library, version $DEBVERSION (development files)

Package: boost-build
Architecture: any
Depends: \${misc:Depends}
Description: Boost Build v2 executable
EOF_CONTROL
#Create rules file
cat > debian/rules <<EOF_RULES
#!/usr/bin/make -f
%:
	dh \$@
override_dh_auto_configure:
	./bootstrap.sh
override_dh_auto_build:
	./b2 $(echo $BOOST_LIBS_TO_BUILD | sed 's/,/ --with-/g' | awk '{print "--with-"$0}') link=static,shared -j 2 --prefix=`pwd`/debian/boost-all/usr/
override_dh_auto_test:
override_dh_auto_install:
	mkdir -p debian/boost-all/usr debian/boost-all-dev/usr debian/boost-build/usr/bin
	./b2 $(echo $BOOST_LIBS_TO_BUILD | sed 's/,/ --with-/g' | awk '{print "--with-"$0}') link=static,shared --prefix=`pwd`/debian/boost-all/usr/ install
	mv debian/boost-all/usr/include debian/boost-all-dev/usr
	cp b2 debian/boost-build/usr/bin
	./b2 install --prefix=`pwd`/debian/boost-build/usr/ install
EOF_RULES
#Create some misc files
echo "8" > debian/compat
mkdir -p debian/source
echo "3.0 (quilt)" > debian/source/format
#Build the package
nice -n19 ionice -c3 debuild -b

EOF

# separate the files for convenience
RUN mkdir /tmp/boost_debs /tmp/boost_dev_debs && \
    mv /tmp/*-dev*.deb /tmp/boost_dev_debs/ && \
    mv /tmp/*.deb /tmp/boost_debs/


FROM docker.io/postgres:${postgres_image_version}-bullseye AS builder
LABEL org.opencontainers.image.source https://github.com/radusuciu/docker-postgres-rdkit
ARG postgres_major_version
ARG rdkit_git_ref
ARG boost_version
ARG DEBIAN_FRONTEND
ARG cmake_version=3.26.4
ARG rdkit_git_url=https://github.com/rdkit/rdkit.git

COPY --from=boost-builder /tmp/boost_debs/libboost-iostreams*.deb \
    /tmp/boost_dev_debs/libboost-regex*.deb \
    /tmp/boost_dev_debs/libboost-serialization*.deb \
    /tmp/boost_dev_debs/libboost-system*.deb \
    /tmp/boost_dev_debs/
RUN dpkg -i /tmp/boost_debs/*.deb && rm -rf /tmp/boost_debs

RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
    && curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main ${postgres_major_version}" > /etc/apt/sources.list.d/pgdg.list

RUN apt-get update \
    && apt-get install -yq --no-install-recommends --allow-downgrades \
        build-essential \
        git \
        libeigen3-dev \
        libfreetype6-dev \
        postgresql-server-dev-${postgres_major_version}=$(postgres -V | awk '{print $3}')\* \
        libpq5=$(postgres -V | awk '{print $3}')\* \
        libpq-dev=$(postgres -V | awk '{print $3}')\* \
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
RUN make -j2

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
ARG postgres_major_version
ARG boost_version

COPY --from=boost-builder /tmp/boost_debs/libboost-iostreams*.deb \
    /tmp/boost_debs/libboost-regex*.deb \
    /tmp/boost_debs/libboost-serialization*.deb \
    /tmp/boost_debs/libboost-system*.deb \
    /tmp/boost_debs/
RUN dpkg -i /tmp/boost_debs/*.deb && rm -rf /tmp/boost_debs

RUN apt-get update \
    && apt-get install -yq --no-install-recommends \
        libfreetype6 \
        zlib1g \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/share/postgresql/${postgres_major_version}/extension/*rdkit* /usr/share/postgresql/${postgres_major_version}/extension/
COPY --from=builder /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so /usr/lib/postgresql/${postgres_major_version}/lib/rdkit.so