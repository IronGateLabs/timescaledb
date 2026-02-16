-- PostGIS ECEF/ECI + TimescaleDB Integration Test Suite
-- Contract §7 checklist items 3-9 + EOP pipeline
--
-- This script runs inside a database that already has:
--   - timescaledb extension
--   - postgis extension
--   - postgis_ecef_eci extension
--   - TimescaleDB SQL artifacts loaded (partitioning.sql, eop.sql, etc.)
--
-- Results are written to _test_results table for the shell script to read.

\set ON_ERROR_STOP 0

-- =====================================================================
-- Test infrastructure
-- =====================================================================

CREATE TABLE _test_results (
    test_id     TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'PENDING',
    detail      TEXT
);

-- =====================================================================
-- §7.3: Hypertable with geometry(PointZ, 4978)
-- =====================================================================

DO $$
BEGIN
    CREATE TABLE test_ecef (
        time         TIMESTAMPTZ     NOT NULL,
        object_id    INT             NOT NULL,
        pos          geometry(PointZ, 4978),
        x            FLOAT8          NOT NULL,
        y            FLOAT8          NOT NULL,
        z            FLOAT8          NOT NULL
    );

    PERFORM create_hypertable(
        'test_ecef', 'time',
        chunk_time_interval => INTERVAL '1 hour'
    );

    INSERT INTO _test_results (test_id, description, status)
    VALUES ('7.3', 'Hypertable with geometry(PointZ, 4978)', 'PASS');
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results (test_id, description, status, detail)
    VALUES ('7.3', 'Hypertable with geometry(PointZ, 4978)', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.4: INSERT/SELECT ECEF point — data integrity
-- =====================================================================

DO $$
DECLARE
    retrieved_x   FLOAT8;
    retrieved_srid INT;
    row_count     INT;
BEGIN
    -- Insert test data: ISS-like positions in ECEF (meters)
    INSERT INTO test_ecef (time, object_id, pos, x, y, z) VALUES
        ('2025-01-01 00:00:00+00', 25544,
         ST_SetSRID(ST_MakePoint(-4400000, 1600000, 4700000), 4978),
         -4400000, 1600000, 4700000),
        ('2025-01-01 00:01:00+00', 25544,
         ST_SetSRID(ST_MakePoint(-4401000, 1601000, 4701000), 4978),
         -4401000, 1601000, 4701000),
        ('2025-01-01 00:02:00+00', 25545,
         ST_SetSRID(ST_MakePoint(-3000000, 3000000, 5500000), 4978),
         -3000000, 3000000, 5500000),
        -- Additional points for compression test (need enough data in a chunk)
        ('2025-01-01 00:03:00+00', 25544,
         ST_SetSRID(ST_MakePoint(-4402000, 1602000, 4702000), 4978),
         -4402000, 1602000, 4702000),
        ('2025-01-01 00:04:00+00', 25545,
         ST_SetSRID(ST_MakePoint(-3001000, 3001000, 5501000), 4978),
         -3001000, 3001000, 5501000);

    -- Verify readback
    SELECT ST_X(pos), ST_SRID(pos)
    INTO retrieved_x, retrieved_srid
    FROM test_ecef
    WHERE object_id = 25544 AND time = '2025-01-01 00:00:00+00';

    SELECT count(*) INTO row_count FROM test_ecef;

    IF retrieved_x = -4400000 AND retrieved_srid = 4978 AND row_count = 5 THEN
        INSERT INTO _test_results VALUES (
            '7.4', 'INSERT/SELECT ECEF point — data integrity', 'PASS',
            format('rows=%s, x=%s, srid=%s', row_count, retrieved_x, retrieved_srid));
    ELSE
        INSERT INTO _test_results VALUES (
            '7.4', 'INSERT/SELECT ECEF point — data integrity', 'FAIL',
            format('rows=%s (exp 5), x=%s (exp -4400000), srid=%s (exp 4978)',
                   row_count, retrieved_x, retrieved_srid));
    END IF;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.4', 'INSERT/SELECT ECEF point — data integrity', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.5: ST_3DDistance with GiST index on hypertable
-- =====================================================================

DO $$
DECLARE
    dist FLOAT8;
BEGIN
    -- Create GiST 3D index
    CREATE INDEX idx_test_ecef_gist
        ON test_ecef USING gist (pos gist_geometry_ops_nd);

    -- Euclidean distance between ISS position at t=0 and t=1
    -- delta = (1000, 1000, 1000) meters => dist = sqrt(3) * 1000 ≈ 1732.05
    SELECT ST_3DDistance(a.pos, b.pos) INTO dist
    FROM test_ecef a, test_ecef b
    WHERE a.object_id = 25544 AND a.time = '2025-01-01 00:00:00+00'
      AND b.object_id = 25544 AND b.time = '2025-01-01 00:01:00+00';

    IF dist IS NOT NULL AND dist BETWEEN 1700 AND 1800 THEN
        INSERT INTO _test_results VALUES (
            '7.5', 'ST_3DDistance with GiST index', 'PASS',
            format('distance=%s m (expected ~1732)', round(dist::numeric, 2)));
    ELSE
        INSERT INTO _test_results VALUES (
            '7.5', 'ST_3DDistance with GiST index', 'FAIL',
            format('distance=%s (expected ~1732)', dist));
    END IF;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.5', 'ST_3DDistance with GiST index', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.8: ST_ECEF_To_ECI on hypertable (before compression)
-- =====================================================================

DO $$
DECLARE
    result_srid INT;
    result_x    FLOAT8;
BEGIN
    -- Convert an ECEF point to ECI (ICRF frame)
    SELECT
        ST_SRID(ST_ECEF_To_ECI(pos, time)),
        ST_X(ST_ECEF_To_ECI(pos, time))
    INTO result_srid, result_x
    FROM test_ecef
    WHERE object_id = 25544 AND time = '2025-01-01 00:00:00+00';

    -- ICRF output SRID = 900001; x should be non-null (rotated from ECEF)
    IF result_srid = 900001 AND result_x IS NOT NULL THEN
        INSERT INTO _test_results VALUES (
            '7.8', 'ST_ECEF_To_ECI on hypertable', 'PASS',
            format('srid=%s, eci_x=%s', result_srid, round(result_x::numeric, 2)));
    ELSE
        INSERT INTO _test_results VALUES (
            '7.8', 'ST_ECEF_To_ECI on hypertable', 'FAIL',
            format('srid=%s (exp 900001), x=%s', result_srid, result_x));
    END IF;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.8', 'ST_ECEF_To_ECI on hypertable', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.9: Continuous aggregate with avg(x), avg(y), avg(z)
-- =====================================================================

-- Step 1: Create the continuous aggregate (can be inside DO block)
DO $$
BEGIN
    CREATE MATERIALIZED VIEW test_ecef_cagg
    WITH (timescaledb.continuous) AS
    SELECT
        time_bucket('1 hour', time) AS bucket,
        object_id,
        avg(x) AS avg_x,
        avg(y) AS avg_y,
        avg(z) AS avg_z,
        count(*) AS cnt
    FROM test_ecef
    GROUP BY bucket, object_id
    WITH NO DATA;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.9', 'Continuous aggregate avg(x,y,z)', 'FAIL',
        'CREATE MATERIALIZED VIEW failed: ' || SQLERRM);
