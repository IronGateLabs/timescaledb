## Why

TimescaleDB's VectorAgg engine processes compressed columnar batches through
CPU-optimized vectorized aggregation, but the ECEF/ECI spatial workload involves
compute-heavy operations (trig-based frame rotations, 3D distance calculations)
applied uniformly across millions of rows.  PG-Strom can offload these to GPU
when integrated with VectorAgg's batch-oriented data flow, and the device
functions for ECEF/ECI transforms already exist in PG-Strom (Phase 1-3 of the
`ecef-eci-device-functions` change).  Connecting these two systems enables
sub-second spatiotemporal queries on 100M+ point datasets that currently take
minutes on CPU alone.

## What Changes

- Add a GPU dispatch path in VectorAgg's aggregation loop that routes eligible
  batches (spatial aggregates on compressed ECEF/ECI data) to PG-Strom's XPU
  execution engine instead of the CPU vectorized path
- Implement a custom VectorAgg aggregate function (`spatial_agg_gpu`) that
  packages Arrow-format batch data into PG-Strom's `kern_data_store` format
  for GPU transfer
- Add a PG-Strom cost-estimation hook so the VectorAgg planner can compare
  GPU vs CPU paths and choose the cheaper one based on batch size and function
  complexity
- Create benchmark harness and reference datasets (100K-1M ECEF points with
  timestamps) to validate GPU speedup and establish regression baselines
- Wire up the integration as a loadable module that activates only when both
  TimescaleDB and PG-Strom are present (no hard dependency on either)

## Capabilities

### New Capabilities
- `gpu-batch-dispatch`: GPU offload path for VectorAgg batches — routes eligible
  compressed batches through PG-Strom's XPU engine for parallel execution of
  spatial aggregates and frame transforms
- `vectoragg-cost-model`: Cost estimation extension for VectorAgg planner —
  compares GPU vs CPU execution cost based on batch size, function opcode cost,
  and device capabilities to select the optimal path
- `gpu-benchmark-harness`: Benchmark infrastructure for GPU-accelerated spatial
  queries — synthetic dataset generation, query templates, and regression
  baseline collection for ECEF/ECI workloads

### Modified Capabilities
_(none — this is a new integration layer, no existing spec requirements change)_

## Impact

- **Code**: New loadable module under `tsl/src/nodes/vector_agg/gpu/` (or
  standalone extension) — ~500-800 lines of C bridging VectorAgg batch format
  to PG-Strom's `kern_data_store`
- **Dependencies**: Runtime dependency on PG-Strom (optional — module is no-op
  without it); build-time dependency on PG-Strom headers for `kern_data_store`
  and opcode definitions
- **APIs**: No public SQL API changes to TimescaleDB; the GPU path is
  transparent to users (same queries, automatic routing)
- **Testing**: New benchmark suite with 100K+ point datasets; regression tests
  comparing GPU vs CPU result correctness
- **Performance**: Target 5-20x speedup on spatial aggregate queries over
  compressed ECEF/ECI hypertables (dependent on GPU hardware and batch sizes)
