/*
 * arrow_kds.c - Arrow-to-KDS batch conversion
 *
 * Converts Arrow C Data Interface columnar batches into PG-Strom's
 * kern_data_store (KDS_FORMAT_COLUMN) layout for GPU transfer.
 *
 * Fixed-width columns use pointer aliasing (zero-copy) when possible.
 * Geometry columns require serialization with xpu_geometry_t headers.
 * Validity bitmaps are copied directly (Arrow and KDS use the same format).
 */
#include <postgres.h>

#include <utils/memutils.h>

#include "arrow_kds.h"
#include "gpu_bridge.h"

/*
 * KDS header layout (matches PG-Strom's kern_data_store for KDS_FORMAT_COLUMN).
 * We build this in a flat byte buffer rather than including PG-Strom headers.
 *
 * Offsets are derived from PG-Strom's kern_data_store definition:
 *   uint32  length          @ 0
 *   uint16  format          @ 4    (KDS_FORMAT_COLUMN = 4)
 *   uint16  ncols           @ 6
 *   uint32  nrooms          @ 8    (capacity in rows)
 *   uint32  nitems          @ 12   (actual rows)
 *   uint32  col_offset[ncols] @ 16 (byte offset from buffer start to each column)
 */
#define KDS_HDR_LENGTH_OFF     0
#define KDS_HDR_FORMAT_OFF     4
#define KDS_HDR_NCOLS_OFF      6
#define KDS_HDR_NROOMS_OFF     8
#define KDS_HDR_NITEMS_OFF     12
#define KDS_HDR_COL_OFFSETS    16

#define KDS_HEADER_SIZE(ncols)  MAXALIGN(KDS_HDR_COL_OFFSETS + (ncols) * sizeof(uint32))

/*
 * Per-column data layout in KDS_FORMAT_COLUMN:
 *   validity bitmap (64-bit words, same as Arrow)
 *   data values (fixed-width) or offsets+data (variable-width)
 */

static size_t
validity_bitmap_bytes(int nrows)
{
	return MAXALIGN(((nrows + 63) / 64) * sizeof(uint64));
}

static size_t
fixed_column_bytes(int nrows, int typlen)
{
	return validity_bitmap_bytes(nrows) + MAXALIGN((size_t) nrows * typlen);
}

/*
 * Estimate the size of a geometry column in KDS format.
 * xpu_geometry_t header per POINT Z: 24 bytes (type, flags, srid, nitems, rawsize, rawdata ptr)
 * plus 24 bytes of coordinate data (3 float8).
 * Total per row ~48 bytes. We add bitmap overhead.
 */
#define XPU_GEOM_POINT_Z_SIZE  48

static size_t
geometry_column_bytes(int nrows)
{
	return validity_bitmap_bytes(nrows) +
		   MAXALIGN((size_t) nrows * sizeof(uint32)) +  /* offset array */
		   MAXALIGN((size_t) nrows * XPU_GEOM_POINT_Z_SIZE);  /* data */
}

/*
 * Get the fixed-width type length for a column type.
 */
static int
kds_col_typlen(KDSColumnType col_type)
{
	switch (col_type)
	{
		case KDS_COL_INT8:    return 8;
		case KDS_COL_FLOAT8:  return 8;
		case KDS_COL_FLOAT4:  return 4;
		case KDS_COL_INT4:    return 4;
		case KDS_COL_INT2:    return 2;
		case KDS_COL_GEOMETRY: return -1;  /* variable-length */
	}
	return -1;
}

/*
 * Copy an Arrow validity bitmap into a KDS column's bitmap slot.
 * Arrow and KDS use the same LSB-first bitmap format.
 */
static void
copy_validity_bitmap(char *dest, const uint64 *arrow_validity, int nrows)
{
	size_t bitmap_len = validity_bitmap_bytes(nrows);

	if (arrow_validity == NULL)
	{
		/* No nulls: set all bits to 1 */
		memset(dest, 0xFF, bitmap_len);
		/* Clear trailing bits beyond nrows */
		if (nrows % 64 != 0)
		{
			uint64 *last_word = (uint64 *)(dest + (nrows / 64) * sizeof(uint64));
			uint64 mask = (~0ULL) >> (64 - (nrows % 64));
			*last_word &= mask;
		}
	}
	else
	{
		memcpy(dest, arrow_validity, bitmap_len);
	}
}

