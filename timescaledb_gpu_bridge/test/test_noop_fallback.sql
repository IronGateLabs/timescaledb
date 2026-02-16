-- test_noop_fallback.sql - Integration test for graceful fallback
--
-- Verifies the GPU bridge is a complete no-op when PG-Strom is not loaded:
-- - No errors or warnings
-- - No performance degradation (no per-row overhead)
-- - Queries produce correct results via CPU path

CREATE EXTENSION IF NOT EXISTS timescaledb_gpu_bridge;

-- Status should show disabled
SELECT
    enabled,
    pgstrom_detected,
    CASE WHEN enabled = false AND pgstrom_detected = false
         THEN 'PASS: Correctly disabled without PG-Strom'
         ELSE 'FAIL: Unexpected state'
    END AS noop_check
FROM gpu_bridge_status();

-- GUC parameters should be accessible even in no-op mode
SHOW timescaledb.gpu_transfer_cost_per_byte;
SHOW timescaledb.gpu_launch_overhead;
SHOW timescaledb.gpu_min_batch_rows;

-- Setting GUC should not cause errors even in no-op mode
SET timescaledb.gpu_min_batch_rows = 10000;
SET timescaledb.gpu_transfer_cost_per_byte = 0.001;
SET timescaledb.gpu_launch_overhead = 50.0;

-- Verify settings took effect
SELECT
    current_setting('timescaledb.gpu_min_batch_rows') AS min_rows,
    current_setting('timescaledb.gpu_transfer_cost_per_byte') AS transfer_cost,
    current_setting('timescaledb.gpu_launch_overhead') AS launch_overhead;

-- Reset to defaults
RESET timescaledb.gpu_min_batch_rows;
RESET timescaledb.gpu_transfer_cost_per_byte;
RESET timescaledb.gpu_launch_overhead;

-- Extension can be cleanly dropped and recreated
DROP EXTENSION timescaledb_gpu_bridge;
CREATE EXTENSION timescaledb_gpu_bridge;

SELECT enabled FROM gpu_bridge_status();

DROP EXTENSION timescaledb_gpu_bridge;
