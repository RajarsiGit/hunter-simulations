-- =============================================================================
-- 19_cleanup_drill_sessions.sql
-- Locks & Deadlocks DRILL — Generic Session Cleanup
-- SysCloud DAL Team
--
-- Terminates ANY session whose application_name matches a drill tag,
-- regardless of state (active, idle, idle in transaction). Use this to end
-- any drill in this folder (02-18) before its sessions self-expire.
--
-- Run directly against the RDS endpoint (port 5432), not PgBouncer —
-- terminating the backend also drops the corresponding PgBouncer server slot.
--
-- Usage:
--   psql -h <rds-endpoint> -p 5432 -U <superuser> -d <dbname> \
--        -v app_pattern='%drill_%' \
--        -f 19_cleanup_drill_sessions.sql
--
-- Defaults to matching every drill tag used in this folder. Override
-- app_pattern to target just one, e.g. '%drill_row_lock_blocker%'.
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
\echo 'Cleanup complete. Re-run 09_lock_triage_queries.sql to confirm the fleet is clear.'
