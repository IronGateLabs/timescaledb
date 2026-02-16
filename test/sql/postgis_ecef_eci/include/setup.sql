-- This file and its contents are licensed under the Apache License 2.0.
-- Please see the included NOTICE for copyright information and
-- LICENSE-APACHE for a copy of the license.

-- Common setup for PostGIS ECEF/ECI integration tests
-- Load the schema and functions before each test file

\ir ../../../../sql/postgis_ecef_eci/partitioning.sql
\ir ../../../../sql/postgis_ecef_eci/schema.sql
\ir ../../../../sql/postgis_ecef_eci/frame_conversion_stubs.sql
\ir ../../../../sql/postgis_ecef_eci/test_data_generator.sql
