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
echo "    is measured from this statement's query_start, so a 2400s hold clears"
echo "    not just query_slow's >=30s warning threshold but query_critical's"
echo "    >=1800s CRITICAL threshold too (actions/slow-queries.jsonc Q-2), with"
echo "    600s to spare over the hunter's 300s poll interval (>=7 ticks of"
echo "    overlap — EXTREME margin). Also bursts 200000 seq scans"
echo "    (seq_scan_tables, >1000 threshold, ratio>0.80) so that check fires hard too."
hold_session_active "drill_json_cpu_spike" \
    "SELECT count(*) AS c FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" 2400
run_seq_scan_burst "drill_json_cpu_spike" \
    "count(*) FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" 200000
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Drill complete."
