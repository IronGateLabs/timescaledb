#!/usr/bin/env bash
# This file and its contents are licensed under the Apache License 2.0.
# Please see the included NOTICE for copyright information and
# LICENSE-APACHE for a copy of the license.
#
# Integration test runner for PostGIS ECEF/ECI + TimescaleDB
# Runs inside the Docker container.
#
# Starts PostgreSQL, runs the contract §7 integration test checklist,
# and exits with 0 on success or 1 on any test failure.

set -euo pipefail

# -- Configuration --
PGDATA=/var/lib/postgresql/data
PGLOG=/var/log/postgresql/test.log
TEST_DB=ecef_eci_integration
SQL_DIR=/test/sql
INTEGRATION_SQL=/test/integration_test.sql

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  PostGIS ECEF/ECI + TimescaleDB${NC}"
echo -e "${BOLD}  Integration Test Suite (Contract §7)${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# -- Initialize PostgreSQL --
echo -e "${YELLOW}[init]${NC} Initializing PostgreSQL..."
mkdir -p "$PGDATA" /var/log/postgresql
chown -R postgres:postgres "$PGDATA" /var/log/postgresql

gosu postgres initdb -D "$PGDATA" --auth=trust --no-locale --encoding=UTF8 > /dev/null

# Configure PostgreSQL for TimescaleDB
cat >> "$PGDATA/postgresql.conf" <<PGCONF
shared_preload_libraries = 'timescaledb'
log_min_messages = warning
timescaledb.telemetry_level = off
max_connections = 20
PGCONF

# Start PostgreSQL
gosu postgres pg_ctl -D "$PGDATA" -l "$PGLOG" -w start > /dev/null
echo -e "${GREEN}[init]${NC} PostgreSQL started."

# Verify extensions are loadable
echo -e "${YELLOW}[init]${NC} Checking installed extensions..."
gosu postgres psql -t -A -c \
    "SELECT name, default_version FROM pg_available_extensions
     WHERE name IN ('timescaledb', 'postgis', 'postgis_ecef_eci')
     ORDER BY name;" 2>/dev/null || true
echo ""

# -- Counters --
pass_count=0
fail_count=0
skip_count=0

report_pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    ((pass_count++)) || true
}

report_fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    [ -n "${2:-}" ] && echo -e "        ${RED}Detail: $2${NC}"
    ((fail_count++)) || true
}

report_skip() {
    echo -e "  ${YELLOW}SKIP${NC}: $1"
    ((skip_count++)) || true
}

# ============================================================
# §7.1: Extension load order — PostGIS first
# ============================================================
echo -e "${BOLD}--- §7.1: Extension load order (PostGIS first) ---${NC}"
gosu postgres createdb test_order1
if gosu postgres psql -q -d test_order1 \
    -c "CREATE EXTENSION postgis;" \
    -c "CREATE EXTENSION postgis_ecef_eci;" \
    -c "CREATE EXTENSION timescaledb CASCADE;" 2>&1; then
    report_pass "CREATE EXTENSION postgis -> postgis_ecef_eci -> timescaledb"
else
    report_fail "CREATE EXTENSION postgis -> postgis_ecef_eci -> timescaledb"
fi
gosu postgres dropdb --if-exists test_order1

# ============================================================
# §7.2: Extension load order — TimescaleDB first
# ============================================================
echo -e "${BOLD}--- §7.2: Extension load order (TimescaleDB first) ---${NC}"
gosu postgres createdb test_order2
if gosu postgres psql -q -d test_order2 \
    -c "CREATE EXTENSION timescaledb;" \
    -c "CREATE EXTENSION postgis;" \
    -c "CREATE EXTENSION postgis_ecef_eci;" 2>&1; then
    report_pass "CREATE EXTENSION timescaledb -> postgis -> postgis_ecef_eci"
else
    report_fail "CREATE EXTENSION timescaledb -> postgis -> postgis_ecef_eci"
fi
gosu postgres dropdb --if-exists test_order2

# ============================================================
# §7.3-7.9 + EOP: Main integration tests
# ============================================================
echo ""
echo -e "${BOLD}--- §7.3-7.9 + EOP: Main integration tests ---${NC}"

# Create integration test database with all extensions
gosu postgres createdb "$TEST_DB"
gosu postgres psql -q -d "$TEST_DB" \
    -c "CREATE EXTENSION timescaledb;" \
    -c "CREATE EXTENSION postgis;" \
    -c "CREATE EXTENSION postgis_ecef_eci;"