/*
 * Convert fixed-width Arrow column to KDS column data.
 * Uses memcpy from Arrow's data buffer (buffer[1]).
 */
static void
convert_fixed_column(char *dest, const ArrowArray *arrow, int nrows, int typlen)
{
	/* Validity bitmap */
	copy_validity_bitmap(dest, (const uint64 *) arrow->buffers[0], nrows);

	/* Data values */
	char *data_dest = dest + validity_bitmap_bytes(nrows);
	if (arrow->buffers[1] != NULL)
	{
		memcpy(data_dest, arrow->buffers[1], (size_t) nrows * typlen);
	}
	else
	{
		memset(data_dest, 0, (size_t) nrows * typlen);
	}
}

/*
 * xpu_geometry_t header layout for POINT Z (matching PG-Strom):
 *   int32  type      (POINTTYPE = 1)
 *   uint16 flags     (FLAGS_GET_Z = 0x01)
 *   int32  srid
 *   int32  nitems    (1 for POINT)
 *   int32  rawsize   (24 = 3 * sizeof(float8))
 *   -- followed by rawdata: 3 x float8 (x, y, z)
 */
#define POINTTYPE           1
#define GEOM_FLAG_Z         0x01

int
build_xpu_geometry_header(char *dest, int32 srid, double x, double y, double z)
{
	int offset = 0;

	/* type */
	int32 type = POINTTYPE;
	memcpy(dest + offset, &type, sizeof(int32));
	offset += sizeof(int32);

	/* flags */
	uint16 flags = GEOM_FLAG_Z;
	memcpy(dest + offset, &flags, sizeof(uint16));
	offset += sizeof(uint16);

	/* padding for alignment */
	offset += sizeof(uint16);  /* pad to 4-byte boundary */

	/* srid */
	memcpy(dest + offset, &srid, sizeof(int32));
	offset += sizeof(int32);

	/* nitems */
	int32 nitems = 1;
	memcpy(dest + offset, &nitems, sizeof(int32));
	offset += sizeof(int32);

	/* rawsize */
	int32 rawsize = 3 * sizeof(double);
	memcpy(dest + offset, &rawsize, sizeof(int32));
	offset += sizeof(int32);

	/* coordinates */
	memcpy(dest + offset, &x, sizeof(double));
	offset += sizeof(double);
	memcpy(dest + offset, &y, sizeof(double));
	offset += sizeof(double);
	memcpy(dest + offset, &z, sizeof(double));
	offset += sizeof(double);

	return offset;
}

/*
 * Convert an Arrow geometry column to KDS format with xpu_geometry_t headers.
 *
 * Arrow geometry columns are variable-length binary with WKB-encoded data.
 * For POINT Z, the WKB contains: 1 byte order + 4 byte type + 3*8 coords = 29 bytes.
 * We convert to xpu_geometry_t which PG-Strom expects.
 */
static void
convert_geometry_column(char *dest, const ArrowArray *arrow, int nrows)
{
	/* Validity bitmap */
	copy_validity_bitmap(dest, (const uint64 *) arrow->buffers[0], nrows);

	/* Offset array */
	size_t bitmap_size = validity_bitmap_bytes(nrows);
	uint32 *offsets = (uint32 *)(dest + bitmap_size);
	char *data_area = (char *)(offsets + nrows + 1);  /* +1 for end offset */

	const uint32 *arrow_offsets = (const uint32 *) arrow->buffers[1];
	const char *arrow_data = (const char *) arrow->buffers[2];
	uint32 current_offset = 0;

	for (int i = 0; i < nrows; i++)
	{
		offsets[i] = current_offset;

		/* Check validity */
		if (arrow->buffers[0] != NULL &&
			!((((const uint64 *) arrow->buffers[0])[i / 64] >> (i % 64)) & 1))
		{
			/* NULL row - skip */
			continue;
		}

		if (arrow_offsets == NULL || arrow_data == NULL)
			continue;

		uint32 wkb_start = arrow_offsets[i];
		uint32 wkb_len = arrow_offsets[i + 1] - wkb_start;
		const char *wkb = arrow_data + wkb_start;

		/*
		 * Parse WKB POINT Z: skip byte-order (1) + type (4), read 3 doubles.
		 * Minimum WKB POINT Z size = 1 + 4 + 24 = 29 bytes.
		 */
		if (wkb_len >= 29)
		{
			double x, y, z;
			memcpy(&x, wkb + 5, sizeof(double));
			memcpy(&y, wkb + 13, sizeof(double));
			memcpy(&z, wkb + 21, sizeof(double));

			/*
			 * SRID 4978 is the standard ECEF CRS.
			 * In a production system this would come from the column metadata.
			 */
			int written = build_xpu_geometry_header(data_area + current_offset,
													4978, x, y, z);
			current_offset += written;
		}
	}

	offsets[nrows] = current_offset;
}

