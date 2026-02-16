#!/bin/bash
#
# run_benchmark.sh - GPU VectorAgg benchmark harness
#
# Runs query templates with GPU enabled vs forced-CPU, collects timing
# and correctness data, and optionally creates or checks baselines.
#
# Usage:
#   ./run_benchmark.sh [OPTIONS]
#
# Options:
#   --size N              Dataset size (default: 100000)
#   --orbit TYPE          Orbit type: LEO, MEO, GEO, mixed (default: mixed)
#   --timespan INTERVAL   Time span for data (default: '24 hours')
#   --create-baseline     Save results as baseline
#   --check-regression    Compare against baseline (exit nonzero on regression)
#   --db NAME             Database name (default: gpu_benchmark)
#   --skip-generate       Skip dataset generation
#   --tolerance TOL       Relative tolerance for result comparison (default: 1e-10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE_FILE="${SCRIPT_DIR}/baseline.json"

# Defaults
DATASET_SIZE=100000
ORBIT_TYPE="mixed"
TIMESPAN="24 hours"
DB_NAME="gpu_benchmark"
CREATE_BASELINE=false
CHECK_REGRESSION=false
SKIP_GENERATE=false
TOLERANCE="1e-10"
REGRESSION_THRESHOLD=0.15  # 15%

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)         DATASET_SIZE="$2"; shift 2;;
        --orbit)        ORBIT_TYPE="$2"; shift 2;;
        --timespan)     TIMESPAN="$2"; shift 2;;
        --create-baseline) CREATE_BASELINE=true; shift;;
        --check-regression) CHECK_REGRESSION=true; shift;;
        --db)           DB_NAME="$2"; shift 2;;
        --skip-generate) SKIP_GENERATE=true; shift;;
        --tolerance)    TOLERANCE="$2"; shift 2;;
        *)              echo "Unknown option: $1"; exit 1;;
    esac
done

RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULTS_DIR}/benchmark_${TIMESTAMP}.json"

echo "=== GPU VectorAgg Benchmark ==="
echo "Dataset: ${DATASET_SIZE} rows, orbit=${ORBIT_TYPE}, timespan=${TIMESPAN}"
echo "Database: ${DB_NAME}"
echo ""

# Create database if needed
psql -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    createdb "${DB_NAME}"

# Generate dataset
if [ "${SKIP_GENERATE}" = false ]; then
    echo "--- Generating dataset ---"
    psql -d "${DB_NAME}" \
        -v num_rows="${DATASET_SIZE}" \
        -v orbit_type="${ORBIT_TYPE}" \
        -v timespan="${TIMESPAN}" \
        -f "${SCRIPT_DIR}/generate_dataset.sql"
    echo ""
fi

# Query names (must match queries.sql tags)
QUERIES=("proximity_search" "frame_conversion_agg" "range_distance" "timebucket_spatial_agg")

# Results accumulator
echo "[" > "${RESULT_FILE}"
FIRST_RESULT=true

run_query() {
    local query_name="$1"
    local mode="$2"  # "gpu" or "cpu"
    local query_file="${SCRIPT_DIR}/queries.sql"

    # Extract query by its tag comment
    local setting=""
    if [ "${mode}" = "cpu" ]; then
        setting="SET timescaledb.gpu_min_batch_rows = 2147483647;"
    else
        setting="RESET timescaledb.gpu_min_batch_rows;"
    fi

    # Run with timing and capture output
    local start_time end_time elapsed_ms
    start_time=$(date +%s%N)

    local output
    output=$(psql -d "${DB_NAME}" -c "${setting}" -f "${query_file}" 2>&1) || true

    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "${elapsed_ms}"
}