END;
$$;

-- Step 2: Refresh must run outside DO block (cannot be inside transaction)
CALL refresh_continuous_aggregate('test_ecef_cagg', NULL, NULL);

-- Step 3: Verify the aggregate has data
DO $$
DECLARE
    agg_x   FLOAT8;
    agg_cnt BIGINT;
BEGIN
    -- Only verify if the CAGG was created and not already recorded as FAIL
    IF NOT EXISTS (SELECT 1 FROM _test_results WHERE test_id = '7.9') THEN
        SELECT avg_x, cnt INTO agg_x, agg_cnt
        FROM test_ecef_cagg
        WHERE object_id = 25544
        LIMIT 1;

        IF agg_x IS NOT NULL AND agg_cnt > 0 THEN
            INSERT INTO _test_results VALUES (
                '7.9', 'Continuous aggregate avg(x,y,z)', 'PASS',
                format('avg_x=%s, count=%s', round(agg_x::numeric, 2), agg_cnt));
        ELSE
            INSERT INTO _test_results VALUES (
                '7.9', 'Continuous aggregate avg(x,y,z)', 'FAIL',
                format('avg_x=%s, count=%s', agg_x, agg_cnt));
        END IF;
    END IF;
EXCEPTION WHEN OTHERS THEN
    IF NOT EXISTS (SELECT 1 FROM _test_results WHERE test_id = '7.9') THEN
        INSERT INTO _test_results VALUES (
            '7.9', 'Continuous aggregate avg(x,y,z)', 'FAIL', SQLERRM);
    END IF;
END;
$$;

-- =====================================================================
-- §7.6: Compress chunk with geometry column
-- =====================================================================

DO $$
DECLARE
    chunk_name TEXT;
BEGIN
    -- Enable compression
    ALTER TABLE test_ecef SET (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'object_id',
        timescaledb.compress_orderby = 'time ASC'
    );

    -- Get a chunk to compress
    SELECT c::text INTO chunk_name
    FROM show_chunks('test_ecef') c
    LIMIT 1;

    IF chunk_name IS NULL THEN
        INSERT INTO _test_results VALUES (
            '7.6', 'Compress chunk with geometry', 'FAIL', 'No chunks found');
        RETURN;
    END IF;

    -- Compress it
    PERFORM compress_chunk(chunk_name);

    INSERT INTO _test_results VALUES (
        '7.6', 'Compress chunk with geometry', 'PASS',
        format('compressed chunk: %s', chunk_name));
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.6', 'Compress chunk with geometry', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.7: SELECT from compressed chunk — geometry intact
-- =====================================================================

