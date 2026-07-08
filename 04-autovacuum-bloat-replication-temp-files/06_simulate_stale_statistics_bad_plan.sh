#!/usr/bin/env bash
# =============================================================================
# 06_simulate_stale_statistics_bad_plan.sh
# Autovacuum/Bloat DRILL — Stale Statistics Cause Bad Query Plans
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_bloat_drill_tables.sql.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §3.9 (Scenario A5).
#
# Reproduces: autoanalyze is disabled on a table (simulating "didn't run
# frequently enough"), a bulk data-shape change happens, and the planner's
# stale row-count/selectivity estimate produces a bad plan. Leaves autovacuum
# disabled and statistics stale (no ANALYZE is run) so the hunter has a real
# window to detect it.
#
# Usage:
#   ./06_simulate_stale_statistics_bad_plan.sh [row_count] [--yes]
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-500000}"

confirm_drill "This disables autovacuum/autoanalyze on bloat_drill_records, bulk-updates it so its data shape no longer matches planner statistics, and shows the resulting bad EXPLAIN plan. Autovacuum is left disabled and statistics left stale." "$@"

echo ""
echo "=== DRILL: Stale Statistics Cause Bad Query Plans (Investigation Guide §3.9 / Scenario A5) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT}"

echo ""
echo "--- Seeding bloat_drill_records if empty, then ANALYZE for a clean baseline ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_stale_stats';
         INSERT INTO bloat_drill_records (tenant_id, status, payload)
         SELECT (random() * 100)::int, 'ACTIVE', repeat(md5(random()::text), 20)
         FROM generate_series(1, ${ROW_COUNT})
         WHERE NOT EXISTS (SELECT 1 FROM bloat_drill_records LIMIT 1);
         ANALYZE bloat_drill_records;"

echo ""
echo "--- Disabling autovacuum/autoanalyze on bloat_drill_records (drill-only) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER TABLE bloat_drill_records SET (autovacuum_enabled = false);"

echo ""
echo "--- Skewing the data: making tenant_id=999 suddenly 30% of the table (no ANALYZE after) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_stale_stats';
         UPDATE bloat_drill_records SET tenant_id = 999
         WHERE id % 3 = 0;"

echo ""
echo "--- Stale-statistics candidates (n_mod_since_analyze climbing, no autoanalyze) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT relname, n_mod_since_analyze, last_analyze, last_autoanalyze
         FROM pg_stat_user_tables WHERE relname = 'bloat_drill_records';"

echo ""
echo "--- EXPLAIN with STALE statistics (row estimate likely far off actual) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM bloat_drill_records WHERE tenant_id = 999 AND status = 'ACTIVE';" \
     2>&1 | sed 's/^/  [stale plan] /'

echo ""
echo "Remediation reference (NOT applied — autovacuum stays disabled and statistics"
echo "stay stale for the hunter to detect): ANALYZE bloat_drill_records; ALTER TABLE"
echo "bloat_drill_records SET (autovacuum_enabled = true); For persistently skewed"
echo "columns, also raise the statistics target instead of relying on the default"
echo "sample size:"
echo "  ALTER TABLE bloat_drill_records ALTER COLUMN tenant_id SET STATISTICS 1000;"
echo "  ANALYZE bloat_drill_records;"
echo ""
ensure_min_duration 90
echo "Drill complete."
