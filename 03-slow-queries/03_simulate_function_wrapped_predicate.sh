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
#   ./03_simulate_function_wrapped_predicate.sh [hold_seconds] [--yes]
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
echo "--- Sustaining load briefly so pg_stat_activity/seq_scan show a signal ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1. This holds the session active for a few seconds and"
echo "    bursts a couple thousand seq scans (seq_scan_tables, >1000 threshold)"
echo "    so a quick poll can catch it — sized for a <=20s drill run, not for"
echo "    clearing the hunter's 300s poll interval/query_critical threshold."
echo "    slowq_customers is seeded at 150k rows (01_setup), above the hunter's"
echo "    n_live_tup > 100k pre-filter, so seq_scan_tables can still fire."
hold_session_active "drill_function_predicate" \
    "SELECT * FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" "${HOLD_SECONDS}"
run_seq_scan_burst "drill_function_predicate" \
    "1 FROM slowq_customers WHERE lower(email) = lower('${TARGET_EMAIL}')" 2000
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Drill complete."
