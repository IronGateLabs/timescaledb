/*
 * gpu_dispatch.h - GPU batch dispatch and eligibility checking
 *
 * Determines whether a VectorAgg batch is eligible for GPU execution,
 * wraps the grouping policy for GPU dispatch, and handles CPU fallback.
 */
#pragma once

#include <postgres.h>
#include <nodes/primnodes.h>

/*
 * Check if all functions in an aggregate expression tree have PG-Strom
 * GPU opcodes. Returns true if the entire expression is GPU-eligible.
 */
extern bool gpu_check_eligibility(List *agg_exprs);

/*
 * Check a single expression node recursively.
 */
extern bool gpu_expr_is_eligible(Expr *expr);

/*
 * Submit a batch to the GPU via PG-Strom's XPU engine.
 * On failure, returns false and the caller should fall back to CPU.
 *
 * kds_buffer: the KDS batch to execute
 * kds_len: length of the KDS buffer
 * result: output buffer for results
 * result_len: in/out parameter for result buffer length
 */
extern bool gpu_dispatch_batch(void *kds_buffer, size_t kds_len,
							   void *result, size_t *result_len);
