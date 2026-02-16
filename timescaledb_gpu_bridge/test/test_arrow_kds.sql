-- test_arrow_kds.sql - Unit test for Arrow-to-KDS conversion
--
-- Tests the conversion logic by exercising the GPU bridge with
-- a known ECEF geometry batch. Since conversion happens internally,
-- we verify via the diagnostic functions and result correctness.

CREATE EXTENSION IF NOT EXISTS timescaledb_gpu_bridge;
CREATE EXTENSION IF NOT EXISTS postgis;

-- Verify module loaded
SELECT enabled FROM gpu_bridge_status();

-- Create a small test table with known ECEF POINT Z values
CREATE TEMP TABLE test_ecef (
    id serial,
    ts timestamptz NOT NULL DEFAULT now(),
    geom geometry(PointZ, 4978) NOT NULL,
    value float8 NOT NULL
);

-- Insert known ECEF coordinates (Earth surface at various locations)
INSERT INTO test_ecef (geom, value) VALUES
    (ST_SetSRID(ST_MakePoint(6378137.0, 0.0, 0.0), 4978), 1.0),          -- Equator, prime meridian
    (ST_SetSRID(ST_MakePoint(0.0, 6378137.0, 0.0), 4978), 2.0),          -- Equator, 90E
    (ST_SetSRID(ST_MakePoint(0.0, 0.0, 6356752.3), 4978), 3.0),          -- North pole
    (ST_SetSRID(ST_MakePoint(-6378137.0, 0.0, 0.0), 4978), 4.0),         -- Equator, 180
    (ST_SetSRID(ST_MakePoint(4517590.0, 4517590.0, 0.0), 4978), 5.0);    -- Equator, 45E

-- Verify data inserted correctly
SELECT id, ST_AsText(geom), value FROM test_ecef ORDER BY id;

-- Test: aggregate query over the test data (exercises VectorAgg path)
SELECT
    count(*) AS num_points,
    avg(value) AS avg_value,
    avg(ST_X(geom)) AS avg_x,
    avg(ST_Y(geom)) AS avg_y,
    avg(ST_Z(geom)) AS avg_z
FROM test_ecef;

-- Clean up
DROP TABLE test_ecef;
DROP EXTENSION timescaledb_gpu_bridge;
