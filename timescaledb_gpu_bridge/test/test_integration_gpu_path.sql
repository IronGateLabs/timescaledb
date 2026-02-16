-- test_integration_gpu_path.sql - Integration test for GPU path selection
--
-- Tests that a spatial aggregate on a compressed hypertable correctly
-- selects the GPU path when PG-Strom is available (shown via EXPLAIN).
-- When PG-Strom is absent, verifies the CPU path is used instead.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS timescaledb_gpu_bridge;

-- Create compressed hypertable with ECEF data
CREATE TABLE test_spatial_agg (
    ts timestamptz NOT NULL,
    object_id integer NOT NULL,
    position geometry(PointZ, 4978) NOT NULL,
    ecef_x float8 NOT NULL,
    ecef_y float8 NOT NULL,
    ecef_z float8 NOT NULL
);

SELECT create_hypertable('test_spatial_agg', 'ts',
                         chunk_time_interval => INTERVAL '1 hour');

-- Insert test data
INSERT INTO test_spatial_agg
SELECT
    '2025-01-01'::timestamptz + (i || ' seconds')::interval,
    i % 20,
    ST_SetSRID(ST_MakePoint(
        6378137.0 * cos(radians(i * 3.6)),
        6378137.0 * sin(radians(i * 3.6)),
        1000.0 * (i % 100)
    ), 4978),
    6378137.0 * cos(radians(i * 3.6)),
    6378137.0 * sin(radians(i * 3.6)),
    1000.0 * (i % 100)
FROM generate_series(1, 10000) i;

-- Compress
ALTER TABLE test_spatial_agg SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'object_id',
    timescaledb.compress_orderby = 'ts'
);
SELECT compress_chunk(c) FROM show_chunks('test_spatial_agg') c;

-- Test: EXPLAIN should show VectorAgg (no GPU annotation without PG-Strom)
EXPLAIN (VERBOSE)
SELECT object_id, avg(ecef_x), avg(ecef_y), avg(ecef_z)
FROM test_spatial_agg
GROUP BY object_id;

-- Test: Query results should be correct regardless of path
SELECT
    object_id,
    round(avg(ecef_x)::numeric, 2) AS avg_x,
    round(avg(ecef_y)::numeric, 2) AS avg_y,
    round(avg(ecef_z)::numeric, 2) AS avg_z
FROM test_spatial_agg
WHERE object_id <= 3
GROUP BY object_id
ORDER BY object_id;

-- Clean up
DROP TABLE test_spatial_agg;
DROP EXTENSION timescaledb_gpu_bridge;
