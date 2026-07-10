#!/usr/bin/env bash
# =============================================================================
# 03_simulate_table_bloat_update_churn.sh
# Autovacuum/Bloat DRILL — Heavy UPDATE/DELETE Churn Outpaces Autovacuum
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_bloat_drill_tables.sql.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §3.5 (Scenario A1)
#         and "RDS Postgres Issue Guide" §3.3 Scenario 3 (table bloat from
#         repeated update/delete).
#
# Reproduces: a table receives continuous UPDATE/DELETE churn faster than
# (auto)vacuum reclaims dead tuples, so n_dead_tup keeps climbing even while
# vacuum runs. Leaves the bloat in place (no VACUUM/REINDEX is run) so the
# hunter has a real window to detect it.
#
# Detectability — verified against C:\SysCloud\Production\AI-Hunters\queries\
# slow-queries\slow-queries-bloated-tables.sql (thresholds live in the
# slow-queries hunter, actions/slow-queries.jsonc — this topic's OWN hunter,
# autovacuum-bloat-replication-temp-files.jsonc, only owns temp-file-spill
# and config-hygiene checks, NOT table bloat):
#   T-4 table_high_bloat     warning  — dead_tup_ratio > 0.30, total_tuples > 10000
#   T-3 table_critical_bloat critical — dead_tup_ratio > 0.60 (same floor)
# Autovacuum is now explicitly disabled on the table before churning (was
# previously left to chance — autovacuum could race in between UPDATE rounds
# and quietly vacuum the bloat away before the hunter's poll ever saw it).
# This also deterministically fires two more real checks from
# slow-queries-autovacuum-disabled.sql:
#   AV-1 autovacuum_disabled          warning  — autovacuum_enabled=false in reloptions
#   AV-2 autovacuum_disabled_bloated  critical — same + dead_tup_ratio > 0.20
#
# Usage:
#   ./03_simulate_table_bloat_update_churn.sh [row_count] [churn_rounds] [--yes]
#
# Defaults: row_count=1000000, churn_rounds=80 — with autovacuum disabled,
# 80 rounds each updating ~10% of rows drives dead_tup ≈ 8,000,000 against
# ~1,000,000 live rows (ratio ≈ 0.89), ~50% above the 0.60 CRITICAL floor —
# wide margin against run-to-run randomness in exactly which rows collide.
#
# Example: 1M rows, 80 churn rounds
#   ./03_simulate_table_bloat_update_churn.sh 1000000 80
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-1000000}"
CHURN_ROUNDS="${2:-80}"

confirm_drill "This creates/populates bloat_drill_records with ${ROW_COUNT} rows, disables autovacuum on it, then runs ${CHURN_ROUNDS} rounds of UPDATE churn to build up dead tuples with nothing ever reclaiming them." "$@"

echo ""
echo "=== DRILL: Table Bloat from UPDATE/DELETE Churn (Investigation Guide §3.5 / Issue Guide §3.3-Scenario3) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT} | churn_rounds=${CHURN_ROUNDS}"

echo ""
echo "--- Seeding bloat_drill_records (idempotent — only inserts if empty) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_av_bloat_churn';
         INSERT INTO bloat_drill_records (tenant_id, status, payload)
         SELECT (random() * 100)::int, 'ACTIVE', repeat(md5(random()::text), 20)
         FROM generate_series(1, ${ROW_COUNT})
         WHERE NOT EXISTS (SELECT 1 FROM bloat_drill_records LIMIT 1);
         ANALYZE bloat_drill_records;"

echo ""
echo "--- Baseline dead-tuple stats ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, autovacuum_count
         FROM pg_stat_all_tables WHERE relname = 'bloat_drill_records';"

echo ""
echo "--- Disabling autovacuum on bloat_drill_records (drill-only — guarantees the"
echo "    bloat isn't quietly reclaimed between churn rounds; also fires AV-1/AV-2) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER TABLE bloat_drill_records SET (autovacuum_enabled = false);"

echo ""
echo "--- Generating churn: ${CHURN_ROUNDS} UPDATE rounds (every 10th row each round) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_av_bloat_churn';
         DO \$\$
         DECLARE i int;
         BEGIN
             FOR i IN 1..${CHURN_ROUNDS} LOOP
                 UPDATE bloat_drill_records
                 SET payload = repeat(md5(random()::text), 20), updated_at = now()
                 WHERE id % 10 = 0;
                 COMMIT;
             END LOOP;
         END \$\$;"

echo ""
echo "--- Dead-tuple stats AFTER churn (n_dead_tup should be materially higher) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT relname, n_tup_upd, n_tup_del, n_dead_tup, last_autovacuum
         FROM pg_stat_user_tables WHERE relname = 'bloat_drill_records';"

echo ""
echo "Remediation reference (NOT applied — bloat is left in place for the hunter"
echo "to detect): VACUUM (VERBOSE, ANALYZE) bloat_drill_records; and for severe,"
echo "already-bloated indexes: REINDEX INDEX CONCURRENTLY <name>; or tune"
echo "table-level autovacuum:"
echo ""
echo "  ALTER TABLE bloat_drill_records SET ("
echo "      autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 5000,"
echo "      autovacuum_analyze_scale_factor = 0.01, autovacuum_analyze_threshold = 5000);"
echo ""
ensure_min_duration 20
echo "Drill complete."
