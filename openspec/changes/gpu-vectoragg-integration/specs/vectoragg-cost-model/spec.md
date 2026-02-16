## ADDED Requirements

### Requirement: GPU cost estimation for VectorAgg paths
The VectorAgg planner SHALL estimate GPU execution cost for eligible query plans
using PG-Strom's opcode cost values and device capability metadata.  The cost
model MUST account for: data transfer overhead (host-to-device and
device-to-host), GPU kernel launch latency, per-row computation cost (sum of
opcode costs), and batch size.

#### Scenario: Large batch favours GPU
- **WHEN** a compressed batch contains 10,000+ rows with spatial aggregate
  functions (opcode cost >= 20)
- **THEN** the GPU cost estimate SHALL be lower than the CPU estimate, causing
  the planner to select the GPU path

#### Scenario: Small batch favours CPU
- **WHEN** a compressed batch contains fewer than 1,000 rows
- **THEN** the CPU cost estimate SHALL be lower than the GPU estimate due to
  transfer overhead dominating computation savings, causing the planner to
  select the CPU path

### Requirement: Cost model parameters
The cost model SHALL expose GUC parameters for tuning:
- `timescaledb.gpu_transfer_cost_per_byte` (default: auto-calibrate from
  first GPU transfer)
- `timescaledb.gpu_launch_overhead` (default: auto-calibrate)
- `timescaledb.gpu_min_batch_rows` (default: 0, meaning use cost model;
  nonzero value overrides cost model with a hard threshold)

#### Scenario: User overrides minimum batch size
- **WHEN** `timescaledb.gpu_min_batch_rows` is set to 5000
- **THEN** batches with fewer than 5000 rows SHALL always use the CPU path
  regardless of cost model output

#### Scenario: Auto-calibration on first use
- **WHEN** `timescaledb.gpu_transfer_cost_per_byte` is 0 (default) and a GPU
  batch is first dispatched
- **THEN** the system SHALL measure actual transfer and execution time, update
  the cost parameters in shared memory, and use measured values for subsequent
  cost estimates within the same session

### Requirement: Plan-time path selection
The VectorAgg planner integration SHALL generate both CPU and GPU paths for
eligible queries and let PostgreSQL's cost-based optimizer select the winner.
The GPU path MUST appear as a distinct `CustomPath` node so that EXPLAIN output
shows the selected execution method.

#### Scenario: EXPLAIN shows GPU path
- **WHEN** a user runs `EXPLAIN` on a spatial aggregate query and the GPU path
  is selected
- **THEN** the plan output SHALL include a node labelled `VectorAgg (GPU)` or
  equivalent, with estimated cost reflecting the GPU cost model

#### Scenario: EXPLAIN shows CPU path when GPU is costlier
- **WHEN** a user runs `EXPLAIN` on a query where the CPU path is cheaper
- **THEN** the plan output SHALL show the standard `VectorAgg` node without
  GPU annotation
