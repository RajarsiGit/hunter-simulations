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
# Detectability — verified against queries/slow-queries/slow-queries-stale-
# stats.sql (thresholds live in the slow-queries hunter, actions/slow-
# queries.jsonc — the SAME script pattern already used in
# ../03-slow-queries/06_simulate_stale_statistics.sh):
#   ST-1 stats_never_analyzed critical — n_live_tup > 100000 AND
#                                         last_analyze IS NULL AND last_autoanalyze IS NULL
#   ST-2 stats_stale          warning  — same floor, most recent ANALYZE > 7 days old
# CRITICAL FIX: the original version of this script ran a baseline ANALYZE
# for a "clean" EXPLAIN comparison, which leaves last_analyze freshly
# populated — ST-1 needs it NULL and ST-2 needs it 7+ days stale, so as
# originally written this script could never actually trip either check
# (only demonstrate the bad-plan EXPLAIN locally). Fixed by resetting
# bloat_drill_records' stat counters via pg_stat_reset_single_table_counters
# right after disabling autovacuum — this nulls last_analyze/
# last_autoanalyze, satisfying ST-1 deterministically instead of waiting a
# week for ST-2. NOTE: this also zeroes seq_scan/idx_scan/n_dead_tup for the
# table (same caveat as 03-slow-queries/06) — bloat_drill_records is shared
# with 03_simulate_table_bloat_update_churn.sh, so don't run 06 concurrently
# with (or right after) 03 if you need a clean T-3/T-4 bloat-ratio reading
# from that script; run_all.sh in this folder fires them concurrently by
# default, which is a known/accepted tradeoff for stacking load, not a bug.
#
# Usage:
#   ./06_simulate_stale_statistics_bad_plan.sh [row_count] [--yes]
#
# Default row_count=1000000 (was 500000) — 10x the ST-1/ST-2 n_live_tup >
# 100000 pre-filter, wide margin.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-1000000}"

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
echo "--- Nulling last_analyze/last_autoanalyze so ST-1 (never analyzed) fires ---"
echo "    instead of waiting 7 days for ST-2 (stale) — see header note above ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT pg_stat_reset_single_table_counters('bloat_drill_records'::regclass);"

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
