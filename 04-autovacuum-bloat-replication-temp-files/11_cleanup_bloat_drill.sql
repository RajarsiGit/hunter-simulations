-- =============================================================================
-- 11_cleanup_bloat_drill.sql
-- Autovacuum / Bloat / Replication / Temp Files — drill cleanup
-- SysCloud DAL Team
--
-- Terminates any remaining drill_* sessions from this topic and drops all
-- objects created by scripts 01-10. Safe to re-run.
--
-- Usage:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
--        -f 11_cleanup_bloat_drill.sql
-- =============================================================================

\echo '--- Terminating any lingering drill sessions ---'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE application_name LIKE 'drill_av_%'
   OR application_name LIKE 'drill_index_bloat%'
   OR application_name LIKE 'drill_stale_stats%'
   OR application_name LIKE 'drill_temp_spill_%'
   OR application_name LIKE 'drill_create_index_temp_spike%'
   OR application_name LIKE 'drill_repl_slot_wal%'
   OR application_name LIKE 'drill_replica_lag_writer%';

\echo '--- Dropping the (intentionally unconsumed) drill replication slot, if present ---'
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name = 'drill_inactive_slot' AND NOT active;

\echo '--- Dropping drill tables ---'
DROP TABLE IF EXISTS bloat_drill_records;
DROP TABLE IF EXISTS wal_drill_records;
DROP TABLE IF EXISTS index_bloat_drill;
DROP TABLE IF EXISTS temp_spill_sort_drill;
DROP TABLE IF EXISTS temp_spill_join_a;
DROP TABLE IF EXISTS temp_spill_join_b;
DROP TABLE IF EXISTS temp_spill_group_drill;

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT tablename FROM pg_tables
        WHERE tablename LIKE 'av_starvation_drill_%'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I', r.tablename);
    END LOOP;
END $$;

\echo 'Cleanup complete.'
