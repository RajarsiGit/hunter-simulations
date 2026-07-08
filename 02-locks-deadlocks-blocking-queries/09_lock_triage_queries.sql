-- =============================================================================
-- 09_lock_triage_queries.sql
-- Locks & Deadlocks — First-Response Detection & Triage Queries
-- SysCloud DAL Team
--
-- Run this file first on any suspected lock/deadlock/blocking incident.
-- All queries connect directly to RDS (port 5432), bypassing PgBouncer.
--
-- psql does not read .env itself — export the vars first, e.g.:
--   set -a; source .env; set +a
--   psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
--     -f 09_lock_triage_queries.sql
--
-- Individual sections can be extracted and run ad hoc in psql or DBeaver.
-- =============================================================================

\echo ''
\echo '============================================================'
\echo '  Locks & Deadlocks — Triage Sweep'
\echo '  Run at first sign of locking / blocking / queue build-up'
\echo '============================================================'
\echo ''

-- ---------------------------------------------------------------------------
-- 1. First-response triage — all non-idle sessions
--    Read: blockers non-empty → session is being blocked
--          wait_event_type = 'Lock' → lock wait confirmed
--          state = 'idle in transaction' → candidate blocker
-- ---------------------------------------------------------------------------
\echo '--- 1. First-response triage (all non-idle sessions) ---'

SELECT pid,
       usename,
       application_name,
       state,
       wait_event_type,
       wait_event,
       pg_blocking_pids(pid)          AS blockers,
       now() - query_start            AS query_age,
       now() - xact_start             AS xact_age,
       left(query, 120)               AS query_snippet
FROM   pg_stat_activity
WHERE  state <> 'idle'
ORDER  BY query_age DESC NULLS LAST;

\echo ''

-- ---------------------------------------------------------------------------
-- 2. Blocking tree — who is blocking whom
--    Run when §1 shows any non-empty blockers column.
--    Directly shows blocker ↔ blocked relationship.
-- ---------------------------------------------------------------------------
\echo '--- 2. Blocking tree (blocker ↔ blocked pairs) ---'

SELECT blocked.pid                          AS blocked_pid,
       blocked.usename                      AS blocked_user,
       blocked.application_name             AS blocked_app,
       blocked.state                        AS blocked_state,
       blocked.wait_event,
       now() - blocked.query_start          AS blocked_query_age,
       now() - blocked.xact_start           AS blocked_xact_age,
       left(blocked.query, 100)             AS blocked_query,

       blocker.pid                          AS blocker_pid,
       blocker.usename                      AS blocker_user,
       blocker.application_name             AS blocker_app,
       blocker.state                        AS blocker_state,
       now() - blocker.xact_start           AS blocker_xact_age,
       left(blocker.query, 100)             AS blocker_query

FROM   pg_stat_activity AS blocked
JOIN   LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bpid(blocker_pid) ON true
JOIN   pg_stat_activity AS blocker ON blocker.pid = bpid.blocker_pid
WHERE  blocked.wait_event_type = 'Lock'
ORDER  BY blocked_query_age DESC;

\echo ''

-- ---------------------------------------------------------------------------
-- 3. Full blocking chain — recursive (for deep A→B→C→D chains)
--    Use when §2 shows multiple levels of blocking.
--    depth column shows how many hops from root to this blocked session.
-- ---------------------------------------------------------------------------
\echo '--- 3. Full blocking chain (recursive, depth ≤ 10) ---'

WITH RECURSIVE lock_tree AS (
    SELECT blocked.pid   AS blocked_pid,
           blocker.pid   AS blocker_pid,
           blocked.query AS blocked_query,
           blocker.query AS blocker_query,
           1             AS depth
    FROM   pg_stat_activity AS blocked
    JOIN   LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bpid(blocker_pid) ON true
    JOIN   pg_stat_activity AS blocker ON blocker.pid = bpid.blocker_pid

    UNION ALL

    SELECT lt.blocked_pid,
           blocker.pid,
           lt.blocked_query,
           blocker.query,
           lt.depth + 1
    FROM   lock_tree lt
    JOIN   pg_stat_activity intermediate ON intermediate.pid = lt.blocker_pid
    JOIN   LATERAL unnest(pg_blocking_pids(intermediate.pid)) AS bpid(blocker_pid) ON true
    JOIN   pg_stat_activity blocker ON blocker.pid = bpid.blocker_pid
    WHERE  lt.depth < 10
)
SELECT *
FROM   lock_tree
ORDER  BY blocked_pid, depth;

\echo ''

