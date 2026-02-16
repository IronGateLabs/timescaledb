# PostGIS ECEF/ECI + TimescaleDB Integration Test Environment
#
# Builds the PostGIS fork from source and installs TimescaleDB from packages,
# then runs the contract §7 integration test checklist.
#
# Requires Docker BuildKit (default in Docker Compose v2+).
#
# Usage with docker compose (recommended):
#   cd docker/integration-test && docker compose up --build
#
# Usage with docker build:
#   docker build \
#     --build-context postgis-src=/path/to/postgis \
#     -f docker/integration-test/Dockerfile \
#     -t ecef-eci-test .
#   docker run --rm ecef-eci-test

FROM postgres:16-bookworm

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# ---- Install build dependencies for PostGIS ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    # PostGIS core dependencies
    libgeos-dev \
    libproj-dev \
    libgdal-dev \
    libjson-c-dev \
    libxml2-dev \
    libpcre3-dev \
    # Protobuf (for MVT support)
    libprotobuf-c-dev \
    protobuf-c-compiler \
    # PostgreSQL server dev headers
    postgresql-server-dev-16 \
    # Utilities
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# ---- Build PostGIS fork from source ----
# The 'postgis-src' named context is provided via docker compose additional_contexts
# or via --build-context on the command line.
COPY --from=postgis-src . /build/postgis
WORKDIR /build/postgis

# Skip loader (shp2pgsql/pgsql2shp) — not needed for tests and hits
# __isoc23_strtol linker error on bookworm due to glibc mismatch.
# Also skip raster — not needed for ECEF/ECI integration testing.
# Patch postgis.pl to recognize postgis_ecef_eci as a supported extension
# (the fork adds this extension but the loader script needs the hash entry).
RUN ./autogen.sh && \
    ./configure \
        --without-topology \
        --without-raster \
        --without-address-standardizer \
        --without-gui \
    && sed -i '/^SUBDIRS +=.*loader/d' GNUmakefile \
    && sed -i "s/'postgis_tiger_geocoder' => 1,/'postgis_tiger_geocoder' => 1,\n\t'postgis_ecef_eci' => 1,/" loader/postgis.pl \
    && make -j"$(nproc)" \
    && make install

# ---- Install TimescaleDB from packages ----
RUN echo "deb https://packagecloud.io/timescale/timescaledb/debian/ bookworm main" \
      > /etc/apt/sources.list.d/timescaledb.list && \
    curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | \
      gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg && \
    apt-get update && \
    apt-get install -y --no-install-recommends timescaledb-2-postgresql-16 && \
    rm -rf /var/lib/apt/lists/*

# ---- Copy test artifacts ----
WORKDIR /test
COPY sql/postgis_ecef_eci/ /test/sql/
COPY docker/integration-test/run_integration_tests.sh /test/
COPY docker/integration-test/integration_test.sql /test/
RUN chmod +x /test/run_integration_tests.sh

# ---- Clean up build artifacts to reduce image size ----
RUN rm -rf /build

ENTRYPOINT ["/test/run_integration_tests.sh"]
