/*
 * gpu_dispatch.c - GPU batch dispatch and eligibility checking
 *
 * Checks whether an aggregate expression tree is GPU-eligible by verifying
 * all functions have PG-Strom opcodes. Implements the grouping policy
 * wrapper that intercepts batches and routes to GPU or CPU. Handles
 * CPU fallback on GPU execution failure with DEBUG1 logging.
 */
#include <postgres.h>

#include <nodes/nodeFuncs.h>
#include <nodes/primnodes.h>
#include <utils/lsyscache.h>

#include "gpu_dispatch.h"
#include "gpu_bridge.h"
#include "arrow_kds.h"

/*
 * Recursively check if a single expression node is GPU-eligible.
 * An expression is GPU-eligible if:
 * - It's a Const or Var (always eligible)
 * - It's a FuncExpr/OpExpr whose function OID has a PG-Strom device opcode,
 *   AND all arguments are recursively GPU-eligible
 */
bool
gpu_expr_is_eligible(Expr *expr)
{
	if (!gpu_bridge_enabled || strom_api.device_func_lookup == NULL)
		return false;

	if (expr == NULL)
		return true;

	switch (nodeTag(expr))
	{
		case T_Const:
		case T_Var:
			return true;

		case T_FuncExpr:
		{
			FuncExpr *f = (FuncExpr *) expr;
			int opcode = strom_api.device_func_lookup(f->funcid);
			if (opcode <= 0)
			{
				elog(DEBUG2, "gpu_bridge: function OID %u has no GPU opcode", f->funcid);
				return false;
			}

			ListCell *lc;
			foreach (lc, f->args)
			{
				if (!gpu_expr_is_eligible((Expr *) lfirst(lc)))
					return false;
			}
			return true;
		}

		case T_OpExpr:
		{
			OpExpr *o = (OpExpr *) expr;
			int opcode = strom_api.device_func_lookup(o->opfuncid);
			if (opcode <= 0)
			{
				elog(DEBUG2, "gpu_bridge: operator function OID %u has no GPU opcode",
					 o->opfuncid);
				return false;
			}

			ListCell *lc;
			foreach (lc, o->args)
			{
				if (!gpu_expr_is_eligible((Expr *) lfirst(lc)))
					return false;
			}
			return true;
		}

		case T_Aggref:
		{
			/*
			 * For aggregates, check the aggregate's arguments.
			 * The aggregate function itself (SUM, AVG, etc.) runs on CPU after
			 * GPU computes the expression values.
			 */
			Aggref *agg = (Aggref *) expr;
			ListCell *lc;
			foreach (lc, agg->args)
			{
				TargetEntry *te = (TargetEntry *) lfirst(lc);
				if (!gpu_expr_is_eligible(te->expr))
					return false;
			}

			/* Check filter clause if present */
			if (agg->aggfilter != NULL)
			{
				if (!gpu_expr_is_eligible(agg->aggfilter))
					return false;
			}
			return true;
		}

		default:
			elog(DEBUG2, "gpu_bridge: unsupported node type %d for GPU eligibility",
				 (int) nodeTag(expr));
			return false;
	}
}

bool
gpu_check_eligibility(List *agg_exprs)
{
	if (!gpu_bridge_enabled)
		return false;

	if (agg_exprs == NIL)
		return false;

	ListCell *lc;
	foreach (lc, agg_exprs)
	{
		Expr *expr = (Expr *) lfirst(lc);
		if (!gpu_expr_is_eligible(expr))
			return false;
	}

	return true;
}

bool
gpu_dispatch_batch(void *kds_buffer, size_t kds_len,
				   void *result, size_t *result_len)
{
	if (!gpu_bridge_enabled || strom_api.xpu_command == NULL)
	{
		elog(DEBUG1, "gpu_bridge: GPU dispatch not available, falling back to CPU");
		return false;
	}

	int rc = strom_api.xpu_command(kds_buffer, kds_len, result, result_len);
	if (rc != 0)
	{
		elog(DEBUG1, "gpu_bridge: GPU execution failed (rc=%d), falling back to CPU", rc);
		return false;
	}

	return true;
}
