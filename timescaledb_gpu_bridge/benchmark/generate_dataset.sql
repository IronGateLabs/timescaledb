-- generate_dataset.sql - Synthetic ECEF dataset generation for benchmarking
--
-- Generates ECEF POINT Z geometries (SRID 4978) distributed across LEO, MEO,
-- and GEO orbital altitude bands with associated timestamps.
--
-- Parameters (set via psql variables):
--   :num_rows   - number of rows to generate (default 100000)
--   :orbit_type - 'LEO', 'MEO', 'GEO', or 'mixed' (default 'mixed')
--   :timespan   - interval for timestamp distribution (default '24 hours')

-- Defaults
\set num_rows_default 100000
SELECT COALESCE(:'num_rows', '100000')::int AS num_rows \gset
SELECT COALESCE(:'orbit_type', 'mixed') AS orbit_type \gset
SELECT COALESCE(:'timespan', '24 hours')::interval AS timespan \gset

-- Create extensions if needed
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Drop existing table if present
DROP TABLE IF EXISTS benchmark_ecef_points CASCADE;

-- Create hypertable
CREATE TABLE benchmark_ecef_points (
    ts          timestamptz     NOT NULL,
    object_id   integer         NOT NULL,
    position    geometry(PointZ, 4978) NOT NULL,
    ecef_x      float8          NOT NULL,
    ecef_y      float8          NOT NULL,
    ecef_z      float8          NOT NULL
);

SELECT create_hypertable('benchmark_ecef_points', 'ts',
                         chunk_time_interval => INTERVAL '1 hour');

-- Altitude bands (km from Earth center, Earth radius ~6371 km)
-- LEO: 6571-8371 km (200-2000 km altitude)
-- MEO: 26571-28371 km (20200-22000 km altitude)
-- GEO: 42164 km (35793 km altitude)

-- Generate data using a series
INSERT INTO benchmark_ecef_points (ts, object_id, position, ecef_x, ecef_y, ecef_z)
SELECT
    '2025-01-01 00:00:00+00'::timestamptz +
        (i::float8 / :num_rows::float8) * :'timespan'::interval AS ts,
    (i % 100) + 1 AS object_id,
    -- Generate ECEF coordinates based on orbit type
    ST_SetSRID(
        ST_MakePoint(
            r * cos(theta) * cos(phi),
            r * cos(theta) * sin(phi),
            r * sin(theta)
        ),
        4978
    ) AS position,
    r * cos(theta) * cos(phi) AS ecef_x,
    r * cos(theta) * sin(phi) AS ecef_y,
    r * sin(theta) AS ecef_z
FROM (
    SELECT
        i,
        -- Orbit radius based on type
        CASE
            WHEN :'orbit_type' = 'LEO' THEN
                6571.0 + random() * 1800.0
            WHEN :'orbit_type' = 'MEO' THEN
                26571.0 + random() * 1800.0
            WHEN :'orbit_type' = 'GEO' THEN
                42164.0 + random() * 10.0
            WHEN :'orbit_type' = 'mixed' THEN
                CASE
                    WHEN random() < 0.60 THEN 6571.0 + random() * 1800.0   -- LEO 60%
                    WHEN random() < 0.84 THEN 26571.0 + random() * 1800.0  -- MEO 25%
                    ELSE 42164.0 + random() * 10.0                          -- GEO 15%
                END
            ELSE
                6571.0 + random() * 1800.0  -- default LEO
        END * 1000.0 AS r,  -- convert km to meters
        -- Latitude: uniform over sphere
        asin(2.0 * random() - 1.0) AS theta,
        -- Longitude: uniform [0, 2*pi)
        2.0 * pi() * random() AS phi
    FROM generate_series(1, :num_rows) AS i
) sub;

-- Enable compression
ALTER TABLE benchmark_ecef_points SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'object_id',
    timescaledb.compress_orderby = 'ts'
);

-- Compress all chunks
SELECT compress_chunk(c) FROM show_chunks('benchmark_ecef_points') c;

-- Report
SELECT
    count(*) AS total_rows,
    count(DISTINCT object_id) AS num_objects,
    min(ts) AS earliest_ts,
    max(ts) AS latest_ts,
    pg_size_pretty(pg_total_relation_size('benchmark_ecef_points')) AS total_size
FROM benchmark_ecef_points;
