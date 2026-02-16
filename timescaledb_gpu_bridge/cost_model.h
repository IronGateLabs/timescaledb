/*
 * cost_model.h - GPU vs CPU cost estimation for VectorAgg paths
 *
 * Estimates GPU execution cost using PG-Strom opcode costs and device
 * metadata, enabling the VectorAgg planner to choose between GPU and
 * CPU paths.
 */
#pragma once

#include <postgres.h>
#include <nodes/primnodes.h>

/*
 * Cost estimate result for a GPU execution path.
 */
typedef struct GpuCostEstimate
{
	double total_cost;         /* total estimated cost */
	double transfer_cost;      /* host-to-device + device-to-host transfer */
	double launch_cost;        /* GPU kernel launch overhead */
	double compute_cost;       /* per-row computation cost */
	bool   is_valid;           /* false if cost cannot be estimated */
} GpuCostEstimate;

/*
 * Estimate GPU execution cost for an aggregate expression over a batch.
 *
 * agg_exprs: list of aggregate expressions
 * nrows: number of rows in the batch
 * row_width: estimated average row width in bytes
 */
extern GpuCostEstimate gpu_estimate_cost(List *agg_exprs, int nrows, int row_width);

/*
 * Sum PG-Strom opcode costs for all functions in an expression tree.
 * Returns the per-row opcode cost sum.
 */
extern double gpu_sum_opcode_costs(Expr *expr);

/*
 * Auto-calibrate transfer cost by measuring actual GPU transfer time.
 * Called after the first GPU batch execution.
 *
 * bytes_transferred: total bytes sent to/from GPU
 * elapsed_us: measured wall-clock time in microseconds
 */
extern void gpu_calibrate_transfer_cost(size_t bytes_transferred, double elapsed_us);

/*
 * Auto-calibrate launch overhead from measured GPU execution.
 *
 * elapsed_us: measured kernel launch + execution time in microseconds
 * compute_cost: estimated computation cost (to subtract)
 */
extern void gpu_calibrate_launch_overhead(double elapsed_us, double compute_cost);
