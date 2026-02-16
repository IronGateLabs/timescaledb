/*
 * gpu_bridge.h - TimescaleDB GPU Bridge Module
 *
 * Bridges TimescaleDB VectorAgg with PG-Strom GPU execution.
 * Discovers both libraries at runtime via dlsym; no-op when PG-Strom absent.
 */
#pragma once

#include <postgres.h>
#include <fmgr.h>
#include <stdbool.h>

/*
 * Global flag: true only when both TimescaleDB and PG-Strom are discovered.
 */
extern bool gpu_bridge_enabled;

/*
 * PG-Strom function pointers discovered at runtime via dlsym.
 * NULL when PG-Strom is not loaded.
 */
typedef struct GpuBridgeStromAPI
{
	/*
	 * pgstrom_xpu_command - submit a KDS batch for GPU execution
	 * Signature: int (*)(void *kds, size_t kds_len, void *result, size_t *result_len)
	 */
	int (*xpu_command)(void *kds, size_t kds_len, void *result, size_t *result_len);

	/*
	 * pgstrom_device_func_lookup - check if a function OID has a GPU opcode
	 * Signature: int (*)(Oid func_oid)
	 * Returns opcode > 0 if supported, 0 if not.
	 */
	int (*device_func_lookup)(Oid func_oid);

	/*
	 * pgstrom_opcode_cost - get cost weight for a PG-Strom opcode
	 * Signature: double (*)(int opcode)
	 */
	double (*opcode_cost)(int opcode);

	/*
	 * pgstrom_gpu_parallelism - get number of GPU threads available
	 * Signature: int (*)(void)
	 */
	int (*gpu_parallelism)(void);
} GpuBridgeStromAPI;

extern GpuBridgeStromAPI strom_api;

/*
 * GUC parameters
 */
extern double gpu_transfer_cost_per_byte;
extern double gpu_launch_overhead;
extern int gpu_min_batch_rows;
