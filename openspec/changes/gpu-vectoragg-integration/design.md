## Context

TimescaleDB's VectorAgg engine (`tsl/src/nodes/vector_agg/`) processes
compressed columnar batches through CPU-optimized vectorized aggregation.
The execution flow is:

1. **ColumnarScan** decompresses chunks into Arrow C Data Interface batches
2. **VectorAgg** applies grouping policies (batch or hash) to accumulate
   aggregate states across batches
3. Aggregate functions dispatch per-row via function pointers in
   `tsl/src/nodes/vector_agg/function/`

PG-Strom (`/home/e/Development/pg-strom`) intercepts SQL expressions at
plan time, translates them to opcode sequences, and dispatches them to GPU
threads (one thread per row).  The `feature/ecef-eci-device-functions` branch
already has device implementations for `ST_ECEF_To_ECI`, `ST_ECI_To_ECEF`,
`ST_ECEF_X/Y/Z`, `ST_3DDistance`, and `ST_3DDWithin`.

The integration challenge is bridging VectorAgg's Arrow-format batch pipeline
to PG-Strom's `kern_data_store` (KDS) format without breaking either system's
assumptions about data ownership and memory lifecycle.

## Goals / Non-Goals

**Goals:**
- Route GPU-eligible VectorAgg batches to PG-Strom's XPU engine for spatial
  aggregate acceleration
- Maintain full CPU fallback — queries produce identical results whether
  executed on GPU or CPU
- Provide cost-based path selection so the planner automatically picks the
  faster path per query
- Deliver a benchmark harness that proves the integration works and quantifies
  speedup on realistic ECEF/ECI workloads

**Non-Goals:**
- Modifying PG-Strom's core XPU execution engine (we use it as-is)
- Modifying TimescaleDB's compression or decompression algorithms
- Supporting non-POINT geometry types on GPU (POINT-only, matching PG-Strom's
  device function limitations)
- GPU-accelerating non-spatial aggregates (SUM, AVG on scalars stay on CPU
  vectorized path)
- Production deployment hardening (this is research/prototype quality)

## Decisions

### 1. Integration as a separate loadable module

**Decision:** Build the GPU dispatch layer as a standalone PostgreSQL extension
(`timescaledb_gpu_bridge`) rather than patching TimescaleDB or PG-Strom
directly.

**Rationale:** Both TimescaleDB (TSL) and PG-Strom have their own release
cycles and build systems (CMake vs Make).  A bridge module avoids coupling them.
It loads via `shared_preload_libraries`, discovers both libraries at runtime via
`dlsym`, and installs hooks into VectorAgg's execution path.

**Alternatives considered:**
- *Patch VectorAgg directly*: Rejected — would fork TimescaleDB and require
  ongoing merge maintenance
- *PG-Strom plugin*: Rejected — PG-Strom's plugin API is oriented toward
  adding new device functions, not intercepting another extension's execution

### 2. Hook point: VectorAgg grouping policy

**Decision:** Register a custom grouping policy that wraps the existing batch
or hash policy.  When a batch arrives, the wrapper checks GPU eligibility,
converts to KDS if eligible, dispatches to GPU, and falls back to the wrapped
policy on failure.

**Rationale:** VectorAgg's grouping policy interface
(`grouping_policy_batch.c`, `grouping_policy_hash.c`) is the natural
interception point — it receives complete Arrow batches and returns partial
aggregate states.  Wrapping preserves the existing policy's correctness as a
fallback.

**Alternatives considered:**
- *Hook at ColumnarScan level*: Rejected — too early, doesn't have aggregate
  context
- *Hook at PostgreSQL executor level*: Rejected — too late, VectorAgg has
  already consumed the batch

### 3. Arrow-to-KDS batch conversion strategy

**Decision:** Convert Arrow batches to PG-Strom's KDS_FORMAT_COLUMN layout
using a zero-copy approach where possible (share underlying buffers) and
memcpy for geometry columns that need re-serialization.

