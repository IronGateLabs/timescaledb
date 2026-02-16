/*
 * cost_model.c - GPU vs CPU cost estimation for VectorAgg paths
 *
 * Implements the cost formula:
 *   gpu_cost = (transfer_bytes * cost_per_byte) + launch_overhead
 *              + (rows * opcode_cost_sum / gpu_parallelism)
 *
 * Opcode costs are retrieved from PG-Strom's device function registry.
 * Transfer cost and launch overhead can be auto-calibrated from measured
 * GPU execution or set manually via GUC parameters.
 */
#include <postgres.h>

#include <nodes/nodeFuncs.h>
#include <nodes/primnodes.h>

#include "cost_model.h"
#include "gpu_bridge.h"

/*
 * Default cost values used when auto-calibration has not yet occurred.
 * These are conservative estimates that favor CPU for small batches.
 */
#define DEFAULT_TRANSFER_COST_PER_BYTE  0.0001
#define DEFAULT_LAUNCH_OVERHEAD         100.0
#define DEFAULT_GPU_PARALLELISM         1024

/*
 * Shared-memory state for auto-calibration results.
 * In this prototype, we use module-level globals since we don't have
 * shared memory infrastructure. A production version would use DSM.
 */
static bool calibration_done = false;
static double calibrated_transfer_cost = 0.0;
static double calibrated_launch_overhead = 0.0;

/*
 * Get the effective transfer cost per byte: user-set GUC > calibrated > default.
 */
static double
effective_transfer_cost(void)
{
	if (gpu_transfer_cost_per_byte > 0.0)
		return gpu_transfer_cost_per_byte;
	if (calibration_done && calibrated_transfer_cost > 0.0)
		return calibrated_transfer_cost;
	return DEFAULT_TRANSFER_COST_PER_BYTE;
}

/*
 * Get the effective launch overhead: user-set GUC > calibrated > default.
 */
static double
effective_launch_overhead(void)
{
	if (gpu_launch_overhead > 0.0)
		return gpu_launch_overhead;
	if (calibration_done && calibrated_launch_overhead > 0.0)
		return calibrated_launch_overhead;
	return DEFAULT_LAUNCH_OVERHEAD;
}

/*
 * Get GPU parallelism from PG-Strom or use default.
 */
static int
effective_gpu_parallelism(void)
{
	if (gpu_bridge_enabled && strom_api.gpu_parallelism != NULL)
	{
		int p = strom_api.gpu_parallelism();
		if (p > 0)
			return p;
	}
	return DEFAULT_GPU_PARALLELISM;
}

double
gpu_sum_opcode_costs(Expr *expr)
{
	if (!gpu_bridge_enabled || strom_api.device_func_lookup == NULL ||
		strom_api.opcode_cost == NULL)
		return 0.0;

	if (expr == NULL)
		return 0.0;

	switch (nodeTag(expr))
	{
		case T_Const:
		case T_Var:
			return 0.0;

		case T_FuncExpr:
		{
			FuncExpr *f = (FuncExpr *) expr;
			double cost = 0.0;

			int opcode = strom_api.device_func_lookup(f->funcid);
			if (opcode > 0)
				cost += strom_api.opcode_cost(opcode);

			ListCell *lc;
			foreach (lc, f->args)
			{
				cost += gpu_sum_opcode_costs((Expr *) lfirst(lc));
			}
			return cost;
		}

		case T_OpExpr:
		{
			OpExpr *o = (OpExpr *) expr;
			double cost = 0.0;

			int opcode = strom_api.device_func_lookup(o->opfuncid);
			if (opcode > 0)
				cost += strom_api.opcode_cost(opcode);

			ListCell *lc;
			foreach (lc, o->args)
			{
				cost += gpu_sum_opcode_costs((Expr *) lfirst(lc));
			}
			return cost;
		}

		case T_Aggref:
		{
			Aggref *agg = (Aggref *) expr;
			double cost = 0.0;

			ListCell *lc;
			foreach (lc, agg->args)
			{
				TargetEntry *te = (TargetEntry *) lfirst(lc);
				cost += gpu_sum_opcode_costs(te->expr);
			}
			return cost;
		}

		default:
			return 0.0;
	}
}

GpuCostEstimate
gpu_estimate_cost(List *agg_exprs, int nrows, int row_width)
{
	GpuCostEstimate est = {0};

	if (!gpu_bridge_enabled || nrows <= 0)
	{
		est.is_valid = false;
		return est;
	}

	/* Check minimum batch rows threshold */
	if (gpu_min_batch_rows > 0 && nrows < gpu_min_batch_rows)
	{
		est.is_valid = false;
		return est;
	}

	/* Sum opcode costs across all aggregate expressions */
	double opcode_cost_sum = 0.0;
	ListCell *lc;
	foreach (lc, agg_exprs)
	{
		opcode_cost_sum += gpu_sum_opcode_costs((Expr *) lfirst(lc));
	}

	if (opcode_cost_sum <= 0.0)
	{
		est.is_valid = false;
		return est;
	}

	/* Transfer cost: bytes to GPU and results back */
	size_t transfer_bytes = (size_t) nrows * row_width * 2;  /* bidirectional */
	est.transfer_cost = transfer_bytes * effective_transfer_cost();

	/* Launch overhead */
	est.launch_cost = effective_launch_overhead();

	/* Compute cost: per-row opcode cost divided by GPU parallelism */
	int parallelism = effective_gpu_parallelism();
	est.compute_cost = (double) nrows * opcode_cost_sum / parallelism;

	est.total_cost = est.transfer_cost + est.launch_cost + est.compute_cost;
	est.is_valid = true;

	return est;
}

void
gpu_calibrate_transfer_cost(size_t bytes_transferred, double elapsed_us)
{
	if (bytes_transferred == 0 || elapsed_us <= 0.0)
		return;

	/*
	 * Convert microseconds to cost units. We use a simple linear model:
	 * cost_per_byte = elapsed_us / bytes_transferred
	 * This assumes cost units are roughly proportional to microseconds.
	 */
	calibrated_transfer_cost = elapsed_us / (double) bytes_transferred;
	calibration_done = true;

	elog(DEBUG1, "gpu_bridge: calibrated transfer cost = %.6f per byte (from %zu bytes in %.1f us)",
		 calibrated_transfer_cost, bytes_transferred, elapsed_us);
}

void
gpu_calibrate_launch_overhead(double elapsed_us, double compute_cost)
{
	double overhead = elapsed_us - compute_cost;
	if (overhead <= 0.0)
		overhead = 1.0;  /* minimum overhead */

	calibrated_launch_overhead = overhead;
	calibration_done = true;

	elog(DEBUG1, "gpu_bridge: calibrated launch overhead = %.1f (from %.1f us elapsed, %.1f compute)",
		 calibrated_launch_overhead, elapsed_us, compute_cost);
}