KDSBatch *
arrow_batch_to_kds(const ArrowArray **arrow_arrays,
				   const KDSColumnDesc *col_descs,
				   int ncols, int nrows)
{
	/* Calculate total buffer size */
	size_t header_size = KDS_HEADER_SIZE(ncols);
	size_t total_size = header_size;

	size_t *col_sizes = palloc(sizeof(size_t) * ncols);
	for (int i = 0; i < ncols; i++)
	{
		int typlen = kds_col_typlen(col_descs[i].col_type);
		if (typlen > 0)
			col_sizes[i] = fixed_column_bytes(nrows, typlen);
		else
			col_sizes[i] = geometry_column_bytes(nrows);

		total_size += MAXALIGN(col_sizes[i]);
	}

	/* Allocate KDS buffer */
	KDSBatch *batch = palloc(sizeof(KDSBatch));
	batch->buffer = palloc0(total_size);
	batch->buffer_len = total_size;
	batch->ncols = ncols;
	batch->nrows = nrows;

	/* Write header */
	uint32 length_val = (uint32) total_size;
	memcpy(batch->buffer + KDS_HDR_LENGTH_OFF, &length_val, sizeof(uint32));

	uint16 format_val = KDS_FORMAT_COLUMN;
	memcpy(batch->buffer + KDS_HDR_FORMAT_OFF, &format_val, sizeof(uint16));

	uint16 ncols_val = (uint16) ncols;
	memcpy(batch->buffer + KDS_HDR_NCOLS_OFF, &ncols_val, sizeof(uint16));

	uint32 nrooms_val = (uint32) nrows;
	memcpy(batch->buffer + KDS_HDR_NROOMS_OFF, &nrooms_val, sizeof(uint32));

	uint32 nitems_val = (uint32) nrows;
	memcpy(batch->buffer + KDS_HDR_NITEMS_OFF, &nitems_val, sizeof(uint32));

	/* Write column offsets and data */
	size_t current_offset = header_size;
	for (int i = 0; i < ncols; i++)
	{
		/* Record column offset */
		uint32 col_off = (uint32) current_offset;
		memcpy(batch->buffer + KDS_HDR_COL_OFFSETS + i * sizeof(uint32),
			   &col_off, sizeof(uint32));

		/* Convert column data */
		char *col_dest = batch->buffer + current_offset;
		int typlen = kds_col_typlen(col_descs[i].col_type);

		if (typlen > 0)
		{
			convert_fixed_column(col_dest, arrow_arrays[i], nrows, typlen);
		}
		else
		{
			convert_geometry_column(col_dest, arrow_arrays[i], nrows);
		}

		current_offset += MAXALIGN(col_sizes[i]);
	}

	pfree(col_sizes);
	return batch;
}

void
kds_batch_free(KDSBatch *batch)
{
	if (batch == NULL)
		return;
	if (batch->buffer != NULL)
		pfree(batch->buffer);
	pfree(batch);
}

void
kds_result_to_partial_agg(const void *result_buf, size_t result_len,
						  Datum *out_values, bool *out_nulls,
						  int num_aggs)
{
	/*
	 * GPU results come back as an array of Datum-sized values, one per
	 * aggregate, followed by a boolean null flags array.
	 *
	 * Layout:
	 *   Datum values[num_aggs]
	 *   bool  nulls[num_aggs]
	 */
	if (result_buf == NULL || result_len < (size_t)(num_aggs * (sizeof(Datum) + sizeof(bool))))
	{
		/* Mark all outputs as null on invalid result */
		for (int i = 0; i < num_aggs; i++)
		{
			out_values[i] = (Datum) 0;
			out_nulls[i] = true;
		}
		return;
	}

	const Datum *values = (const Datum *) result_buf;
	const bool *nulls = (const bool *)((const char *) result_buf + num_aggs * sizeof(Datum));

	for (int i = 0; i < num_aggs; i++)
	{
		out_values[i] = values[i];
		out_nulls[i] = nulls[i];
	}
}