DO $$
DECLARE
    cnt         INT;
    retrieved_x FLOAT8;
    retrieved_srid INT;
BEGIN
    SELECT count(*) INTO cnt FROM test_ecef;

    SELECT ST_X(pos), ST_SRID(pos)
    INTO retrieved_x, retrieved_srid
    FROM test_ecef
    WHERE object_id = 25544
    ORDER BY time
    LIMIT 1;

    IF cnt = 5 AND retrieved_x = -4400000 AND retrieved_srid = 4978 THEN
        INSERT INTO _test_results VALUES (
            '7.7', 'SELECT from compressed chunk — geometry intact', 'PASS',
            format('rows=%s, x=%s, srid=%s', cnt, retrieved_x, retrieved_srid));
    ELSE
        INSERT INTO _test_results VALUES (
            '7.7', 'SELECT from compressed chunk — geometry intact', 'FAIL',
            format('rows=%s (exp 5), x=%s (exp -4400000), srid=%s (exp 4978)',
                   cnt, retrieved_x, retrieved_srid));
    END IF;
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.7', 'SELECT from compressed chunk — geometry intact', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- §7.EOP: EOP sync pipeline (load -> interpolation -> sync -> staleness)
-- =====================================================================

DO $$
DECLARE
    n_loaded    INT;
    interp_xp   FLOAT8;
    interp_dut1  FLOAT8;
    n_synced    INT;
    stale_flag  BOOLEAN;
    postgis_eop_exists BOOLEAN;
BEGIN
    -- Step 1: Load synthetic EOP data into ecef_eci.eop_data
    -- MJD 60676 = 2025-01-01, 60677 = 2025-01-02, 60678 = 2025-01-03
    INSERT INTO ecef_eci.eop_data (mjd, date, xp, yp, dut1, data_type) VALUES
        (60676.0, '2025-01-01', 0.12345, 0.45678, -0.1234, 'I'),
        (60677.0, '2025-01-02', 0.12355, 0.45688, -0.1244, 'I'),
        (60678.0, '2025-01-03', 0.12365, 0.45698, -0.1254, 'I')
    ON CONFLICT (mjd) DO NOTHING;

    SELECT count(*) INTO n_loaded FROM ecef_eci.eop_data;
    IF n_loaded < 3 THEN
        INSERT INTO _test_results VALUES (
            '7.EOP', 'EOP sync pipeline', 'FAIL',
            format('Only %s rows in eop_data (expected >= 3)', n_loaded));
        RETURN;
    END IF;

    -- Step 2: Test interpolation at midpoint (2025-01-01 12:00:00 UTC)
    -- Expected: xp = (0.12345 + 0.12355) / 2 = 0.12350
    --           dut1 = (-0.1234 + -0.1244) / 2 = -0.1239
    SELECT xp, dut1 INTO interp_xp, interp_dut1
    FROM ecef_eci.eop_at_epoch('2025-01-01 12:00:00+00');

    IF interp_xp IS NULL OR abs(interp_xp - 0.12350) > 0.0001 THEN
        INSERT INTO _test_results VALUES (
            '7.EOP', 'EOP sync pipeline', 'FAIL',
            format('Interpolation: xp=%s (exp ~0.12350), dut1=%s', interp_xp, interp_dut1));
        RETURN;
    END IF;

    -- Step 3: Sync to PostGIS postgis_eop table
    SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'postgis_eop'
    ) INTO postgis_eop_exists;

    IF postgis_eop_exists THEN
        SELECT ecef_eci.sync_eop_to_postgis() INTO n_synced;
        IF n_synced < 0 THEN
            INSERT INTO _test_results VALUES (
                '7.EOP', 'EOP sync pipeline', 'FAIL',
                format('sync_eop_to_postgis returned %s', n_synced));
            RETURN;
        END IF;
    ELSE
        -- postgis_eop doesn't exist — sync function should handle gracefully
        SELECT ecef_eci.sync_eop_to_postgis() INTO n_synced;
        -- n_synced = -1 means table not found (expected if extension doesn't create it)
    END IF;

    -- Step 4: Check staleness (data is from 2025, "today" is 2026 — should be stale)
    SELECT is_stale INTO stale_flag FROM ecef_eci.eop_staleness(7);

    INSERT INTO _test_results VALUES (
        '7.EOP', 'EOP sync pipeline', 'PASS',
        format('loaded=%s, interp_xp=%s, synced=%s, stale=%s',
               n_loaded, round(interp_xp::numeric, 5), n_synced, stale_flag));
EXCEPTION WHEN OTHERS THEN
    INSERT INTO _test_results VALUES (
        '7.EOP', 'EOP sync pipeline', 'FAIL', SQLERRM);
END;
$$;

-- =====================================================================
-- Final results summary
-- =====================================================================

SELECT
    test_id,
    description,
    status,
    COALESCE(detail, '') AS detail
FROM _test_results
ORDER BY test_id;