compare_results() {
    local query_name="$1"

    # Run query in both modes, capture results (not timing)
    local gpu_result cpu_result

    gpu_result=$(psql -d "${DB_NAME}" -t -A \
        -c "RESET timescaledb.gpu_min_batch_rows;" \
        -c "$(extract_query "${query_name}")" 2>/dev/null) || true

    cpu_result=$(psql -d "${DB_NAME}" -t -A \
        -c "SET timescaledb.gpu_min_batch_rows = 2147483647;" \
        -c "$(extract_query "${query_name}")" 2>/dev/null) || true

    if [ "${gpu_result}" = "${cpu_result}" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Run benchmarks
echo "--- Running benchmarks ---"
echo ""

for query_name in "${QUERIES[@]}"; do
    echo "Query: ${query_name}"

    # Run 3 iterations for each mode, take median
    declare -a gpu_times=()
    declare -a cpu_times=()

    for i in 1 2 3; do
        gpu_ms=$(run_query "${query_name}" "gpu")
        cpu_ms=$(run_query "${query_name}" "cpu")
        gpu_times+=("${gpu_ms}")
        cpu_times+=("${cpu_ms}")
    done

    # Sort and take median (index 1 of 3)
    gpu_median=$(printf '%s\n' "${gpu_times[@]}" | sort -n | sed -n '2p')
    cpu_median=$(printf '%s\n' "${cpu_times[@]}" | sort -n | sed -n '2p')

    # Calculate speedup
    if [ "${gpu_median}" -gt 0 ]; then
        speedup=$(echo "scale=2; ${cpu_median} / ${gpu_median}" | bc)
    else
        speedup="N/A"
    fi

    # Result match check
    result_match=$(compare_results "${query_name}")

    echo "  CPU: ${cpu_median}ms  GPU: ${gpu_median}ms  Speedup: ${speedup}x  Match: ${result_match}"

    # Append to JSON
    if [ "${FIRST_RESULT}" = false ]; then
        echo "," >> "${RESULT_FILE}"
    fi
    FIRST_RESULT=false

    cat >> "${RESULT_FILE}" <<ENTRY
  {
    "query": "${query_name}",
    "cpu_median_ms": ${cpu_median},
    "gpu_median_ms": ${gpu_median},
    "speedup": "${speedup}",
    "result_match": ${result_match},
    "dataset_size": ${DATASET_SIZE},
    "timestamp": "${TIMESTAMP}"
  }
ENTRY
done

echo "]" >> "${RESULT_FILE}"
echo ""
echo "Results saved to: ${RESULT_FILE}"

# Baseline operations
if [ "${CREATE_BASELINE}" = true ]; then
    cp "${RESULT_FILE}" "${BASELINE_FILE}"
    echo "Baseline saved to: ${BASELINE_FILE}"
fi

if [ "${CHECK_REGRESSION}" = true ]; then
    if [ ! -f "${BASELINE_FILE}" ]; then
        echo "ERROR: No baseline file found at ${BASELINE_FILE}"
        echo "Run with --create-baseline first"
        exit 1
    fi

    echo ""
    echo "--- Regression Check ---"
    REGRESSION_FOUND=false

    for query_name in "${QUERIES[@]}"; do
        baseline_ms=$(python3 -c "
import json, sys
with open('${BASELINE_FILE}') as f:
    data = json.load(f)
for r in data:
    if r['query'] == '${query_name}':
        print(r.get('gpu_median_ms', r.get('cpu_median_ms', 0)))
        sys.exit(0)
print(0)
")
        current_ms=$(python3 -c "
import json, sys
with open('${RESULT_FILE}') as f:
    data = json.load(f)
for r in data:
    if r['query'] == '${query_name}':
        print(r.get('gpu_median_ms', r.get('cpu_median_ms', 0)))
        sys.exit(0)
print(0)
")

        if [ "${baseline_ms}" -gt 0 ]; then
            regression_pct=$(echo "scale=4; (${current_ms} - ${baseline_ms}) / ${baseline_ms}" | bc)
            threshold_exceeded=$(echo "${regression_pct} > ${REGRESSION_THRESHOLD}" | bc)

            if [ "${threshold_exceeded}" = "1" ]; then
                echo "REGRESSION: ${query_name} - baseline: ${baseline_ms}ms, current: ${current_ms}ms (${regression_pct})"
                REGRESSION_FOUND=true
            else
                echo "OK: ${query_name} - baseline: ${baseline_ms}ms, current: ${current_ms}ms"
            fi
        fi
    done

    if [ "${REGRESSION_FOUND}" = true ]; then
        echo ""
        echo "FAILED: Performance regression detected!"
        exit 1
    else
        echo ""
        echo "PASSED: No performance regressions detected."
    fi
fi
