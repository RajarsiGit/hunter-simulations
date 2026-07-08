#!/usr/bin/env bash
# =============================================================================
# 06_simulate_stale_statistics.sh
# Slow Queries DRILL — Stale Statistics Causing a Bad Plan
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
# MUTATES DATA: bulk-inserts 200k rows without ANALYZE. Drill-database only.
#
# A large data change (bulk insert of a value the planner has never seen at
# this frequency) leaves pg_stat_user_tables.n_mod_since_analyze high while
# last_analyze/last_autoanalyze stay stale — the planner's row-count estimate
# for that value becomes wrong until the next ANALYZE runs.
#
#   Simulate: bulk INSERT 200k customer_id=1/status='failed' rows, no ANALYZE
#             EXPLAIN (ANALYZE, BUFFERS)
#             SELECT * FROM slowq_orders WHERE customer_id = 1 AND status = 'failed';
#   Fix:      ANALYZE slowq_orders;  -- then rerun to compare estimated vs actual rows
#
# Usage:
#   ./06_simulate_stale_statistics.sh [simulate|fix] [--yes]
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

echo "=== DRILL: Stale Statistics Causing a Bad Plan (mode=${MODE}) ==="

confirm_drill "This bulk-inserts 200,000 rows into slowq_orders WITHOUT running ANALYZE, to make the planner's row estimates stale — mutates drill data." "$@"

echo ""
echo "--- pg_stat_user_tables before insert ---"
"${PSQL[@]}" -c "SELECT relname, last_analyze, last_autoanalyze, n_live_tup, n_dead_tup, n_mod_since_analyze
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

if [[ "${MODE}" == "simulate" ]]; then
    echo ""
    echo "--- Making staleness deterministic (else this races autovacuum's autoanalyze) ---"
    echo "    01_setup already ran ANALYZE on this table, so last_analyze is currently"
    echo "    recent (not stale) — the hunter's stale_stats check (stats_never_analyzed /"
    echo "    stats_stale, see AI-Hunters/queries/slow-queries/slow-queries-stale-stats.sql)"
    echo "    needs last_analyze/last_autoanalyze to be NULL or >7 days old. This disables"
    echo "    per-table autovacuum (so autoanalyze can never quietly refresh it again) and"
    echo "    resets this table's stat counters to null out last_analyze/last_autoanalyze."
    echo "    NOTE: pg_stat_reset_single_table_counters also zeroes seq_scan/idx_scan for"
    echo "    this table — do not run this drill back-to-back with 02's seq_scan burst."
    "${PSQL[@]}" -c "ALTER TABLE slowq_orders SET (autovacuum_enabled = false);"
    "${PSQL[@]}" -c "SELECT pg_stat_reset_single_table_counters('slowq_orders'::regclass);"
fi

echo ""
echo "--- Bulk inserting 200,000 customer_id=1 / status='failed' rows (no ANALYZE) ---"
"${PSQL[@]}" -c "INSERT INTO slowq_orders (customer_id, status, amount, created_at)
                  SELECT 1, 'failed', 100, now()
                  FROM generate_series(1, 200000);"

echo ""
echo "--- pg_stat_user_tables after insert (note n_mod_since_analyze) ---"
"${PSQL[@]}" -c "SELECT relname, last_analyze, last_autoanalyze, n_live_tup, n_dead_tup, n_mod_since_analyze
                  FROM pg_stat_user_tables WHERE relname = 'slowq_orders';"

run_explain() {
    "${PSQL[@]}" -c "SET application_name = 'drill_stale_statistics';
                      EXPLAIN (ANALYZE, BUFFERS)
                      SELECT * FROM slowq_orders WHERE customer_id = 1 AND status = 'failed';"
}

echo ""
echo "--- EXPLAIN with stale statistics (compare 'rows=' estimate vs actual) ---"
run_explain

if [[ "${MODE}" == "fix" ]]; then
    echo ""
    echo "--- Applying fix: re-enable autovacuum + ANALYZE slowq_orders ---"
    "${PSQL[@]}" -c "ALTER TABLE slowq_orders RESET (autovacuum_enabled);"
    "${PSQL[@]}" -c "ANALYZE slowq_orders;"

    echo ""
    echo "--- Re-running EXPLAIN after ANALYZE (estimate should now match actual) ---"
    run_explain

    echo ""
    echo "For persistently skewed correlated columns, also consider:"
    echo "  CREATE STATISTICS st_slowq_orders_customer_status ON customer_id, status FROM slowq_orders;"
fi

echo ""
echo "Drill complete. Run with 'fix' as the first argument to apply and verify the ANALYZE fix."