-- ---------------------------------------------------------------------------
-- 4. Idle-in-transaction sessions
--    Any session with transaction_age > 5 minutes is a candidate
--    for investigation and possible termination.
-- ---------------------------------------------------------------------------
\echo '--- 4. Idle-in-transaction sessions (potential blockers) ---'

SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       now() - xact_start   AS transaction_age,
       now() - state_change  AS idle_in_txn_age,
       left(query, 120)      AS last_query
FROM   pg_stat_activity
WHERE  state = 'idle in transaction'
ORDER  BY transaction_age DESC;

\echo ''

-- ---------------------------------------------------------------------------
-- 5. Full lock inventory (pg_locks)
--    granted = false → waiting session
--    granted = true  → holder
--    Compare pairs to understand the conflict mode.
-- ---------------------------------------------------------------------------
\echo '--- 5. Full lock inventory (granted=false rows are waiters) ---'

SELECT a.pid,
       a.usename,
       a.application_name,
       a.state,
       a.wait_event_type,
       a.wait_event,
       now() - a.xact_start          AS xact_age,
       l.locktype,
       l.mode,
       l.granted,
       l.relation::regclass          AS relation_name,
       l.transactionid,
       left(a.query, 80)             AS query
FROM   pg_locks l
JOIN   pg_stat_activity a ON a.pid = l.pid
ORDER  BY l.granted ASC, xact_age DESC NULLS LAST;

\echo ''

-- ---------------------------------------------------------------------------
-- 6. Deadlock counter
--    A rising value means PostgreSQL has auto-aborted one session per
--    deadlock event. Check CloudWatch Logs for ERROR: deadlock detected.
-- ---------------------------------------------------------------------------
\echo '--- 6. Deadlock counter for current database ---'

SELECT datname,
       deadlocks
FROM   pg_stat_database
WHERE  datname = current_database();

\echo ''

-- ---------------------------------------------------------------------------
-- 7. Long-running transactions (vacuum impact)
--    backend_xmin prevents autovacuum from cleaning dead tuples
--    beyond the oldest active transaction.
-- ---------------------------------------------------------------------------
\echo '--- 7. Long-running transactions (xact_start IS NOT NULL) ---'

SELECT pid,
       usename,
       backend_xmin,
       now() - xact_start AS transaction_age,
       left(query, 100)   AS query
FROM   pg_stat_activity
WHERE  xact_start IS NOT NULL
ORDER  BY transaction_age DESC NULLS LAST;

\echo ''

-- ---------------------------------------------------------------------------
-- 8. Index creation and vacuum progress
--    Check these when a CREATE INDEX or VACUUM is the suspected blocker.
-- ---------------------------------------------------------------------------
\echo '--- 8a. Active index creation progress ---'

SELECT * FROM pg_stat_progress_create_index;

\echo ''
\echo '--- 8b. Active vacuum progress ---'

SELECT * FROM pg_stat_progress_vacuum;

\echo ''

-- ---------------------------------------------------------------------------
-- 9. Connection headroom
--    High used/max ratio means a single blocker is accumulating waiters
--    that each hold an open connection slot.
-- ---------------------------------------------------------------------------
\echo '--- 9. Connection headroom ---'

SELECT (SELECT count(*) FROM pg_stat_activity)                                AS used,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections')  AS max,
       round(
           100.0 * (SELECT count(*) FROM pg_stat_activity)
               / (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'),
           1
       )                                                                       AS pct_used;

\echo ''
\echo '--- 9. Connection distribution by database / user / state ---'

SELECT datname,
       usename,
       state,
       count(*) AS cnt
FROM   pg_stat_activity
GROUP  BY datname, usename, state
ORDER  BY cnt DESC;

\echo ''

-- ---------------------------------------------------------------------------
-- 10. Advisory lock detection
--     Look for sessions holding or waiting on pg_advisory_lock.
-- ---------------------------------------------------------------------------
\echo '--- 10. Advisory lock sessions ---'

SELECT pid,
       usename,
       application_name,
       state,
       now() - xact_start  AS age,
       left(query, 100)    AS query
FROM   pg_stat_activity
WHERE  query ILIKE '%pg_advisory_lock%';

\echo ''
\echo '============================================================'
\echo '  Triage complete. Next steps:'
\echo '  1. Use §2 blocker_pid to identify the root blocker.'
\echo '  2. Classify severity based on blocked session count (or run'
\echo '     20_lock_incident_rca.sh for an automated classification).'
\echo '  3. Terminate with pg_terminate_backend via deployment request.'
\echo '  4. If deadlock: check CloudWatch for ERROR: deadlock detected.'
\echo '============================================================'
\echo ''
