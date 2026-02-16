-- verify_correctness.sql - GPU vs CPU result equivalence verification
--
-- Runs queries in both GPU and CPU modes and compares results
-- with floating-point tolerance (1e-10 relative error).

-- Helper function for relative error comparison
CREATE OR REPLACE FUNCTION check_relative_error(gpu_val float8, cpu_val float8, tolerance float8)
RETURNS boolean AS $$
BEGIN
    IF cpu_val = 0.0 THEN
        RETURN abs(gpu_val) < tolerance;
    END IF;
    RETURN abs((gpu_val - cpu_val) / cpu_val) < tolerance;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

-- Test 1: Time-bucket spatial aggregate equivalence
\echo 'Test 1: Time-bucket spatial aggregate'

-- CPU mode results
SET timescaledb.gpu_min_batch_rows = 2147483647;
CREATE TEMP TABLE cpu_results AS
SELECT
    time_bucket('5 minutes', ts) AS bucket,
    count(*) AS num_points,
    avg(ecef_x) AS avg_x,
    avg(ecef_y) AS avg_y,
    avg(ecef_z) AS avg_z
FROM benchmark_ecef_points
WHERE ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 06:00:00+00'
GROUP BY bucket
ORDER BY bucket;

-- GPU mode results
RESET timescaledb.gpu_min_batch_rows;
CREATE TEMP TABLE gpu_results AS
SELECT
    time_bucket('5 minutes', ts) AS bucket,
    count(*) AS num_points,
    avg(ecef_x) AS avg_x,
    avg(ecef_y) AS avg_y,
    avg(ecef_z) AS avg_z
FROM benchmark_ecef_points
WHERE ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 06:00:00+00'
GROUP BY bucket
ORDER BY bucket;

-- Compare
SELECT
    CASE
        WHEN count(*) = 0 THEN 'PASS: All results match within tolerance'
        ELSE 'FAIL: ' || count(*) || ' rows differ'
    END AS test1_result
FROM (
    SELECT g.bucket
    FROM gpu_results g
    JOIN cpu_results c ON g.bucket = c.bucket
    WHERE g.num_points != c.num_points
       OR NOT check_relative_error(g.avg_x, c.avg_x, 1e-10)
       OR NOT check_relative_error(g.avg_y, c.avg_y, 1e-10)
       OR NOT check_relative_error(g.avg_z, c.avg_z, 1e-10)
) divergent;

-- Show first divergent row if any
SELECT 'First divergent row:' AS info, g.*, c.*
FROM gpu_results g
JOIN cpu_results c ON g.bucket = c.bucket
WHERE g.num_points != c.num_points
   OR NOT check_relative_error(g.avg_x, c.avg_x, 1e-10)
   OR NOT check_relative_error(g.avg_y, c.avg_y, 1e-10)
   OR NOT check_relative_error(g.avg_z, c.avg_z, 1e-10)
LIMIT 1;

-- Row count check
SELECT
    (SELECT count(*) FROM gpu_results) AS gpu_rows,
    (SELECT count(*) FROM cpu_results) AS cpu_rows,
    CASE
        WHEN (SELECT count(*) FROM gpu_results) = (SELECT count(*) FROM cpu_results)
        THEN 'PASS: Row counts match'
        ELSE 'FAIL: Row count mismatch'
    END AS row_count_check;

DROP TABLE cpu_results;
DROP TABLE gpu_results;

-- Clean up helper
DROP FUNCTION check_relative_error(float8, float8, float8);
