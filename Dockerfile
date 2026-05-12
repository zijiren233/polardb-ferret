# syntax=docker/dockerfile:1.7

ARG POLARDB_DEVEL_IMAGE=polardb/polardb_pg_devel:anolis8
ARG RUNTIME_IMAGE=openanolis/anolisos:8

ARG POLARDB_REPO=https://github.com/polardb/PolarDB-for-PostgreSQL.git
ARG POLARDB_REF=POLARDB_17_STABLE
ARG POLARDB_MAJOR=17

ARG DOCUMENTDB_REPO=https://github.com/documentdb/documentdb.git
ARG DOCUMENTDB_REF=v0.107-0
ARG PGVECTOR_REF=v0.8.0
ARG POSTGIS_REF=3.5.2
ARG RUM_REF=1.3.14
ARG GEOS_REF=3.12.2

# 1. Clone PolarDB and build RPM inside Dockerfile
FROM ${POLARDB_DEVEL_IMAGE} AS polardb-rpm-builder

ARG POLARDB_REPO
ARG POLARDB_REF

USER root

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    dnf install -y --setopt=keepcache=1 git ca-certificates rpm-build || true

RUN git clone --depth 1 --branch "${POLARDB_REF}" \
    "${POLARDB_REPO}" \
    /home/postgres/PolarDB-for-PostgreSQL \
    && chown -R postgres:postgres /home/postgres/PolarDB-for-PostgreSQL

WORKDIR /home/postgres/PolarDB-for-PostgreSQL/package/rpm

RUN ./build-rpm.sh \
    && mkdir -p /out \
    && find /home/postgres/PolarDB-for-PostgreSQL \
    -type f \
    -name 'PolarDB-*.rpm' \
    ! -name '*debuginfo*' \
    ! -name '*debugsource*' \
    -exec cp -v {} /out/ \;

# 2. Optional: build DocumentDB against PolarDB's pg_config
FROM ${RUNTIME_IMAGE} AS documentdb-builder

ARG DOCUMENTDB_REPO
ARG DOCUMENTDB_REF
ARG POLARDB_MAJOR
ARG PGVECTOR_REF
ARG POSTGIS_REF
ARG RUM_REF
ARG GEOS_REF

COPY --from=polardb-rpm-builder /out/PolarDB-*.rpm /tmp/

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    rpm -ivh /tmp/PolarDB-*.rpm \
    && ln -sfn "/u01/polardb_pg_${POLARDB_MAJOR}" /u01/polardb_pg \
    && mkdir -p "/usr/pgsql-${POLARDB_MAJOR}" \
    && ln -sfn /u01/polardb_pg/bin "/usr/pgsql-${POLARDB_MAJOR}/bin" \
    && dnf install -y --setopt=keepcache=1 epel-release \
    && dnf install -y --setopt=keepcache=1 \
    autoconf \
    automake \
    bzip2 \
    bzip2-devel \
    ca-certificates \
    curl \
    diffutils \
    file \
    flex \
    git \
    gcc \
    gcc-c++ \
    geos-devel \
    json-c-devel \
    krb5-devel \
    libcurl-devel \
    libicu-devel \
    libtool \
    libuuid-devel \
    libxml2-devel \
    lz4-devel \
    cmake \
    make \
    openssl-devel \
    perl \
    pkgconf-pkg-config \
    proj-devel \
    readline-devel \
    snappy-devel \
    tar \
    wget \
    which \
    zlib-devel \
    && rm -f /tmp/PolarDB-*.rpm

ENV PATH=/u01/polardb_pg/bin:$PATH
ENV PG_CONFIG=/u01/polardb_pg/bin/pg_config
ENV PGVERSION=17

RUN --mount=type=cache,target=/var/cache/source-downloads,sharing=locked \
    mkdir -p /src \
    && geos_archive="/var/cache/source-downloads/geos-${GEOS_REF}.tar.bz2" \
    && if [ ! -s "$geos_archive" ]; then \
    curl --retry 5 --retry-delay 3 -fsSL \
    "https://download.osgeo.org/geos/geos-${GEOS_REF}.tar.bz2" \
    -o "$geos_archive"; \
    fi \
    && tar -xjf "$geos_archive" -C /src \
    && cmake -S "/src/geos-${GEOS_REF}" -B /src/geos-build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_TESTING=OFF \
    && cmake --build /src/geos-build -j"$(nproc)" \
    && cmake --install /src/geos-build \
    && ldconfig

RUN git clone --depth 1 --branch "${DOCUMENTDB_REF}" \
    "${DOCUMENTDB_REPO}" \
    /src/documentdb \
    && sed -i \
    -e 's/curl -s -L/curl --retry 5 --retry-delay 3 -fsSL/g' \
    -e 's/curl -L/curl --retry 5 --retry-delay 3 -fL/g' \
    /src/documentdb/scripts/install_setup_libbson.sh \
    /src/documentdb/scripts/install_setup_pcre2.sh \
    && export INSTALL_DEPENDENCIES_ROOT=/tmp/documentdb-deps \
    && mkdir -p "$INSTALL_DEPENDENCIES_ROOT" \
    && MAKE_PROGRAM=cmake /src/documentdb/scripts/install_setup_libbson.sh \
    && /src/documentdb/scripts/install_setup_pcre2.sh \
    && /src/documentdb/scripts/install_setup_intel_decimal_math_lib.sh \
    && rm -rf "$INSTALL_DEPENDENCIES_ROOT"

