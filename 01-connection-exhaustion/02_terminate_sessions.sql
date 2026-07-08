-- =============================================================================
-- 02_terminate_sessions.sql
-- Connection Exhaustion - Mitigation: Terminate Sessions
-- SysCloud DAL Team
--
-- SAFETY MODEL:
--   Pass -v dry_run=1 (default) to ONLY preview what would be terminated.
--   Pass -v dry_run=0 to ACTUALLY terminate.
--
-- Usage (preview - default, safe):
--   set -a; source .env; set +a
--   psql -v min_idle_minutes=5 -f 02_terminate_sessions.sql
--
-- Usage (execute termination):
--   psql -v dry_run=0 -v min_idle_minutes=5 -f 02_terminate_sessions.sql
--
-- Optional: target a specific application_name pattern (e.g. a drill tag)
--   psql -v dry_run=0 -v app_pattern='%drill_%' -f 02_terminate_sessions.sql
-- =============================================================================

-- \set dry_run 1
-- \set min_idle_minutes 5
\set app_pattern '%'

\if :dry_run
\echo '*** DRY RUN MODE — no sessions will be terminated. Pass -v dry_run=0 to execute. ***'
\else
\echo '*** LIVE MODE — sessions matching criteria WILL be terminated. ***'
\endif

\echo ''
\echo '--- PREVIEW: idle-in-transaction sessions older than :min_idle_minutes minutes ---'
SELECT pid, usename, application_name,
       now() - state_change AS duration,
       left(query, 100) AS last_query
FROM   pg_stat_activity
WHERE  state = 'active'
  AND  state_change < now() - (:'min_idle_minutes' || ' minutes')::interval
  AND  application_name ILIKE :'app_pattern'
ORDER  BY duration DESC;

\if :dry_run
\echo ''
\echo 'Dry run complete. No action taken.'
\else
\echo ''
\echo '--- TERMINATING matched sessions ---'
SELECT pg_terminate_backend(pid) AS terminated, pid, usename, application_name
FROM   pg_stat_activity
WHERE  state = 'active'
  AND  state_change < now() - (:'min_idle_minutes' || ' minutes')::interval
  AND  application_name ILIKE :'app_pattern'
  AND  pid <> pg_backend_pid();
\echo 'Termination pass complete. Re-run diagnostics (01_diagnostic_queries.sql) to confirm resolution.'
\endif

-- -----------------------------------------------------------------------------
-- Terminate a SINGLE specific PID (manual, ad-hoc use):
--   Uncomment and run separately, replacing <PID>.
-- -----------------------------------------------------------------------------
-- SELECT pg_terminate_backend(<PID>);

-- -----------------------------------------------------------------------------
-- NOTE: pg_cancel_backend() does NOT work on idle-in-transaction sessions
-- (no active query to cancel — it returns TRUE but does nothing).
-- Always use pg_terminate_backend() for idle-in-transaction blockers.
-- -----------------------------------------------------------------------------
