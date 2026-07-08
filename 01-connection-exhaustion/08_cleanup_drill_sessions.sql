-- =============================================================================
-- 08_cleanup_drill_sessions.sql
-- Connection Exhaustion DRILL — Generic Cleanup
-- SysCloud DAL Team
--
-- Terminates ANY session whose application_name matches a drill tag,
-- regardless of state (active, idle, idle in transaction). Use this after
-- 06/07/09/10/11 if you need to end a drill before sessions self-expire.
--
-- Run directly against the RDS endpoint (port 5432), not PgBouncer —
-- terminating the backend also drops the corresponding PgBouncer server slot.
--
-- Usage:
--   psql -v app_pattern='%drill_%' -f 08_cleanup_drill_sessions.sql
--
-- Defaults to matching all drill_* tags used in this folder. Override
-- app_pattern to target just one, e.g. '%drill_idle_txn%'.
-- =============================================================================

\set app_pattern '%drill_%'

\echo '--- PREVIEW: sessions matching :app_pattern ---'
SELECT pid, usename, application_name, state, now() - state_change AS age
FROM   pg_stat_activity
WHERE  application_name ILIKE :'app_pattern'
ORDER  BY age DESC;

\echo ''
\echo '--- TERMINATING matched sessions ---'
SELECT pg_terminate_backend(pid) AS terminated, pid, application_name
FROM   pg_stat_activity
WHERE  application_name ILIKE :'app_pattern'
  AND  pid <> pg_backend_pid();

\echo ''
\echo 'Cleanup complete. Re-run 01_diagnostic_queries.sql to confirm the fleet is clear.'
