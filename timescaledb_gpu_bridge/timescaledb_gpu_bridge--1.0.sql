-- timescaledb_gpu_bridge--1.0.sql
-- Extension SQL for TimescaleDB GPU Bridge

-- This extension is primarily a shared library module loaded via
-- shared_preload_libraries. It does not define SQL-callable functions
-- for normal use. The following function is provided for diagnostics.

CREATE FUNCTION gpu_bridge_status()
RETURNS TABLE (
    enabled boolean,
    pgstrom_detected boolean,
    timescaledb_detected boolean,
    transfer_cost_per_byte double precision,
    launch_overhead double precision,
    min_batch_rows integer
)
AS 'MODULE_PATHNAME', 'gpu_bridge_status'
LANGUAGE C STRICT;

COMMENT ON FUNCTION gpu_bridge_status() IS
    'Returns the current status of the GPU bridge module';