**Rationale:** Arrow and KDS_FORMAT_COLUMN are both columnar, so fixed-width
columns (int64 timestamps, float8 values) can share the same buffer pointer.
Geometry columns need conversion because Arrow stores them as variable-length
binary while PG-Strom expects `xpu_geometry_t` with inline metadata (type,
flags, srid, nitems).

**Data flow:**
```
Arrow batch (from ColumnarScan)
  │
  ├─ fixed-width columns → pointer aliasing into KDS column slots
  ├─ geometry columns    → memcpy with xpu_geometry_t header prepend
  └─ validity bitmaps    → direct copy (Arrow and KDS use same format)
  │
  v
kern_data_store (KDS_FORMAT_COLUMN)
  │
  v
PG-Strom XPU engine → GPU kernel execution
  │
  v
Result buffer → convert back to VectorAgg partial aggregate state
```

### 4. Asynchronous batch pipelining

**Decision:** Use PG-Strom's async execution API to overlap GPU computation
of batch N with CPU decompression of batch N+1.

**Rationale:** GPU transfer and kernel launch have fixed latency (~50-200 us).
Overlapping with decompression hides this latency.  VectorAgg already processes
batches sequentially, so we maintain a 1-batch lookahead buffer.

### 5. Cost model based on PG-Strom opcode costs

**Decision:** Sum PG-Strom opcode costs from `xpu_opcodes.h` per row, multiply
by batch size, add measured transfer overhead.  Compare against VectorAgg's
CPU cost (already estimated by the planner).

**Rationale:** PG-Strom already assigns per-function costs (e.g., ECI
transforms = 20, coordinate accessors = 5).  These are proportional to actual
GPU kernel time.  The transfer overhead is auto-calibrated on first use.

### 6. Benchmark as SQL + shell scripts

**Decision:** Implement the benchmark harness as a set of SQL scripts
(dataset generation, query templates) and a shell wrapper that runs them with
`pgbench` or `psql` timing, collects results to JSON.

**Rationale:** Keeps the benchmark portable and easy to run in CI or manually.
No custom C code needed for benchmarking.  SQL scripts double as documentation
of the supported query patterns.

## Risks / Trade-offs

- **[Risk] Arrow-to-KDS conversion overhead negates GPU speedup for small
  batches** → Mitigation: Cost model includes conversion cost; `gpu_min_batch_rows`
  GUC provides a hard floor.  Benchmark harness will quantify the crossover
  point.

- **[Risk] PG-Strom API instability** → Mitigation: Pin to a specific PG-Strom
  release tag.  The bridge module isolates API surface to `kern_data_store`
  construction and `pgstrom_xpu_*` execution functions.

- **[Risk] Memory pressure from double-buffering (Arrow + KDS)** →
  Mitigation: Use pointer aliasing for fixed-width columns to avoid copies.
  Geometry conversion is per-batch and freed after GPU returns.

- **[Risk] GPU device function coverage gaps** → Mitigation: Any unsupported
  function causes graceful fallback to CPU.  Phase 4 PG-Strom tests (pending)
  will verify all device functions produce correct results.

- **[Trade-off] Prototype quality vs production hardening** → Accepted: This
  integration is research-grade.  Error handling covers the critical paths
  (fallback on failure) but does not handle edge cases like mid-query GPU
  hot-unplug or concurrent GPU memory exhaustion from other processes.

## Open Questions

1. **VectorAgg grouping policy extensibility**: Does TimescaleDB's grouping
   policy interface support external registration, or does the bridge module
   need to patch the function pointer table at load time?  Need to inspect
   `grouping_policy_batch.c` registration path.

2. **KDS_FORMAT_COLUMN geometry layout**: PG-Strom's geometry column handling
   in KDS may differ from its tuple-based layout.  Need to verify against
   `xpu_postgis.cu`'s `KEXP_PROCESS_ARGS` expectations for columnar format.

3. **Async execution API availability**: PG-Strom's async API may be internal.
   If not exposed, synchronous dispatch is the fallback (still beneficial for
   large batches, just no pipelining benefit).
