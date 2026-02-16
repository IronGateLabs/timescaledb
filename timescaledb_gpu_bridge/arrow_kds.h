/*
 * arrow_kds.h - Arrow-to-KDS batch conversion
 *
 * Converts Arrow C Data Interface batches from TimescaleDB VectorAgg
 * into PG-Strom's kern_data_store (KDS) columnar format.
 */
#pragma once

#include <postgres.h>
#include <compression/arrow_c_data_interface.h>

/*
 * KDS format constants matching PG-Strom's definitions.
 * We define our own copies to avoid compile-time dependency on PG-Strom headers.
 */
#define KDS_FORMAT_COLUMN   4

/*
 * Opaque KDS representation. The actual structure is defined by PG-Strom;
 * we build a byte buffer matching the expected binary layout.
 */
typedef struct KDSBatch
{
	char   *buffer;        /* allocated KDS buffer */
	size_t  buffer_len;    /* total bytes allocated */
	int     ncols;         /* number of columns */
	int     nrows;         /* number of rows */
} KDSBatch;

/*
 * Column descriptor for Arrow-to-KDS conversion.
 */
typedef enum KDSColumnType
{
	KDS_COL_INT8,          /* int64 / timestamptz */
	KDS_COL_FLOAT8,        /* float8 */
	KDS_COL_FLOAT4,        /* float4 */
	KDS_COL_INT4,          /* int32 */
	KDS_COL_INT2,          /* int16 */
	KDS_COL_GEOMETRY       /* geometry (variable-length with xpu_geometry_t header) */
} KDSColumnType;

typedef struct KDSColumnDesc
{
	KDSColumnType  col_type;
	int            attnum;        /* attribute number in the original tuple */
	int            typlen;        /* type length for fixed-width columns */
	bool           typbyval;      /* pass-by-value? */
} KDSColumnDesc;

/*
 * Convert a set of Arrow arrays into a KDS columnar batch.
 *
 * arrow_arrays: array of ArrowArray pointers, one per column
 * col_descs: column type descriptors
 * ncols: number of columns
 * nrows: number of rows in the batch
 *
 * Returns a KDSBatch allocated in CurrentMemoryContext.
 * The caller is responsible for freeing it.
 */
extern KDSBatch *arrow_batch_to_kds(const ArrowArray **arrow_arrays,
									const KDSColumnDesc *col_descs,
									int ncols, int nrows);

/*
 * Free a KDS batch.
 */
extern void kds_batch_free(KDSBatch *batch);

/*
 * Convert GPU result buffer back to VectorAgg partial aggregate format.
 *
 * result_buf: raw result from GPU execution
 * result_len: length of result buffer
 * out_values: output Datum array (one per aggregate)
 * out_nulls: output null flags
 * num_aggs: number of aggregates
 */
extern void kds_result_to_partial_agg(const void *result_buf, size_t result_len,
									  Datum *out_values, bool *out_nulls,
									  int num_aggs);

/*
 * Build an xpu_geometry_t-compatible header for a POINT Z geometry.
 * Returns the total serialized size including header.
 */
extern int build_xpu_geometry_header(char *dest, int32 srid,
									 double x, double y, double z);
