-- Test: gpu_bridge no-op fallback when PG-Strom is not loaded
--
-- Verifies that the module loads cleanly, GUC parameters are accessible,
-- and the status function reports PG-Strom as not detected.

CREATE EXTENSION timescaledb_gpu_bridge;

-- Check the status function reports correctly
SELECT enabled, pgstrom_detected, timescaledb_detected
FROM gpu_bridge_status();

-- Verify GUC parameters are accessible and have defaults
SHOW timescaledb.gpu_transfer_cost_per_byte;
SHOW timescaledb.gpu_launch_overhead;
SHOW timescaledb.gpu_min_batch_rows;

-- Verify we can set GUC parameters
SET timescaledb.gpu_min_batch_rows = 5000;
SHOW timescaledb.gpu_min_batch_rows;

-- Reset
RESET timescaledb.gpu_min_batch_rows;

DROP EXTENSION timescaledb_gpu_bridge;
