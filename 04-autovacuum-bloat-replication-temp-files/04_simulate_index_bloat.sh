#!/usr/bin/env bash
# =============================================================================
# 04_simulate_index_bloat.sh
# Autovacuum/Bloat DRILL — Index Bloat After Repeated Updates
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_bloat_drill_tables.sql.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §3.8 (Scenario A4)
#         and "RDS Postgres Issue Guide" §3.3 Scenario 2 (index bloat /
#         excessive index growth).
#
# Reproduces: several indexes on a churn table accumulate dead entries and
# grow disproportionately to the table itself. Shows detection via
# pg_stat_user_indexes (size + scan usage). No remediation (REINDEX / drop)
# is applied — the bloat is left in place for the hunter to detect.
#
# Detectability — HONEST NOTE: neither actions/slow-queries.jsonc nor
# actions/autovacuum-bloat-replication-temp-files.jsonc has a dedicated
# "index bloat %" check (pg_stat_user_indexes has no dead-tuple-ratio
# equivalent). What DOES fire is the underlying TABLE's own dead_tup_ratio —
# the churn UPDATEs that bloat the indexes also dead-tuple index_bloat_drill
# itself, which feeds the same table-bloat checks as script 03 (verified
# against queries/slow-queries/slow-queries-bloated-tables.sql):
#   T-4 table_high_bloat     warning  — dead_tup_ratio > 0.30, total_tuples > 10000
#   T-3 table_critical_bloat critical — dead_tup_ratio > 0.60
#   AV-1/AV-2 (slow-queries-autovacuum-disabled.sql) — autovacuum_enabled=false
#     (+ dead_tup_ratio > 0.20 for AV-2) — now fired deterministically, see below.
# The oversized-index angle itself is diagnostic-only (surfaced by
# 02_bloat_vacuum_diagnostic_sweep.sql), not independently hunter-detected.
#
# Usage:
#   ./04_simulate_index_bloat.sh [row_count] [--yes]
#
# Defaults: row_count=1000000, 50 churn rounds (was 30) touching ~1/7 of rows
# each round — with autovacuum now disabled, dead_tup ≈ 7,100,000 against
# ~1,000,000 live rows (ratio ≈ 0.88), well past the 0.60 CRITICAL floor.
#
# Example:
#   ./04_simulate_index_bloat.sh 1000000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-1000000}"

confirm_drill "This creates a dedicated index_bloat_drill table (${ROW_COUNT} rows) with 4 indexes, disables autovacuum on it, then churns it with updates so both the indexes and the table itself bloat." "$@"

echo ""
echo "=== DRILL: Index Bloat After Repeated Updates (Investigation Guide §3.8 / Issue Guide §3.3-Scenario2) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT}"

echo ""
echo "--- Setting up index_bloat_drill + 4 indexes (idempotent) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_index_bloat';
         CREATE TABLE IF NOT EXISTS index_bloat_drill (
             id bigserial PRIMARY KEY,
             tenant_id int,
             status text,
             created_at timestamptz,
             payload text
         );
         INSERT INTO index_bloat_drill (tenant_id, status, created_at, payload)
         SELECT (random()*1000)::int, md5(random()::text),
                now() - (random() * interval '365 days'), repeat(md5(random()::text), 50)
         FROM generate_series(1, ${ROW_COUNT})
         WHERE NOT EXISTS (SELECT 1 FROM index_bloat_drill LIMIT 1);
         CREATE INDEX IF NOT EXISTS idx_index_bloat_drill_tenant  ON index_bloat_drill(tenant_id);
         CREATE INDEX IF NOT EXISTS idx_index_bloat_drill_status  ON index_bloat_drill(status);
         CREATE INDEX IF NOT EXISTS idx_index_bloat_drill_created ON index_bloat_drill(created_at);
         CREATE INDEX IF NOT EXISTS idx_index_bloat_drill_payload ON index_bloat_drill(payload);
         ANALYZE index_bloat_drill;
         ALTER TABLE index_bloat_drill SET (autovacuum_enabled = false);"

echo ""
echo "--- Churning: repeated UPDATEs touching all indexed columns (autovacuum disabled"
echo "    on this table, so accumulated bloat is never quietly reclaimed) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_index_bloat';
         DO \$\$
         DECLARE i int;
         BEGIN
             FOR i IN 1..50 LOOP
                 UPDATE index_bloat_drill
                 SET status = md5(random()::text), payload = repeat(md5(random()::text), 50)
                 WHERE id % 7 = 0;
                 COMMIT;
             END LOOP;
         END \$\$;"

echo ""
echo "--- Detect: index sizes vs. scan usage (idx_scan=0 candidates are drop targets) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS index_size, idx_scan
         FROM pg_stat_user_indexes
         WHERE relname = 'index_bloat_drill'
         ORDER BY pg_relation_size(indexrelid) DESC;"

echo ""
echo "Remediation reference (NOT applied — bloat is left in place for the hunter"
echo "to detect): REINDEX INDEX CONCURRENTLY idx_index_bloat_drill_payload; or, if"
echo "an index shows idx_scan=0 and no application depends on it, drop it:"
echo "  DROP INDEX CONCURRENTLY idx_index_bloat_drill_payload;"
echo ""
echo "For fillfactor-tuned hot-update tables: ALTER TABLE ... SET (fillfactor = 80);"
echo "(requires a VACUUM FULL / table rewrite to take effect on existing data)."
echo ""
ensure_min_duration 90
echo "Drill complete."
