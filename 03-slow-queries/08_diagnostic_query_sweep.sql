-- =============================================================================
-- 08_diagnostic_query_sweep.sql
-- Slow Queries — full first-response diagnostic sweep
-- SysCloud DAL Team
--
-- Run first on any "queries are slow" report. Requires PGHOST/PGUSER/etc set
-- in the environment (e.g. `set -a; source .env; set +a` before invoking
-- psql, or via .pgpass) — psql itself does not read .env.
--
-- Usage:
--   psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE \
--        -f 08_diagnostic_query_sweep.sql
-- =============================================================================

\echo '=== 1. Currently active queries, longest-running first ==='
SELECT
    pid,
    usename,
    datname,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS duration,
    left(query, 200) AS query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC;

\echo ''
\echo '=== 2. CPU-heavy wait events (NULL wait_event_type among active = likely on-CPU) ==='
SELECT
    wait_event_type,
    wait_event,
    count(*)
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;

\echo ''
\echo '=== 3. Top queries by total execution time (requires pg_stat_statements) ==='
SELECT
    queryid,
    calls,
    round(total_exec_time::numeric, 2)  AS total_exec_time_ms,
    round(mean_exec_time::numeric, 2)   AS mean_exec_time_ms,
    rows,
    shared_blks_hit,
    shared_blks_read,
    temp_blks_written,
    left(query, 200) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

\echo ''
\echo '=== 4. Highest mean-latency queries called more than 10 times (possible N+1) ==='
SELECT
    calls,
    round(mean_exec_time::numeric, 2) AS mean_exec_time_ms,
    round(max_exec_time::numeric, 2)  AS max_exec_time_ms,
    rows,
    left(query, 200) AS query
FROM pg_stat_statements
WHERE calls > 10
ORDER BY mean_exec_time DESC
LIMIT 20;

\echo ''
\echo '=== 5. Missing-index candidates (high seq_scan + high seq_tup_read) ==='
SELECT
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan > 100
ORDER BY seq_tup_read DESC
LIMIT 30;

\echo ''
\echo '=== 6. Stale statistics candidates (high n_mod_since_analyze, old last_analyze) ==='
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    n_mod_since_analyze,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_mod_since_analyze DESC
LIMIT 20;

\echo ''
\echo '=== 7. Sessions grouped by application/client (retry-storm / connection-multiplication check) ==='
SELECT
    application_name,
    client_addr,
    count(*) AS sessions
FROM pg_stat_activity
GROUP BY application_name, client_addr
ORDER BY sessions DESC
LIMIT 20;

\echo ''
\echo '=== 8. Largest indexes with low usage (index bloat / unused-index candidates) ==='
SELECT
    schemaname,
    relname,
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

\echo ''
\echo 'NOTE: sections 3, 4 require: CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
\echo '      (also requires shared_preload_libraries=pg_stat_statements at the instance'
\echo '      parameter-group level on RDS, which needs a reboot to take effect).'
