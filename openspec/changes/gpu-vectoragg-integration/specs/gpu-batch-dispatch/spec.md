## ADDED Requirements

### Requirement: GPU-eligible batch detection
The VectorAgg execution engine SHALL identify compressed batches eligible for
GPU dispatch based on the presence of PG-Strom-registered device functions in
the aggregate expression tree.  A batch is GPU-eligible when ALL aggregate
functions and filter expressions in the query have corresponding PG-Strom
opcode registrations.

#### Scenario: Batch with all GPU-supported functions
- **WHEN** a VectorAgg batch contains only aggregates over functions registered
  in PG-Strom's `xpu_opcodes.h` (e.g., `ST_3DDistance`, `ST_ECEF_To_ECI`)
- **THEN** the batch SHALL be marked as GPU-eligible

#### Scenario: Batch with mixed GPU and CPU-only functions
- **WHEN** a VectorAgg batch contains at least one aggregate function without a
  PG-Strom opcode registration
- **THEN** the batch SHALL NOT be marked as GPU-eligible and SHALL execute
  entirely on the CPU vectorized path

### Requirement: Arrow-to-KDS batch conversion
The GPU dispatch path SHALL convert Arrow C Data Interface batch data from
VectorAgg's columnar format into PG-Strom's `kern_data_store` (KDS) format
for GPU transfer.  The conversion MUST handle geometry columns (serialized
LWGEOM), timestamptz columns (int64 microseconds), and float8 columns without
data loss or alignment violations.

#### Scenario: ECEF geometry batch conversion
- **WHEN** a GPU-eligible batch contains a geometry column with POINT Z values
  (SRID 4978)
- **THEN** the converter SHALL produce a KDS column with correctly serialized
  `xpu_geometry_t` values matching PG-Strom's expected layout (type, flags,
  srid, nitems, rawsize, rawdata)

#### Scenario: Timestamptz batch conversion
- **WHEN** a GPU-eligible batch contains a timestamptz column
- **THEN** the converter SHALL produce a KDS column with int64 microsecond
  values since PostgreSQL epoch (2000-01-01 00:00:00 UTC), matching
  PG-Strom's `xpu_timestamptz_t` format

### Requirement: GPU batch execution
The GPU dispatch path SHALL submit converted KDS batches to PG-Strom's XPU
execution engine and collect results.  Execution MUST be asynchronous per batch
to overlap GPU computation with CPU decompression of subsequent batches.

#### Scenario: Successful GPU execution
- **WHEN** a GPU-eligible batch is submitted to PG-Strom's XPU engine
- **THEN** the dispatch path SHALL return partial aggregate results in the same
  format as the CPU vectorized path (compatible with VectorAgg's result merging)

#### Scenario: GPU execution failure with CPU fallback
- **WHEN** a GPU batch execution fails (device error, out-of-memory, or
  PG-Strom's `cpu_fallback` triggered)
- **THEN** the dispatch path SHALL re-execute the batch on the CPU vectorized
  path and log a DEBUG1-level message indicating the fallback

### Requirement: No-op when PG-Strom absent
The GPU dispatch module SHALL be a no-op when PG-Strom is not loaded.  It MUST
NOT cause errors, warnings, or performance degradation when PG-Strom is not
installed.

#### Scenario: Module loaded without PG-Strom
- **WHEN** the GPU dispatch module is loaded but PG-Strom's shared library is
  not present in `shared_preload_libraries`
- **THEN** all batches SHALL execute on the CPU vectorized path with zero
  additional overhead (no function pointer indirection per row)
