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
# vacuum runs. Shows the fix: VACUUM (VERBOSE, ANALYZE), and for severe bloat,
# REINDEX CONCURRENTLY on any affected index.
#
# Usage:
#   ./03_simulate_table_bloat_update_churn.sh [row_count] [churn_rounds] [--yes]
#
# Example: 500k rows, 50 churn rounds
#   ./03_simulate_table_bloat_update_churn.sh 500000 50
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-500000}"
CHURN_ROUNDS="${2:-50}"

confirm_drill "This creates/populates bloat_drill_records with ${ROW_COUNT} rows, then runs ${CHURN_ROUNDS} rounds of UPDATE churn on it to build up dead tuples faster than autovacuum can clean them." "$@"

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
echo "--- Remediation: VACUUM (VERBOSE, ANALYZE) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "VACUUM (VERBOSE, ANALYZE) bloat_drill_records;" 2>&1 | sed 's/^/  [VACUUM] /'

echo ""
echo "--- Dead-tuple stats AFTER manual VACUUM ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT relname, n_live_tup, n_dead_tup, last_vacuum
         FROM pg_stat_all_tables WHERE relname = 'bloat_drill_records';"

echo ""
echo "If bloat persists after VACUUM (e.g. a long transaction is pinning an old"
echo "snapshot), see ../02-locks-deadlocks-blocking-queries/12_simulate_long_txn_vacuum_bloat.sh"
echo "(the long-txn-blocks-vacuum drill), or tune table-level autovacuum:"
echo ""
echo "  ALTER TABLE bloat_drill_records SET ("
echo "      autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 5000,"
echo "      autovacuum_analyze_scale_factor = 0.01, autovacuum_analyze_threshold = 5000);"
echo ""
echo "For severe, already-bloated indexes: REINDEX INDEX CONCURRENTLY <name>;"
echo "Drill complete. Run 11_cleanup_bloat_drill.sql when finished with this topic's drills."
