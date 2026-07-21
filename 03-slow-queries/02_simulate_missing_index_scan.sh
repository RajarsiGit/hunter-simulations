#!/usr/bin/env bash
# =============================================================================
# 02_simulate_missing_index_scan.sh
# Slow Queries DRILL — Missing Index Causing Sequential Scan
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
#
# Reproduces the classic case: a large table filtered on an unindexed column
# forces a full sequential scan.
#
#   Simulate: EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM slowq_orders
#             WHERE status = 'failed';   -- Seq Scan, Rows Removed by Filter: many
#
# Usage:
#   ./02_simulate_missing_index_scan.sh [hold_seconds] [--yes]
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

echo "=== DRILL: Missing Index Causing Sequential Scan ==="

run_explain() {
    "${PSQL[@]}" -c "SET application_name = 'drill_missing_index_scan';
                      EXPLAIN (ANALYZE, BUFFERS)
                      SELECT * FROM slowq_orders WHERE status = 'failed';"
}

echo ""
echo "--- pg_stat_user_tables before ---"
"${PSQL[@]}" -c "SELECT relname, seq_scan, seq_tup_read, idx_scan
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

echo ""
echo "--- EXPLAIN (ANALYZE, BUFFERS) on unindexed 'status' filter ---"
run_explain

echo ""
echo "--- Sustaining load briefly so pg_stat_activity/seq_scan show a signal ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1. This holds the session active for a few seconds and"
echo "    bursts a couple thousand seq scans (seq_scan_tables, >1000 threshold)"
echo "    so a quick poll can catch it — sized for a <=20s drill run, not for"
echo "    clearing the hunter's 300s poll interval/query_critical threshold."
hold_session_active "drill_missing_index_scan" \
    "SELECT * FROM slowq_orders WHERE status = 'failed'" "${HOLD_SECONDS}"
run_seq_scan_burst "drill_missing_index_scan" \
    "1 FROM slowq_orders WHERE status = 'failed'" 2000
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "--- pg_stat_user_tables after ---"
"${PSQL[@]}" -c "SELECT relname, seq_scan, seq_tup_read, idx_scan
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

echo ""
echo "Drill complete."
