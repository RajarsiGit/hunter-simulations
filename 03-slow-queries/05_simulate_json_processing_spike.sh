#!/usr/bin/env bash
# =============================================================================
# 05_simulate_json_processing_spike.sh
# Slow Queries DRILL — JSONB Field Extraction CPU Spike
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
#
# Filtering on a jsonb field (`data->>'status'`) with no expression index
# forces PostgreSQL to deserialize and inspect every row's JSON payload —
# a CPU-heavy seq scan that shows up as high CPUUtilization/DBLoad in
# CloudWatch with no single obviously "slow" query in isolation.
#
#   Simulate: SELECT count(*) FROM slowq_json_events WHERE data->>'status' LIKE 'a%';
#
# Usage:
#   ./05_simulate_json_processing_spike.sh [--yes]
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")

echo "=== DRILL: JSONB Field Extraction CPU Spike ==="

run_explain() {
    "${PSQL[@]}" -c "SET application_name = 'drill_json_cpu_spike';
                      EXPLAIN (ANALYZE, BUFFERS)
                      SELECT count(*) FROM slowq_json_events WHERE data->>'status' LIKE 'a%';"
}

echo ""
echo "--- EXPLAIN on unindexed jsonb field extraction (expect Seq Scan, high CPU) ---"
run_explain

echo ""
echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
echo "    is measured from this statement's query_start, so it only crosses the"
echo "    hunter's >=30s threshold near the END of the hold — a 180s hold keeps it"
echo "    over threshold for a full 150s, comfortably wider than the poller's ~27s"
echo "    tick cadence (vs. only ~5s of margin at the old 35s hold). Also bursts"
echo "    1500 seq scans (seq_scan_tables, >1000 threshold) so that check fires too."
hold_session_active "drill_json_cpu_spike" \
    "SELECT count(*) AS c FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" 180
run_seq_scan_burst "drill_json_cpu_spike" \
    "count(*) FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" 1500
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Drill complete."
