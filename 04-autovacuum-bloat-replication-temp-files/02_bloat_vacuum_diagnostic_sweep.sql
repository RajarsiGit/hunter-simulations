-- =============================================================================
-- 02_bloat_vacuum_diagnostic_sweep.sql
-- Autovacuum / Bloat / Replication / Temp Files — full first-response sweep
-- SysCloud DAL Team
--
-- Read-only detection queries. Run this first on any incident in this
-- category — no setup required, safe against production. Source: gpt-docs
-- "RDS PostgreSQL Investigation Guide" §3.3/§4.3/§5.3 and
-- "RDS Postgres Issue Guide" storage/WAL/CPU investigation checklists.
--
-- Usage:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
--        -f 02_bloat_vacuum_diagnostic_sweep.sql
-- =============================================================================

\echo '=== §1 Dead tuple / vacuum overview (top 50 by dead tuples) ==='
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n_dead_tup DESC
LIMIT 50;

\echo '=== §2 Tables not vacuumed recently (>10k dead tuples) ==='
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    now() - last_autovacuum AS since_last_autovacuum
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND n_dead_tup > 10000
ORDER BY last_autovacuum NULLS FIRST, n_dead_tup DESC;

\echo '=== §3 Transaction ID wraparound risk (database + table level) ==='
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    2000000000 - age(datfrozenxid) AS tx_remaining_before_wraparound
FROM pg_database
ORDER BY xid_age DESC;

SELECT
    c.oid::regclass AS table_name,
    age(c.relfrozenxid) AS xid_age,
    c.relpages,
    c.reltuples
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY xid_age DESC
LIMIT 50;
-- Note: forcing genuine wraparound is not a drillable scenario (needs
-- billions of transactions) — this is diagnostic-only. Alert well before
-- tx_remaining_before_wraparound gets uncomfortably small.

\echo '=== §4 Autovacuum workers currently running + progress ==='
SELECT
    pid, datname, application_name, state, wait_event_type, wait_event,
    now() - query_start AS runtime, left(query, 200) AS query
FROM pg_stat_activity
WHERE query ILIKE '%autovacuum%'
ORDER BY query_start;

SELECT
    pid, relid::regclass, phase, heap_blks_total, heap_blks_scanned, heap_blks_vacuumed
FROM pg_stat_progress_vacuum;

SHOW autovacuum_max_workers;
SHOW autovacuum_naptime;
SHOW autovacuum_vacuum_cost_delay;
SHOW autovacuum_vacuum_cost_limit;

\echo '=== §5 Table and index size (top 50) ==='
SELECT
    schemaname, relname,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_indexes_size(relid)) AS index_size,
    n_live_tup, n_dead_tup
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 50;

\echo '=== §6 Index bloat candidates (largest indexes + scan usage) ==='
SELECT
    schemaname, relname AS table_name, indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 50;

\echo '=== §7 Stale statistics candidates ==='
SELECT
    schemaname, relname, n_mod_since_analyze, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_mod_since_analyze DESC
LIMIT 50;

\echo '=== §8 Temp file usage — database level ==='
SELECT
    datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes,
    deadlocks, blk_read_time, blk_write_time
FROM pg_stat_database
ORDER BY temp_bytes DESC;

\echo '=== §9 Active queries likely creating temp files right now ==='
SELECT
    pid, usename, datname, application_name, state, wait_event_type, wait_event,
    now() - query_start AS query_age, left(query, 300) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND (query ILIKE '%order by%' OR query ILIKE '%group by%' OR query ILIKE '%distinct%'
       OR query ILIKE '%create index%' OR query ILIKE '%hash%' OR query ILIKE '%join%')
ORDER BY query_start;

SHOW work_mem;
SHOW maintenance_work_mem;
SHOW temp_file_limit;
SHOW log_temp_files;

\echo '=== §10 Top SQL by temp block usage (requires pg_stat_statements) ==='
SELECT
    queryid, calls, total_exec_time, mean_exec_time, rows,
    temp_blks_read, temp_blks_written, left(query, 300) AS query
FROM pg_stat_statements
ORDER BY temp_blks_written DESC
LIMIT 20;

\echo '=== §11 Replication slots — retained WAL ==='
SELECT
    slot_name, plugin, slot_type, database, active, restart_lsn, confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;

\echo '=== §12 Physical replication status (run on primary) ==='
SELECT
    pid, usename, application_name, client_addr, state, sync_state,
    sent_lsn, write_lsn, flush_lsn, replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
    write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

\echo '=== §13 High-write tables (WAL pressure candidates) ==='
SELECT
    schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd, n_dead_tup
FROM pg_stat_user_tables
ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC
LIMIT 30;

\echo '=== §14 Long transactions (delays vacuum cleanup + WAL retention) ==='
SELECT
    pid, usename, application_name, state, backend_xmin,
    now() - xact_start AS xact_age, left(query, 200) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;

\echo 'Sweep complete. Cross-reference: long transactions pinning old snapshots are'
\echo 'also drilled in ../02-locks-deadlocks-blocking-queries (script 12).'
