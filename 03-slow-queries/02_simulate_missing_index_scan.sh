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
#   ./02_simulate_missing_index_scan.sh [--yes]
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

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
echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
echo "    is measured from this statement's query_start, so a 2400s hold clears"
echo "    not just query_slow's >=30s warning threshold but query_critical's"
echo "    >=1800s CRITICAL threshold too (actions/slow-queries.jsonc Q-2), with"
echo "    600s to spare over the hunter's 300s poll interval (>=7 ticks of"
echo "    overlap — EXTREME margin). Also bursts 200000 seq scans"
echo "    (seq_scan_tables, >1000 threshold, ratio>0.80) so that check fires hard too."
hold_session_active "drill_missing_index_scan" \
    "SELECT * FROM slowq_orders WHERE status = 'failed'" 2400
run_seq_scan_burst "drill_missing_index_scan" \
    "1 FROM slowq_orders WHERE status = 'failed'" 200000
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "--- pg_stat_user_tables after ---"
"${PSQL[@]}" -c "SELECT relname, seq_scan, seq_tup_read, idx_scan
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

echo ""
echo "Drill complete."
