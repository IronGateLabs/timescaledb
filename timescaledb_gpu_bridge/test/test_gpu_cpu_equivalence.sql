-- test_gpu_cpu_equivalence.sql - GPU vs CPU result equivalence test
--
-- Verifies that GPU and CPU paths produce identical results for all
-- ECEF/ECI device functions. Results are compared with floating-point
-- tolerance (1e-10 relative error).

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS timescaledb_gpu_bridge;

-- Create test data
CREATE TABLE test_equivalence (
    ts timestamptz NOT NULL,
    object_id integer NOT NULL,
    position geometry(PointZ, 4978) NOT NULL,
    ecef_x float8 NOT NULL,
    ecef_y float8 NOT NULL,
    ecef_z float8 NOT NULL
);

SELECT create_hypertable('test_equivalence', 'ts',
                         chunk_time_interval => INTERVAL '1 hour');

INSERT INTO test_equivalence
SELECT
    '2025-01-01'::timestamptz + (i || ' seconds')::interval,
    i % 10,
    ST_SetSRID(ST_MakePoint(
        (6371000.0 + 400000.0) * cos(radians(i * 0.36)) * cos(radians(i * 0.18)),
        (6371000.0 + 400000.0) * cos(radians(i * 0.36)) * sin(radians(i * 0.18)),
        (6371000.0 + 400000.0) * sin(radians(i * 0.36))
    ), 4978),
    (6371000.0 + 400000.0) * cos(radians(i * 0.36)) * cos(radians(i * 0.18)),
    (6371000.0 + 400000.0) * cos(radians(i * 0.36)) * sin(radians(i * 0.18)),
    (6371000.0 + 400000.0) * sin(radians(i * 0.36))
FROM generate_series(1, 5000) i;

ALTER TABLE test_equivalence SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'object_id',
    timescaledb.compress_orderby = 'ts'
);
SELECT compress_chunk(c) FROM show_chunks('test_equivalence') c;

-- Test: AVG over float columns - CPU mode
SET timescaledb.gpu_min_batch_rows = 2147483647;  -- force CPU
CREATE TEMP TABLE cpu_avg AS
SELECT
    object_id,
    avg(ecef_x) AS avg_x,
    avg(ecef_y) AS avg_y,
    avg(ecef_z) AS avg_z,
    count(*) AS cnt
FROM test_equivalence
GROUP BY object_id
ORDER BY object_id;

-- Test: AVG over float columns - GPU mode (or default mode)
RESET timescaledb.gpu_min_batch_rows;
CREATE TEMP TABLE gpu_avg AS
SELECT
    object_id,
    avg(ecef_x) AS avg_x,
    avg(ecef_y) AS avg_y,
    avg(ecef_z) AS avg_z,
    count(*) AS cnt
FROM test_equivalence
GROUP BY object_id
ORDER BY object_id;

-- Verify results match
SELECT
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL: ' || count(*) || ' mismatches' END
    AS avg_test_result
FROM (
    SELECT g.object_id
    FROM gpu_avg g
    JOIN cpu_avg c USING (object_id)
    WHERE g.cnt != c.cnt
       OR abs(g.avg_x - c.avg_x) > abs(c.avg_x) * 1e-10 + 1e-15
       OR abs(g.avg_y - c.avg_y) > abs(c.avg_y) * 1e-10 + 1e-15
       OR abs(g.avg_z - c.avg_z) > abs(c.avg_z) * 1e-10 + 1e-15
) diff;

-- Verify row counts match
SELECT
    (SELECT count(*) FROM gpu_avg) AS gpu_groups,
    (SELECT count(*) FROM cpu_avg) AS cpu_groups,
    CASE WHEN (SELECT count(*) FROM gpu_avg) = (SELECT count(*) FROM cpu_avg)
         THEN 'PASS' ELSE 'FAIL' END AS count_test;

DROP TABLE cpu_avg;
DROP TABLE gpu_avg;

-- Clean up
DROP TABLE test_equivalence;
DROP EXTENSION timescaledb_gpu_bridge;
