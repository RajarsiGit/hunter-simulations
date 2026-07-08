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
#   Fix:      CREATE INDEX CONCURRENTLY idx_slowq_customers_lower_email
#             ON slowq_customers (lower(email));  -- expression index
#
# Usage:
#   ./03_simulate_function_wrapped_predicate.sh [simulate|fix] [--yes]
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
TARGET_EMAIL="user100@example.com"

echo "=== DRILL: Function-Wrapped Predicate Defeats Plain Index (mode=${MODE}) ==="

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

if [[ "${MODE}" == "simulate" ]]; then
    echo ""
    echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
    echo "    A single EXPLAIN above finishes in well under a second and only bumps"
    echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
    echo "    is measured from this statement's query_start, so it only crosses the"
    echo "    hunter's >=30s threshold near the END of the hold — a 90s hold keeps it"
    echo "    over threshold for a full 60s, comfortably wider than the poller's ~27s"
    echo "    tick cadence (vs. only ~5s of margin at the old 35s hold), so query_slow"
    echo "    reliably fires. NOTE: seq_scan_tables still won't fire for this table —"
    echo "    slowq_customers has only 50k rows, below the hunter's n_live_tup > 100k"
    echo "    pre-filter, regardless of hold duration or seq_scan_ratio."
    hold_session_active "drill_function_predicate" \
        "SELECT * FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" 90
    run_seq_scan_burst "drill_function_predicate" \
        "1 FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" 1500
    wait "${HOLD_PID}" 2>/dev/null || true
fi

if [[ "${MODE}" == "fix" ]]; then
    echo ""
    echo "--- Applying fix: CREATE INDEX CONCURRENTLY on lower(email) (expression index) ---"
    "${PSQL[@]}" -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_slowq_customers_lower_email ON slowq_customers (lower(email));"

    echo ""
    echo "--- Re-running EXPLAIN after fix (expect Index Scan on the expression index) ---"
    run_explain
fi

echo ""
echo "Drill complete. Run with 'fix' as the first argument to apply and verify the expression-index fix."
echo "Alternative fix (not scripted): store a normalized email column and index that instead."
