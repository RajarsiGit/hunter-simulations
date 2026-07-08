-- =============================================================================
-- 09_cleanup_slow_query_drill.sql
-- Slow Queries DRILL — cleanup: drops all slowq_* objects, ends drill sessions
-- SysCloud DAL Team
--
-- Usage:
--   psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE \
--        -f 09_cleanup_slow_query_drill.sql
-- =============================================================================

-- Terminate any lingering drill sessions (retry-storm etc.) first, so the
-- DROP TABLE below isn't blocked by a still-open drill connection.
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE application_name LIKE 'drill_%'
  AND pid <> pg_backend_pid()
  AND datname = current_database();

DROP TABLE IF EXISTS slowq_orders CASCADE;
DROP TABLE IF EXISTS slowq_customers CASCADE;
DROP TABLE IF EXISTS slowq_json_events CASCADE;

SELECT 'slow-queries drill objects dropped' AS status;