# Create ecef_eci schema for TimescaleDB artifacts
# (The postgis_ecef_eci extension installs into public; our TimescaleDB-side
#  objects like eop_data, partitioning functions go into a separate schema.)
gosu postgres psql -q -d "$TEST_DB" \
    -c "CREATE SCHEMA IF NOT EXISTS ecef_eci;"

# Load TimescaleDB SQL artifacts (order matters for dependencies)
echo -e "${YELLOW}[setup]${NC} Loading TimescaleDB SQL artifacts..."
for f in \
    "$SQL_DIR/partitioning.sql" \
    "$SQL_DIR/eop.sql" \
    "$SQL_DIR/frame_conversion_stubs.sql" \
; do
    if [ -f "$f" ]; then
        echo "  Loading: $(basename "$f")"
        gosu postgres psql -q -d "$TEST_DB" -f "$f" 2>&1 | grep -v "^NOTICE:" || true
    fi
done
echo ""

# Run the SQL integration tests
echo -e "${YELLOW}[test]${NC} Running SQL integration tests..."
gosu postgres psql -d "$TEST_DB" -f "$INTEGRATION_SQL" 2>&1 | \
    grep -E "^(NOTICE|ERROR|WARNING)" | \
    sed 's/^NOTICE:  //' || true

# Parse results from the _test_results table
echo ""
while IFS='|' read -r test_id description status detail; do
    test_id=$(echo "$test_id" | xargs)
    description=$(echo "$description" | xargs)
    status=$(echo "$status" | xargs)
    detail=$(echo "${detail:-}" | xargs)

    case "$status" in
        PASS)
            if [ -n "$detail" ]; then
                report_pass "§$test_id: $description ($detail)"
            else
                report_pass "§$test_id: $description"
            fi
            ;;
        FAIL)
            report_fail "§$test_id: $description" "$detail"
            ;;
        SKIP)
            report_skip "§$test_id: $description"
            ;;
    esac
done < <(gosu postgres psql -d "$TEST_DB" -t -A \
    -c "SELECT test_id, description, status, COALESCE(detail, '') FROM _test_results ORDER BY test_id;")

# ============================================================
# §7.12: pg_dump / pg_restore cycle
# ============================================================
echo ""
echo -e "${BOLD}--- §7.12: pg_dump / pg_restore cycle ---${NC}"
DUMP_FILE=/tmp/integration_dump.sql
RESTORE_DB=ecef_eci_restored

if gosu postgres pg_dump "$TEST_DB" > "$DUMP_FILE" 2>/dev/null; then
    gosu postgres createdb "$RESTORE_DB"

    # Restore — some NOTICE messages are expected
    if gosu postgres psql -q -d "$RESTORE_DB" -f "$DUMP_FILE" > /dev/null 2>&1; then
        # Verify data survived the roundtrip
        restored_count=$(gosu postgres psql -d "$RESTORE_DB" -t -A \
            -c "SELECT count(*) FROM test_ecef;" 2>/dev/null || echo "0")
        restored_count=$(echo "$restored_count" | xargs)

        if [ "$restored_count" -gt 0 ] 2>/dev/null; then
            report_pass "pg_dump/pg_restore cycle (${restored_count} rows restored)"
        else
            report_fail "pg_dump/pg_restore cycle" "No rows found after restore"
        fi
    else
        report_fail "pg_dump/pg_restore cycle" "psql restore failed"
    fi

    gosu postgres dropdb --if-exists "$RESTORE_DB"
    rm -f "$DUMP_FILE"
else
    report_fail "pg_dump/pg_restore cycle" "pg_dump failed"
fi

# ============================================================
# §7.10-7.11: ALTER EXTENSION UPDATE (skipped for dev versions)
# ============================================================
echo ""
echo -e "${BOLD}--- §7.10-7.11: ALTER EXTENSION UPDATE ---${NC}"
report_skip "§7.10: ALTER EXTENSION postgis_ecef_eci UPDATE (no upgrade path for dev version)"
report_skip "§7.11: ALTER EXTENSION timescaledb UPDATE (no upgrade path for dev version)"

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Results${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "  ${GREEN}PASS${NC}: $pass_count"
echo -e "  ${RED}FAIL${NC}: $fail_count"
echo -e "  ${YELLOW}SKIP${NC}: $skip_count"
echo ""

# Shutdown PostgreSQL
gosu postgres pg_ctl -D "$PGDATA" -m fast stop > /dev/null 2>&1 || true

if [ "$fail_count" -gt 0 ]; then
    echo -e "${RED}FAILED: $fail_count test(s) failed.${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED.${NC}"
    exit 0
fi
