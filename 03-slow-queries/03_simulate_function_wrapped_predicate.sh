#!/usr/bin/env bash
# =============================================================================
# 03_simulate_function_wrapped_predicate.sh
# Slow Queries DRILL — Function on Indexed Column Defeats the Index
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
#
# A plain b-tree index on `email` does NOT help a query that wraps the column
# in a function (`lower(email) = ...`) — the planner falls back to a seq scan
# because the index is built on the raw column value, not the function result.
#
#   Simulate: CREATE INDEX idx_slowq_customers_email ON slowq_customers(email);
#             EXPLAIN (ANALYZE, BUFFERS)
#             SELECT * FROM slowq_customers WHERE lower(email) = lower('user100@example.com');
#             -- still a Seq Scan despite the plain index existing
#
# Usage:
#   ./03_simulate_function_wrapped_predicate.sh [--yes]
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")
TARGET_EMAIL="user100@example.com"

echo "=== DRILL: Function-Wrapped Predicate Defeats Plain Index ==="

confirm_drill "This creates a plain index on slowq_customers(email) to demonstrate it does NOT help lower(email) queries — a schema change." "$@"

echo ""
echo "--- Creating plain (non-expression) index on email ---"
"${PSQL[@]}" -c "CREATE INDEX IF NOT EXISTS idx_slowq_customers_email ON slowq_customers(email);"

run_explain() {
    "${PSQL[@]}" -c "SET application_name = 'drill_function_predicate';
                      EXPLAIN (ANALYZE, BUFFERS)
                      SELECT * FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}');"
}

echo ""
echo "--- EXPLAIN with plain index in place (expect Seq Scan — the plain index cannot be used) ---"
run_explain

echo ""
echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
echo "    is measured from this statement's query_start, so a 2400s hold clears"
echo "    not just query_slow's >=30s warning threshold but query_critical's"
echo "    >=1800s CRITICAL threshold too (actions/slow-queries.jsonc Q-2), with"
echo "    600s to spare over the hunter's 300s poll interval (>=7 ticks of"
echo "    overlap — EXTREME margin), so query_slow/query_critical reliably fire."
echo "    slowq_customers is now seeded at 3M rows (01_setup), way above the"
echo "    hunter's n_live_tup > 100k pre-filter, so seq_scan_tables fires too."
hold_session_active "drill_function_predicate" \
    "SELECT * FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" 2400
run_seq_scan_burst "drill_function_predicate" \
    "1 FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" 200000
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Drill complete."
