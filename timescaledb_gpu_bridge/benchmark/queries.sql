-- queries.sql - Benchmark query templates for GPU VectorAgg testing
--
-- Each query is tagged with a name for identification in benchmark results.
-- Queries cover the four primary spatial workload patterns.

-- Q1: Proximity search - ST_3DDWithin over a time window
-- Tag: proximity_search
\timing on
\set query_name 'proximity_search'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT object_id, count(*)
FROM benchmark_ecef_points
WHERE ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 06:00:00+00'
  AND ST_3DDWithin(
        position,
        ST_SetSRID(ST_MakePoint(6771000.0, 0.0, 0.0), 4978),
        500000.0  -- 500 km search radius
      )
GROUP BY object_id
ORDER BY count(*) DESC;

-- Q2: Frame conversion aggregate - ST_ECEF_To_ECI with AVG
-- Tag: frame_conversion_agg
\set query_name 'frame_conversion_agg'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT
    object_id,
    avg(ST_X(ST_ECEF_To_ECI(position, ts))) AS avg_eci_x,
    avg(ST_Y(ST_ECEF_To_ECI(position, ts))) AS avg_eci_y,
    avg(ST_Z(ST_ECEF_To_ECI(position, ts))) AS avg_eci_z
FROM benchmark_ecef_points
WHERE ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 12:00:00+00'
GROUP BY object_id;

-- Q3: Range scan with distance - ST_3DDistance between object pairs
-- Tag: range_distance
\set query_name 'range_distance'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT
    a.object_id AS obj_a,
    b.object_id AS obj_b,
    avg(ST_3DDistance(a.position, b.position)) AS avg_distance
FROM benchmark_ecef_points a
JOIN benchmark_ecef_points b
    ON a.ts = b.ts AND a.object_id < b.object_id
WHERE a.ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 01:00:00+00'
  AND a.object_id <= 5 AND b.object_id <= 5
GROUP BY a.object_id, b.object_id;

-- Q4: Time-series spatial aggregate - grouped by time bucket
-- Tag: timebucket_spatial_agg
\set query_name 'timebucket_spatial_agg'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT
    time_bucket('5 minutes', ts) AS bucket,
    count(*) AS num_points,
    avg(ecef_x) AS avg_x,
    avg(ecef_y) AS avg_y,
    avg(ecef_z) AS avg_z,
    avg(ST_3DDistance(
        position,
        ST_SetSRID(ST_MakePoint(0.0, 0.0, 0.0), 4978)
    )) AS avg_distance_from_origin
FROM benchmark_ecef_points
WHERE ts BETWEEN '2025-01-01 00:00:00+00' AND '2025-01-01 24:00:00+00'
GROUP BY bucket
ORDER BY bucket;

\timing off
