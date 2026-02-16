## ADDED Requirements

### Requirement: Synthetic dataset generation
The benchmark harness SHALL generate synthetic ECEF point datasets with
configurable size (default 100K, 500K, 1M rows), realistic orbital parameters
(LEO, MEO, GEO altitude bands), and associated timestamps spanning a
configurable time range.  Data SHALL be inserted into a TimescaleDB hypertable
with appropriate compression settings.

#### Scenario: Generate 100K-point LEO dataset
- **WHEN** the harness is invoked with `--size 100000 --orbit LEO --timespan 24h`
- **THEN** it SHALL create a compressed hypertable containing 100,000 ECEF POINT
  Z geometries (SRID 4978) with timestamps distributed over 24 hours, positions
  following realistic LEO orbital tracks (altitude 200-2000 km)

#### Scenario: Generate multi-orbit mixed dataset
- **WHEN** the harness is invoked with `--size 1000000 --orbit mixed`
- **THEN** it SHALL create 1M points distributed across LEO (60%), MEO (25%),
  and GEO (15%) altitude bands with distinct object IDs per orbit

### Requirement: Query template library
The benchmark harness SHALL include a library of parameterised SQL query
templates covering the primary ECEF/ECI spatial workload patterns:
- Proximity search: `ST_3DDWithin` over a time window
- Frame conversion aggregate: `ST_ECEF_To_ECI` with `AVG` over coordinate
  components
- Range scan with distance: `ST_3DDistance` between object pairs
- Time-series spatial aggregate: grouped by time bucket with spatial functions

#### Scenario: Run proximity benchmark
- **WHEN** the harness executes the proximity query template against a 100K
  dataset
- **THEN** it SHALL record wall-clock time, rows processed, and whether the
  GPU or CPU path was used (from EXPLAIN ANALYZE output)

### Requirement: GPU vs CPU comparison mode
The benchmark harness SHALL support a comparison mode that runs each query
template twice — once with GPU dispatch enabled and once with
`timescaledb.gpu_min_batch_rows = 2147483647` (forcing CPU) — and reports the
speedup ratio, result correctness (diff), and resource usage.

#### Scenario: Comparison run produces speedup report
- **WHEN** the harness runs in comparison mode on a 500K dataset
- **THEN** it SHALL output a table with columns: query name, CPU time (ms),
  GPU time (ms), speedup ratio, result match (boolean), and peak GPU memory

#### Scenario: Result mismatch detection
- **WHEN** a GPU query produces results that differ from the CPU query beyond
  floating-point tolerance (1e-10 relative error)
- **THEN** the harness SHALL flag the query as FAILED and output the first
  divergent row for debugging

### Requirement: Regression baseline persistence
The benchmark harness SHALL persist baseline results to a JSON file so that
future runs can detect performance regressions.  A regression is flagged when
any query's median time exceeds the baseline by more than 15%.

#### Scenario: Baseline creation
- **WHEN** the harness is run with `--create-baseline`
- **THEN** it SHALL write median timings for all query templates to
  `benchmark/baseline.json`

#### Scenario: Regression detection
- **WHEN** the harness is run with `--check-regression` and a query's median
  time exceeds the baseline by more than 15%
- **THEN** it SHALL exit with a nonzero status and print the regressed queries
  with actual vs baseline timings
