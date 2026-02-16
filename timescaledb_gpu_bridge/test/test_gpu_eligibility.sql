-- test_gpu_eligibility.sql - Unit test for GPU eligibility detection
--
-- Tests positive and negative cases for GPU eligibility checking.
-- Without PG-Strom loaded, all eligibility checks should return false (no-op).

CREATE EXTENSION IF NOT EXISTS timescaledb_gpu_bridge;

-- Verify module loaded in no-op mode
SELECT enabled, pgstrom_detected FROM gpu_bridge_status();

-- In no-op mode (PG-Strom absent), GPU eligibility should always be false.
-- The bridge does not expose a direct SQL function for eligibility checking,
-- but we can verify via EXPLAIN that no GPU path is selected.

-- Create a test table
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE test_eligibility (
    ts timestamptz NOT NULL,
    obj_id integer NOT NULL,
    position geometry(PointZ, 4978),
    value float8
);

SELECT create_hypertable('test_eligibility', 'ts');

INSERT INTO test_eligibility
SELECT
    '2025-01-01'::timestamptz + (i || ' seconds')::interval,
    i % 10,
    ST_SetSRID(ST_MakePoint(6378137.0 * cos(i), 6378137.0 * sin(i), 0.0), 4978),
    random()
FROM generate_series(1, 1000) i;

-- Enable and run compression
ALTER TABLE test_eligibility SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'obj_id',
    timescaledb.compress_orderby = 'ts'
);
SELECT compress_chunk(c) FROM show_chunks('test_eligibility') c;

-- This should use standard VectorAgg (no GPU annotation)
EXPLAIN (VERBOSE)
SELECT obj_id, avg(value) FROM test_eligibility GROUP BY obj_id;

-- A spatial query should also not select GPU path without PG-Strom
EXPLAIN (VERBOSE)
SELECT avg(ST_X(position)) FROM test_eligibility;

-- Clean up
DROP TABLE test_eligibility;
DROP EXTENSION timescaledb_gpu_bridge;
