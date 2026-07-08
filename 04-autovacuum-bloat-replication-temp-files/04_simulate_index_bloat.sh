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
# pg_stat_user_indexes (size + scan usage) and remediation via
# REINDEX INDEX CONCURRENTLY / dropping an unused index.
#
# Usage:
#   ./04_simulate_index_bloat.sh [row_count] [--yes]
#
# Example:
#   ./04_simulate_index_bloat.sh 500000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-500000}"

confirm_drill "This creates a dedicated index_bloat_drill table (${ROW_COUNT} rows) with 4 indexes, then churns it with updates so the indexes bloat relative to the table." "$@"

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
         ANALYZE index_bloat_drill;"

echo ""
echo "--- Churning: repeated UPDATEs touching all indexed columns ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_index_bloat';
         DO \$\$
         DECLARE i int;
         BEGIN
             FOR i IN 1..30 LOOP
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
echo "--- Remediation demo: REINDEX CONCURRENTLY on the payload index ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "REINDEX INDEX CONCURRENTLY idx_index_bloat_drill_payload;" 2>&1 | sed 's/^/  [REINDEX] /'

echo ""
echo "--- Index sizes AFTER REINDEX CONCURRENTLY ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS index_size, idx_scan
         FROM pg_stat_user_indexes
         WHERE relname = 'index_bloat_drill'
         ORDER BY pg_relation_size(indexrelid) DESC;"

echo ""
echo "If an index shows idx_scan=0 and no application depends on it, drop it:"
echo "  DROP INDEX CONCURRENTLY idx_index_bloat_drill_payload;"
echo ""
echo "For fillfactor-tuned hot-update tables: ALTER TABLE ... SET (fillfactor = 80);"
echo "(requires a VACUUM FULL / table rewrite to take effect on existing data)."
echo ""
echo "Drill complete. Run 11_cleanup_bloat_drill.sql when finished with this topic's drills."
