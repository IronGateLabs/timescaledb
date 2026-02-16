/*
 * gpu_bridge.c - TimescaleDB GPU Bridge Module entry point
 *
 * Discovers TimescaleDB and PG-Strom shared libraries at load time via dlsym.
 * Registers GUC parameters for cost model tuning. When PG-Strom is absent,
 * all GPU paths are disabled and execution falls through to CPU.
 */
#include <postgres.h>

#include <dlfcn.h>
#include <fmgr.h>
#include <funcapi.h>
#include <miscadmin.h>
#include <utils/builtins.h>
#include <utils/guc.h>

#include "gpu_bridge.h"
#include "gpu_dispatch.h"
#include "cost_model.h"

PG_MODULE_MAGIC;

/* Global state */
bool gpu_bridge_enabled = false;
GpuBridgeStromAPI strom_api = {0};

/* GUC parameters */
double gpu_transfer_cost_per_byte = 0.0;   /* 0 = auto-calibrate */
double gpu_launch_overhead = 0.0;          /* 0 = auto-calibrate */
int gpu_min_batch_rows = 0;                /* 0 = use cost model */

/*
 * Attempt to resolve a symbol from any loaded shared library.
 * Returns NULL if the symbol is not found.
 */
static void *
resolve_symbol(const char *symbol_name)
{
	void *sym = dlsym(RTLD_DEFAULT, symbol_name);
	if (sym == NULL)
	{
		elog(DEBUG1, "gpu_bridge: symbol '%s' not found: %s", symbol_name, dlerror());
	}
	return sym;
}

/*
 * Discover PG-Strom runtime API via dlsym.
 * Returns true if all required symbols were found.
 */
static bool
discover_pgstrom(void)
{
	strom_api.xpu_command = (int (*)(void *, size_t, void *, size_t *))
		resolve_symbol("pgstrom_xpu_command");
	strom_api.device_func_lookup = (int (*)(Oid))
		resolve_symbol("pgstrom_device_func_lookup");
	strom_api.opcode_cost = (double (*)(int))
		resolve_symbol("pgstrom_opcode_cost");
	strom_api.gpu_parallelism = (int (*)(void))
		resolve_symbol("pgstrom_gpu_parallelism");

	if (strom_api.xpu_command == NULL ||
		strom_api.device_func_lookup == NULL ||
		strom_api.opcode_cost == NULL ||
		strom_api.gpu_parallelism == NULL)
	{
		/* Reset all pointers if any are missing */
		memset(&strom_api, 0, sizeof(strom_api));
		return false;
	}

	return true;
}

/*
 * Check if TimescaleDB is loaded by looking for a known symbol.
 */
static bool
discover_timescaledb(void)
{
	void *sym = dlsym(RTLD_DEFAULT, "ts_extension_is_loaded");
	if (sym == NULL)
	{
		elog(DEBUG1, "gpu_bridge: TimescaleDB not detected");
		return false;
	}
	return true;
}

/*
 * Register GUC parameters for the GPU bridge.
 */
static void
register_gucs(void)
{
	DefineCustomRealVariable(
		"timescaledb.gpu_transfer_cost_per_byte",
		"Cost per byte for GPU data transfer",
		"Set to 0 for auto-calibration on first GPU execution. "
		"Units are arbitrary cost units matching PostgreSQL's cost model.",
		&gpu_transfer_cost_per_byte,
		0.0,    /* default */
		0.0,    /* min */
		1.0e6,  /* max */
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomRealVariable(
		"timescaledb.gpu_launch_overhead",
		"Fixed overhead cost for GPU kernel launch",
		"Set to 0 for auto-calibration on first GPU execution. "
		"Units are arbitrary cost units.",
		&gpu_launch_overhead,
		0.0,    /* default */
		0.0,    /* min */
		1.0e9,  /* max */
		PGC_USERSET,
		0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		"timescaledb.gpu_min_batch_rows",
		"Minimum batch rows for GPU dispatch",
		"Batches with fewer rows than this always use CPU. "
		"Set to 0 to let the cost model decide.",
		&gpu_min_batch_rows,
		0,          /* default */
		0,          /* min */
		INT_MAX,    /* max */
		PGC_USERSET,
		0,
		NULL, NULL, NULL);
}

/*
 * Module initialization entry point.
 */
void
_PG_init(void)
{
	register_gucs();

	timescaledb_detected = discover_timescaledb();
	if (!timescaledb_detected)
	{
		elog(LOG, "gpu_bridge: TimescaleDB not loaded, GPU dispatch disabled");
		return;
	}

	pgstrom_detected = discover_pgstrom();
	if (!pgstrom_detected)
	{
		elog(LOG, "gpu_bridge: PG-Strom not loaded, GPU dispatch disabled");
		return;
	}

	gpu_bridge_enabled = true;
	elog(LOG, "gpu_bridge: TimescaleDB and PG-Strom detected, GPU dispatch enabled");
}

/* Track discovery results for status function */
static bool timescaledb_detected = false;
static bool pgstrom_detected = false;

/*
 * SQL-callable status function for diagnostics.
 */
PG_FUNCTION_INFO_V1(gpu_bridge_status);
Datum
gpu_bridge_status(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	TupleDesc tupdesc;
	Datum values[6];
	bool nulls[6] = {false};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function returning record called in context that cannot accept type record")));

	tupdesc = BlessTupleDesc(tupdesc);

	values[0] = BoolGetDatum(gpu_bridge_enabled);
	values[1] = BoolGetDatum(pgstrom_detected);
	values[2] = BoolGetDatum(timescaledb_detected);
	values[3] = Float8GetDatum(gpu_transfer_cost_per_byte);
	values[4] = Float8GetDatum(gpu_launch_overhead);
	values[5] = Int32GetDatum(gpu_min_batch_rows);

	HeapTuple tuple = heap_form_tuple(tupdesc, values, nulls);
	PG_RETURN_DATUM(HeapTupleGetDatum(tuple));
}
