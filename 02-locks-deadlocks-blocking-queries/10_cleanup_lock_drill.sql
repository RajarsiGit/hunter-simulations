-- =============================================================================
-- 10_cleanup_lock_drill.sql
-- Locks & Deadlocks DRILL — Full Cleanup
-- SysCloud DAL Team
--
-- Removes all tables, indexes, and materialized views created by
-- 01_setup_lock_drill_tables.sql and terminates any remaining drill sessions
-- tagged with 'drill_*' application names.
--
-- Safe to run at any point during or after a drill.
-- Does NOT touch non-drill objects.
--
-- psql does not read .env itself — export the vars first, e.g.:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
--     -f 10_cleanup_lock_drill.sql
-- =============================================================================

\echo '=== Locks & Deadlocks Drill — Cleanup ==='
\echo ''

-- ---------------------------------------------------------------------------
-- Step 1: Terminate any remaining drill sessions
--         Matches all application_name patterns used by scripts 02–18.
-- ---------------------------------------------------------------------------
\echo '--- Step 1: Terminating active drill sessions ---'

SELECT pid,
       application_name,
       state,
       pg_terminate_backend(pid) AS terminated
FROM   pg_stat_activity
WHERE  application_name LIKE 'drill_%'
  AND  pid <> pg_backend_pid();

\echo ''

-- ---------------------------------------------------------------------------
-- Step 2: Drop drill indexes (created by 05_simulate_ddl_blocking_dml.sh,
--         15_simulate_index_blocking.sh, and 01_setup_lock_drill_tables.sql)
-- ---------------------------------------------------------------------------
\echo '--- Step 2: Dropping drill indexes ---'

DROP INDEX IF EXISTS idx_drill_balance;
DROP INDEX IF EXISTS idx_drill_index_blocking_balance;
DROP INDEX IF EXISTS idx_lock_test_mvw_category;
DROP INDEX IF EXISTS idx_lock_test_child_parent_id;

\echo '  Drill indexes dropped.'
\echo ''

-- ---------------------------------------------------------------------------
-- Step 3: Drop materialized view
-- ---------------------------------------------------------------------------
\echo '--- Step 3: Dropping materialized view ---'

DROP MATERIALIZED VIEW IF EXISTS lock_test_mvw;

\echo '  lock_test_mvw dropped.'
\echo ''

-- ---------------------------------------------------------------------------
-- Step 4: Drop drill tables (CASCADE handles FK child → parent ordering)
-- ---------------------------------------------------------------------------
\echo '--- Step 4: Dropping drill tables ---'

DROP TABLE IF EXISTS lock_test_child          CASCADE;
DROP TABLE IF EXISTS lock_test_parent         CASCADE;
DROP TABLE IF EXISTS lock_test_workflow_jobs  CASCADE;
DROP TABLE IF EXISTS lock_test_job_queue      CASCADE;
DROP TABLE IF EXISTS lock_test_credits        CASCADE;
DROP TABLE IF EXISTS lock_test_mvw_base       CASCADE;
DROP TABLE IF EXISTS lock_test_accounts       CASCADE;

\echo '  All lock_test_* tables dropped.'
\echo ''

-- ---------------------------------------------------------------------------
-- Step 5: Confirm clean state
-- ---------------------------------------------------------------------------
\echo '--- Step 5: Confirming no lock_test_* objects remain ---'

SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_name LIKE 'lock_test%';

\echo ''

\echo '--- Active drill sessions remaining (should be empty) ---'

SELECT pid, application_name, state
FROM   pg_stat_activity
WHERE  application_name LIKE 'drill_%'
  AND  pid <> pg_backend_pid();

\echo ''
\echo '=== Cleanup complete. ==='
