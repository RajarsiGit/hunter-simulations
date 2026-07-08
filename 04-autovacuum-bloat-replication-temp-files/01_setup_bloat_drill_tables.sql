-- =============================================================================
-- 01_setup_bloat_drill_tables.sql
-- Autovacuum / Bloat / Replication / Temp Files DRILLS — shared setup
-- SysCloud DAL Team
--
-- Creates the empty table shells reused by the churn/index-bloat/stale-stats/
-- WAL drills in this folder (03, 04, 06, 09, 10). Safe to re-run — uses
-- CREATE TABLE IF NOT EXISTS, so it never wipes data from an in-progress
-- drill. Each simulate script populates/mutates these itself.
--
-- Large, size-parameterized tables used only by the temp-file-spill drills
-- (07, 08) are NOT created here — they're provisioned on demand inside those
-- scripts since their row count is a script argument.
--
-- Usage:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
--        -f 01_setup_bloat_drill_tables.sql
-- =============================================================================

CREATE TABLE IF NOT EXISTS bloat_drill_records (
    id          bigserial PRIMARY KEY,
    tenant_id   int,
    status      text,
    payload     text,
    updated_at  timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS wal_drill_records (
    id          bigserial PRIMARY KEY,
    payload     text,
    created_at  timestamptz DEFAULT now()
);

-- pg_stat_statements is required by several detection queries in
-- 02_bloat_vacuum_diagnostic_sweep.sql — create it if the instance allows
-- (RDS parameter group must have it in shared_preload_libraries; this just
-- registers the extension in this database).
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

\echo 'Setup complete: bloat_drill_records, wal_drill_records ready. pg_stat_statements ensured.'
