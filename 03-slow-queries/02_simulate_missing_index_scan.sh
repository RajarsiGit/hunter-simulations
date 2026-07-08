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
#   Fix:      CREATE INDEX CONCURRENTLY idx_slowq_orders_status
#             ON slowq_orders(status);   -- then rerun to show the Index Scan
#
# Usage:
#   ./02_simulate_missing_index_scan.sh [simulate|fix] [--yes]
#
# Defaults: mode=simulate
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="simulate"
for arg in "$@"; do
    case "${arg}" in
        simulate|fix) MODE="${arg}" ;;
    esac
done

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")

echo "=== DRILL: Missing Index Causing Sequential Scan (mode=${MODE}) ==="

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

if [[ "${MODE}" == "simulate" ]]; then
    echo ""
    echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
    echo "    A single EXPLAIN above finishes in well under a second and only bumps"
    echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
    echo "    is measured from this statement's query_start, so it only crosses the"
    echo "    hunter's >=30s threshold near the END of the hold — a 90s hold keeps it"
    echo "    over threshold for a full 60s, comfortably wider than the poller's ~27s"
    echo "    tick cadence (vs. only ~5s of margin at the old 35s hold). Also bursts"
    echo "    1500 seq scans (seq_scan_tables, >1000 threshold) so that check fires too."
    hold_session_active "drill_missing_index_scan" \
        "SELECT * FROM slowq_orders WHERE status = 'failed'" 90
    run_seq_scan_burst "drill_missing_index_scan" \
        "1 FROM slowq_orders WHERE status = 'failed'" 1500
    wait "${HOLD_PID}" 2>/dev/null || true
fi

if [[ "${MODE}" == "fix" ]]; then
    confirm_drill "This will CREATE INDEX CONCURRENTLY idx_slowq_orders_status on slowq_orders — a schema change." "$@"
    echo ""
    echo "--- Applying fix: CREATE INDEX CONCURRENTLY idx_slowq_orders_status ---"
    "${PSQL[@]}" -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_slowq_orders_status ON slowq_orders(status);"

    echo ""
    echo "--- Re-running EXPLAIN after fix (expect Index Scan) ---"
    run_explain
fi

echo ""
echo "--- pg_stat_user_tables after ---"
"${PSQL[@]}" -c "SELECT relname, seq_scan, seq_tup_read, idx_scan
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

echo ""
echo "Drill complete. Run with 'fix' as the first argument to apply and verify the index fix."