RUN --mount=type=cache,target=/var/cache/source-downloads,sharing=locked \
    git clone --depth 1 --branch "${PGVECTOR_REF}" \
    https://github.com/pgvector/pgvector.git \
    /src/pgvector \
    && make -C /src/pgvector PG_CONFIG="${PG_CONFIG}" OPTFLAGS="" with_llvm=no \
    && make -C /src/pgvector PG_CONFIG="${PG_CONFIG}" with_llvm=no install \
    && postgis_archive="/var/cache/source-downloads/postgis-${POSTGIS_REF}.tar.gz" \
    && if [ ! -s "$postgis_archive" ]; then \
    curl --retry 5 --retry-delay 3 -fsSL \
    "https://download.osgeo.org/postgis/source/postgis-${POSTGIS_REF}.tar.gz" \
    -o "$postgis_archive"; \
    fi \
    && tar -xzf "$postgis_archive" -C /src \
    && cd "/src/postgis-${POSTGIS_REF}" \
    && ./autogen.sh \
    && ./configure \
    --with-pgconfig="${PG_CONFIG}" \
    --without-protobuf \
    --without-raster \
    --without-topology \
    && make with_llvm=no \
    && make with_llvm=no install \
    && git clone --depth 1 --branch "${RUM_REF}" \
    https://github.com/postgrespro/rum.git \
    /src/rum \
    && make -C /src/rum USE_PGXS=1 PG_CONFIG="${PG_CONFIG}" with_llvm=no \
    && make -C /src/rum USE_PGXS=1 PG_CONFIG="${PG_CONFIG}" with_llvm=no install

RUN cd /src/documentdb \
    && sed -i '/internal/d' Makefile \
    && make -j"$(nproc)" \
    PG_CONFIG=/u01/polardb_pg/bin/pg_config \
    PG_CFLAGS="-std=gnu99 -Wall -Wno-error" \
    CFLAGS="" \
    with_llvm=no \
    && make install-no-distributed \
    PG_CONFIG=/u01/polardb_pg/bin/pg_config \
    PG_CFLAGS="-std=gnu99 -Wall -Wno-error" \
    CFLAGS="" \
    with_llvm=no \
    && test -f /u01/polardb_pg/share/postgresql/extension/documentdb.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/pg_cron.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/vector.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/postgis.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/rum.control \
    && ldd /u01/polardb_pg/lib/postgresql/pg_documentdb.so

# 3. Final runtime image
FROM ${RUNTIME_IMAGE}

ARG POLARDB_MAJOR

COPY --from=polardb-rpm-builder /out/PolarDB-*.rpm /tmp/

RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    dnf install -y --setopt=keepcache=1 \
    epel-release \
    && dnf install -y --setopt=keepcache=1 \
    bash \
    ca-certificates \
    geos \
    json-c \
    libxml2 \
    proj \
    which \
    && rpm -ivh /tmp/PolarDB-*.rpm \
    && ln -sfn "/u01/polardb_pg_${POLARDB_MAJOR}" /u01/polardb_pg \
    && (id postgres >/dev/null 2>&1 || useradd -m postgres) \
    && mkdir -p /var/lib/polardb \
    && chown -R postgres:postgres /var/lib/polardb /u01/polardb_pg \
    && rm -f /tmp/PolarDB-*.rpm

COPY --from=documentdb-builder /u01/polardb_pg_17/ /u01/polardb_pg_17/
COPY --from=documentdb-builder /usr/local/ /usr/local/
COPY --from=documentdb-builder /usr/lib64/libbson-1.0.so* /usr/lib64/

RUN echo "/usr/local/lib64" > /etc/ld.so.conf.d/usr-local-lib64.conf \
    && echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local-lib.conf \
    && ldconfig \
    && test -f /u01/polardb_pg/share/postgresql/extension/documentdb.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/pg_cron.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/vector.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/postgis.control \
    && test -f /u01/polardb_pg/share/postgresql/extension/rum.control

COPY polardb-entrypoint.sh /usr/local/bin/polardb-entrypoint.sh

RUN chmod +x /usr/local/bin/polardb-entrypoint.sh

ENV PATH=/u01/polardb_pg/bin:$PATH
ENV POLARDB_PORT=5432
ENV POLARDB_DATA_ROOT=/var/lib/polardb
ENV POLARDB_ENABLE_DOCUMENTDB=1

EXPOSE 5432

ENTRYPOINT ["/usr/local/bin/polardb-entrypoint.sh"]
