-- =============================================================================
-- 01_diagnostic_queries.sql
-- Connection Exhaustion - Diagnostic Suite
-- SysCloud DAL Team
--
-- Usage:
--   set -a; source .env; set +a   # loads PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE
--   psql -f 01_diagnostic_queries.sql
-- (psql itself only reads PG* env vars / ~/.pgpass — it does not source .env,
--  so export the values into the shell first, or pass -h/-p/-U/-d explicitly.)
--
-- NOTE: Connect directly to RDS on port 5432 (NOT via PgBouncer) so
-- pg_stat_activity reflects true backend state.
-- =============================================================================

\echo '========================================================================='
\echo '1. ACTIVE & BLOCKED SESSIONS'
\echo '========================================================================='
SELECT pid, usename, application_name, state, wait_event_type, wait_event,
       now() - query_start AS query_age,
       now() - state_change AS state_age,
       left(query, 100) AS query_snippet
FROM   pg_stat_activity
WHERE  state <> 'idle'
ORDER  BY query_age DESC NULLS LAST;

\echo ''
\echo '========================================================================='
\echo '2. BLOCKING TREE (who is blocking whom)'
\echo '========================================================================='
SELECT blocked.pid          AS blocked_pid,
       blocked.usename      AS blocked_user,
       blocked.query        AS blocked_query,
       blocker.pid          AS blocker_pid,
       blocker.state        AS blocker_state,
       blocker.query        AS blocker_query,
       blocker.wait_event   AS blocker_wait_event
FROM   pg_stat_activity AS blocked
JOIN   pg_stat_activity AS blocker
         ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE  cardinality(pg_blocking_pids(blocked.pid)) > 0;

\echo ''
\echo '========================================================================='
\echo '3. LONG IDLE-IN-TRANSACTION SESSIONS (> 5 min)'
\echo '========================================================================='
SELECT pid, usename, application_name, state,
       now() - state_change AS idle_in_txn_duration,
       left(query, 120) AS last_query
FROM   pg_stat_activity
WHERE  state = 'idle in transaction'
  AND  state_change < now() - interval '5 minutes'
ORDER  BY idle_in_txn_duration DESC;

\echo ''
\echo '========================================================================='
\echo '4. CONNECTION USAGE BY DATABASE AND USER'
\echo '========================================================================='
SELECT datname, usename, state,
       COUNT(*) AS connection_count
FROM   pg_stat_activity
WHERE  pid <> pg_backend_pid()
GROUP  BY datname, usename, state
ORDER  BY connection_count DESC;

\echo ''
\echo '========================================================================='
\echo '5. MAX_CONNECTIONS VS CURRENT USAGE'
\echo '========================================================================='
SELECT
  (SELECT count(*) FROM pg_stat_activity) AS used,
  (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections,
  round(
    100.0 * (SELECT count(*) FROM pg_stat_activity)
    / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 1
  ) AS pct_used;

\echo ''
\echo '========================================================================='
\echo '6. ROLE CONNECTION LIMITS (non-default)'
\echo '========================================================================='
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolconnlimit <> -1;

\echo ''
\echo '========================================================================='
\echo '7. DATABASE CONNECTION LIMITS (non-default)'
\echo '========================================================================='
SELECT datname, datconnlimit FROM pg_database WHERE datconnlimit <> -1;

\echo ''
\echo '========================================================================='
\echo '8. QUERY AGE DISTRIBUTION (triage overview)'
\echo '========================================================================='
SELECT state,
  CASE
    WHEN now() - query_start < interval '1 minute'  THEN '< 1 min'
    WHEN now() - query_start < interval '5 minutes' THEN '1-5 min'
    WHEN now() - query_start < interval '1 hour'    THEN '5-60 min'
    ELSE '> 1 hour'
  END AS age_bucket,
  COUNT(*) AS sessions
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY state, age_bucket
ORDER BY state, age_bucket;

\echo ''
\echo '========================================================================='
\echo '9. CONNECTIONS BY CLIENT ADDRESS (spot deploy/scale-out storms)'
\echo '========================================================================='
SELECT client_addr, application_name, state, COUNT(*) AS connections,
       min(backend_start) AS oldest_connection
FROM   pg_stat_activity
WHERE  pid <> pg_backend_pid()
GROUP  BY client_addr, application_name, state
ORDER  BY connections DESC;

\echo ''
\echo '========================================================================='
\echo 'Diagnostic suite complete.'
\echo '========================================================================='
