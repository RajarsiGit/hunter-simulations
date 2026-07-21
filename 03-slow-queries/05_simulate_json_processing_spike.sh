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
#   ./05_simulate_json_processing_spike.sh [hold_seconds] [--yes]
#
# Defaults: hold_seconds=5 — how long the sustained session below stays
# state='active' (see hold_session_active in _lib/env.sh). 5s is well under
# the hunter's 300s poll interval/query_slow >=30s threshold; pass a larger
# value (e.g. 60+) for a wider hunter-detection window.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

POSARGS=()
while IFS= read -r line; do POSARGS+=("${line}"); done < <(strip_flags "$@")
HOLD_SECONDS="${POSARGS[0]:-5}"

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
echo "--- Sustaining load briefly so pg_stat_activity/seq_scan show a signal ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1. This holds the session active for a few seconds and"
echo "    bursts a few hundred seq scans — kept lower than the other drills'"
echo "    burst count here since each scan pays real per-row jsonb-deserialize"
echo "    cost (the whole point of this drill) — sized for a <=20s drill run,"
echo "    not for clearing the hunter's 300s poll interval/query_critical threshold."
hold_session_active "drill_json_cpu_spike" \
    "SELECT count(*) AS c FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" "${HOLD_SECONDS}"
run_seq_scan_burst "drill_json_cpu_spike" \
    "count(*) FROM slowq_json_events WHERE data->>'status' LIKE 'a%'" 300
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Drill complete."
