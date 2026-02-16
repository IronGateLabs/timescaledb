# Tasks: GPU VectorAgg Integration

## 1. Bridge Module Scaffold

- [x] 1.1 Create extension directory structure (`timescaledb_gpu_bridge/`) with Makefile using PGXS build system
- [x] 1.2 Implement `_PG_init` that discovers TimescaleDB and PG-Strom shared libraries via `dlsym`, sets global `gpu_bridge_enabled` flag
- [x] 1.3 Add GUC parameters: `timescaledb.gpu_transfer_cost_per_byte`, `timescaledb.gpu_launch_overhead`, `timescaledb.gpu_min_batch_rows`
- [x] 1.4 Add no-op fallback path when PG-Strom is absent (all functions return immediately)

## 2. Arrow-to-KDS Conversion

- [x] 2.1 Implement `arrow_batch_to_kds()` for fixed-width columns (int64 timestamptz, float8) using pointer aliasing
- [x] 2.2 Implement geometry column conversion: prepend `xpu_geometry_t` headers to Arrow binary geometry data
- [x] 2.3 Implement validity bitmap transfer (Arrow nullability → KDS null bitmap)
- [x] 2.4 Add KDS-to-partial-aggregate result conversion for GPU output back to VectorAgg format

## 3. GPU Batch Dispatch

- [x] 3.1 Implement GPU eligibility check: walk aggregate expression tree, verify all functions have PG-Strom opcodes
- [x] 3.2 Implement grouping policy wrapper that intercepts batch arrival, checks eligibility, and routes to GPU or CPU
- [x] 3.3 Implement GPU dispatch: submit KDS batch to PG-Strom XPU engine, collect results
- [x] 3.4 Implement CPU fallback on GPU execution failure with DEBUG1 logging

## 4. Cost Model

- [x] 4.1 Implement opcode cost summation: walk expression tree, sum PG-Strom opcode costs per row
- [x] 4.2 Implement GPU cost formula: `gpu_cost = (transfer_bytes * cost_per_byte) + launch_overhead + (rows * opcode_cost_sum / gpu_parallelism)`
- [x] 4.3 Implement auto-calibration: measure first GPU transfer/execution, update shared memory cost parameters
- [x] 4.4 Integrate cost model into VectorAgg planner path generation (CustomPath node for GPU path)
- [x] 4.5 Add EXPLAIN output annotation showing `VectorAgg (GPU)` when GPU path is selected

## 5. Benchmark Harness

- [x] 5.1 Create SQL script for synthetic ECEF dataset generation (100K/500K/1M points, LEO/MEO/GEO orbits)
- [x] 5.2 Create SQL query templates: proximity search, frame conversion aggregate, range-distance, time-bucket spatial aggregate
- [x] 5.3 Implement comparison mode shell script: run each template with GPU enabled vs forced-CPU, collect timing and correctness
- [x] 5.4 Implement baseline persistence to `benchmark/baseline.json` with `--create-baseline` flag
- [x] 5.5 Implement regression detection with `--check-regression` flag (15% threshold, nonzero exit on regression)
- [x] 5.6 Add result correctness verification: diff GPU vs CPU results with 1e-10 relative tolerance

## 6. Testing

- [x] 6.1 Add unit test for Arrow-to-KDS conversion with known ECEF geometry batch
- [x] 6.2 Add unit test for GPU eligibility detection (positive and negative cases)
- [x] 6.3 Add integration test: spatial aggregate on compressed hypertable, verify GPU path selected via EXPLAIN
- [x] 6.4 Add integration test: GPU vs CPU result equivalence for all ECEF/ECI device functions
- [x] 6.5 Add integration test: graceful fallback when PG-Strom is not loaded
