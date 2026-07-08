# RDS PostgreSQL Lock Investigation

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:11  
**Link:** [https://chatgpt.com/share/e/6a4c97a4-92b0-83ee-91df-392e8c90c7da](https://chatgpt.com/share/e/6a4c97a4-92b0-83ee-91df-392e8c90c7da)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert.

I need a complete investigation and simulation plan for the topic:

**Locks, Deadlocks, Blocked Queries, and Blocked Production Workflows in an AWS RDS PostgreSQL Environment**

Please cover this in depth from both **manual troubleshooting steps** and **agent-based/root-cause analysis automation** perspectives.

The goal is to identify, diagnose, reproduce, and resolve production issues caused by:

* Row-level locks
* Table-level locks
* Long-running transactions
* Idle in transaction sessions
* Blocking queries
* Deadlocks
* Lock wait contention
* Connection pool exhaustion caused by blocked sessions
* DDL blocking DML
* Vacuum/autovacuum contention
* Foreign key-related locking
* Index creation/reindexing lock behavior
* Application workflow blockage due to database contention

Please structure the response as follows:

1. **Conceptual Overview**

   * Explain PostgreSQL locks, lock modes, waits, blocking chains, deadlocks, and contention.
   * Explain how these behave specifically in AWS RDS PostgreSQL.
   * Clarify the difference between lock wait, blocked query, deadlock, long-running transaction, and connection exhaustion.

2. **Production Symptoms**

   * List common production symptoms caused by locks and deadlocks.
   * Include examples such as slow API responses, job queue backlog, stuck workflows, high database connections, CPU spikes, transaction timeout errors, and deadlock errors.

3. **Manual Root Cause Investigation Steps**

   * Provide SQL queries to inspect:

     * Active queries
     * Waiting sessions
     * Blocking sessions
     * Blocking chains
     * Lock types and lock modes
     * Long-running transactions
     * Idle in transaction sessions
     * Deadlock-related evidence
     * Application name, user, client address, wait events
   * Use PostgreSQL views such as:

     * pg_stat_activity
     * pg_locks
     * pg_blocking_pids()
     * pg_stat_database
     * pg_stat_statements
     * RDS Performance Insights
     * CloudWatch metrics
     * PostgreSQL logs

4. **AWS RDS-Specific Investigation**

   * Explain how to use:

     * RDS Performance Insights
     * CloudWatch metrics
     * Enhanced Monitoring
     * RDS PostgreSQL logs
     * Parameter groups
     * log_lock_waits
     * deadlock_timeout
     * statement_timeout
     * idle_in_transaction_session_timeout
     * lock_timeout
   * Include recommended parameter settings for production-safe observability.

5. **Root Cause Classification**

   * Categorize possible root causes, including:

     * Application transaction not committing
     * Large batch update/delete
     * Missing or inefficient indexes
     * DDL executed during peak hours
     * Foreign key without proper indexing
     * ORM transaction misuse
     * Connection pool misconfiguration
     * Long-running reports
     * Autovacuum conflicts
     * Migration scripts blocking production workload

6. **Simulation Scenarios**
   Provide reproducible PostgreSQL examples using multiple sessions.

   Include simulations for:

   * Simple row-level blocking
   * Table-level lock blocking
   * Deadlock between two transactions
   * Idle in transaction holding locks
   * DDL blocking DML
   * Long-running update blocking application workflow
   * Foreign key locking/contention
   * Index creation behavior
   * Vacuum/autovacuum-related contention
   * Connection pool exhaustion due to blocked queries

   For each simulation, include:

   * Setup SQL
   * Session 1 commands
   * Session 2 commands
   * Optional Session 3 monitoring query
   * Expected behavior
   * How to detect the issue
   * How to resolve it safely

7. **Agent-Based RCA Design**
   Design agents or automation workflows that can detect and analyze lock issues.

   Include:

   * Lock monitoring agent
   * Blocking-chain detection agent
   * Deadlock evidence collector
   * Long-running transaction detector
   * Idle-in-transaction detector
   * Query impact classifier
   * RDS metrics correlation agent
   * Remediation recommendation agent

   For each agent, explain:

   * Inputs
   * SQL queries or metrics used
   * Detection logic
   * Severity classification
   * Output format
   * Recommended action

8. **Decision Tree for Production Incidents**
   Provide a step-by-step decision tree for on-call engineers:

   * Is the issue blocking production?
   * Which PID is the blocker?
   * Is the blocker safe to terminate?
   * Is it an application transaction, migration, report, or maintenance task?
   * Should we cancel query or terminate backend?
   * What evidence must be collected before action?

9. **Safe Remediation**
   Explain when to use:

   * pg_cancel_backend(pid)
   * pg_terminate_backend(pid)
   * Application rollback
   * Kill idle transaction
   * Pause worker/job queue
   * Stop migration
   * Add index
   * Tune timeout settings
   * Change transaction boundaries
   * Adjust connection pool settings

10. **Preventive Best Practices**
    Include best practices for:

* Transaction design
* Lock timeout settings
* Statement timeout
* Idle transaction timeout
* Indexing foreign keys
* Migration safety
* Batch processing
* Job queue design
* Connection pool sizing
* Monitoring and alerting
* Runbooks

11. **Deliverables**
    Provide:

* SQL diagnostic script
* Simulation SQL script
* Production incident runbook
* Agent RCA workflow
* Monitoring and alert recommendations
* Checklist for developers
* Checklist for DBAs/SREs

Make the answer practical, production-oriented, and suitable for a team running AWS RDS PostgreSQL in a real production environment.

Show moreShow less

## Response:
I’ll structure this as a practical production guide with scripts/runbooks, then add automation/RCA design on top. I’ll verify AWS RDS/PostgreSQL observability details against current official docs before giving parameter and tooling recommendations.

Thought for 7s

Below is a production-oriented investigation, simulation, and RCA automation plan for **locks, deadlocks, blocked queries, and blocked workflows in AWS RDS PostgreSQL**.

* * *

1\. Conceptual Overview
=======================

1.1 What PostgreSQL locks are
-----------------------------

PostgreSQL uses locks to protect data consistency when multiple sessions access or modify the same objects. Locks can exist at different levels:

| Lock area | Example |
| --- | --- |
| Row-level lock | `UPDATE`, `DELETE`, `SELECT ... FOR UPDATE` |
| Table-level lock | `ALTER TABLE`, `TRUNCATE`, `VACUUM FULL`, some DDL |
| Transaction-level lock | One transaction waits for another transaction to finish |
| Advisory lock | Application-controlled lock using `pg_advisory_lock()` |
| Predicate/SIRead lock | Serializable isolation conflict tracking |
| Extension/internal lock | Locks used by indexes, vacuum, replication, catalog updates |

PostgreSQL exposes active locks through `pg_locks`, active sessions through `pg_stat_activity`, and blockers through `pg_blocking_pids()`. PostgreSQL documentation recommends using `pg_locks` to inspect outstanding locks. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/explicit-locking.html?utm_source=chatgpt.com)

* * *

1.2 Lock wait vs blocked query vs deadlock
------------------------------------------

| Term | Meaning | Example |
| --- | --- | --- |
| Lock wait | A session is waiting to acquire a lock | Session B waits for row locked by Session A |
| Blocked query | Query cannot proceed because another session holds an incompatible lock | `UPDATE users SET ... WHERE id=1` waits |
| Blocking session | Session holding the lock that others need | Session A has uncommitted update |
| Blocking chain | A blocks B, B blocks C, C blocks D | Queue of waiting sessions |
| Deadlock | Two or more sessions wait on each other cyclically | A waits for B, B waits for A |
| Long-running transaction | Transaction stays open for a long time | Report query or batch update open for 1 hour |
| Idle in transaction | Session opened transaction but is not doing work | App forgot to commit/rollback |
| Connection exhaustion | Pool or DB reaches connection limit, often because blocked sessions pile up | API workers wait forever and consume all pool connections |

* * *

1.3 How this behaves in AWS RDS PostgreSQL
------------------------------------------

AWS RDS PostgreSQL is still PostgreSQL, but investigation and remediation differ from self-managed PostgreSQL:

| Area | RDS behavior |
| --- | --- |
| OS access | No direct host access |
| PostgreSQL logs | Access through RDS console, AWS CLI, API, or CloudWatch Logs if exported |
| Parameters | Managed through DB parameter groups |
| Performance visibility | RDS Performance Insights, CloudWatch, Enhanced Monitoring |
| Superuser | No real `postgres` superuser; use `rds_superuser` capabilities |
| Emergency restart | Done through RDS reboot/failover, not OS process kill |
| Query kill | Use `pg_cancel_backend()` or `pg_terminate_backend()` |

AWS documents RDS PostgreSQL wait events and notes that wait events indicate sessions waiting for resources, including cases like sessions waiting on rows locked by another session. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.waits.html?utm_source=chatgpt.com)

* * *

2\. Production Symptoms
=======================

Common symptoms caused by locks, deadlocks, and blocked workflows:

| Symptom | Possible cause |
| --- | --- |
| API response time spikes | Queries waiting on row/table locks |
| Job queue backlog | Workers blocked on same records |
| High DB connections | Blocked queries consuming pool connections |
| App timeout errors | `statement_timeout`, app timeout, pool timeout |
| Deadlock errors | Cyclic locking between transactions |
| CPU spike | Many blocked sessions waking/retrying, inefficient blocker query |
| Low CPU but high latency | Sessions waiting, not executing |
| High `Lock` wait in Performance Insights | Lock contention |
| `idle in transaction` sessions | App failed to commit/rollback |
| DDL stuck | DDL waiting for active DML transactions |
| DML stuck after deployment | Migration DDL holding table lock |
| Autovacuum lag or bloat | Long transaction prevents cleanup |
| Replication lag | Long transaction, vacuum delay, write burst |
| Error: `deadlock detected` | PostgreSQL aborted one transaction |
| Error: `canceling statement due to lock timeout` | `lock_timeout` reached |
| Error: `terminating connection due to idle-in-transaction timeout` | `idle_in_transaction_session_timeout` reached |

* * *

3\. Manual Root Cause Investigation Steps
=========================================

3.1 First triage query: active sessions
---------------------------------------

```
SELECT
    now() AS captured_at,
    pid,
    usename,
    application_name,
    client_addr,
    backend_type,
    state,
    wait_event_type,
    wait_event,
    xact_start,
    query_start,
    state_change,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY
    CASE WHEN wait_event_type = 'Lock' THEN 0 ELSE 1 END,
    xact_start NULLS LAST,
    query_start NULLS LAST;
```

Look for:

| Column | Meaning |
| --- | --- |
| `wait_event_type = 'Lock'` | Session is waiting on a lock |
| `state = 'idle in transaction'` | Dangerous if transaction age is high |
| `xact_age` | How long transaction has been open |
| `query_age` | How long current query has been running |
| `application_name` | Helps identify API, worker, migration, report |
| `client_addr` | Helps identify app host/pod |
| `backend_type` | Distinguishes client backend, autovacuum, background processes |

* * *

3.2 Find blocked sessions and blockers
--------------------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_app,
    blocked.client_addr AS blocked_client,
    blocked.state AS blocked_state,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_query_age,
    left(blocked.query, 800) AS blocked_query,

    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.application_name AS blocker_app,
    blocker.client_addr AS blocker_client,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    now() - blocker.query_start AS blocker_query_age,
    left(blocker.query, 800) AS blocker_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bpid(blocker_pid) ON true
JOIN pg_stat_activity blocker ON blocker.pid = bpid.blocker_pid
WHERE blocked.datname = current_database()
ORDER BY blocker_xact_age DESC NULLS LAST;
```

This is usually the most important query during an incident.

* * *

3.3 Find lock details and lock modes
------------------------------------

```
SELECT
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    a.wait_event_type,
    a.wait_event,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    l.classid,
    l.objid,
    l.objsubid,
    now() - a.xact_start AS xact_age,
    now() - a.query_start AS query_age,
    left(a.query, 800) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE a.datname = current_database()
ORDER BY l.granted, a.xact_start NULLS LAST, a.query_start NULLS LAST;
```

Important interpretation:

| `granted` | Meaning |
| --- | --- |
| `true` | Session already holds the lock |
| `false` | Session is waiting for the lock |

Common lock modes:

| Lock mode | Typical source |
| --- | --- |
| `RowExclusiveLock` | `INSERT`, `UPDATE`, `DELETE` |
| `ShareLock` | FK checks, index operations |
| `ShareRowExclusiveLock` | Some DDL |
| `AccessExclusiveLock` | `ALTER TABLE`, `TRUNCATE`, `DROP`, `VACUUM FULL` |
| `AccessShareLock` | Plain `SELECT` |

PostgreSQL’s explicit locking documentation describes table-level lock modes and their conflicts. `ACCESS EXCLUSIVE` is the strongest table lock and blocks most concurrent access. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/explicit-locking.html?utm_source=chatgpt.com)

* * *

3.4 Blocking chain query
------------------------

```
WITH RECURSIVE blocking_tree AS (
    SELECT
        a.pid AS blocked_pid,
        unnest(pg_blocking_pids(a.pid)) AS blocker_pid,
        1 AS depth,
        ARRAY[a.pid] AS path
    FROM pg_stat_activity a
    WHERE cardinality(pg_blocking_pids(a.pid)) > 0

    UNION ALL

    SELECT
        bt.blocker_pid AS blocked_pid,
        unnest(pg_blocking_pids(bt.blocker_pid)) AS blocker_pid,
        bt.depth + 1 AS depth,
        bt.path || bt.blocker_pid
    FROM blocking_tree bt
    JOIN pg_stat_activity a ON a.pid = bt.blocker_pid
    WHERE cardinality(pg_blocking_pids(bt.blocker_pid)) > 0
      AND NOT bt.blocker_pid = ANY(bt.path)
)
SELECT
    bt.depth,
    bt.blocked_pid,
    blocked.application_name AS blocked_app,
    blocked.state AS blocked_state,
    blocked.wait_event_type AS blocked_wait_type,
    blocked.wait_event AS blocked_wait_event,
    left(blocked.query, 500) AS blocked_query,
    bt.blocker_pid,
    blocker.application_name AS blocker_app,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    left(blocker.query, 500) AS blocker_query,
    bt.path
FROM blocking_tree bt
JOIN pg_stat_activity blocked ON blocked.pid = bt.blocked_pid
JOIN pg_stat_activity blocker ON blocker.pid = bt.blocker_pid
ORDER BY bt.depth, bt.blocked_pid;
```

Use this to find the **root blocker**.

* * *

3.5 Root blocker query
----------------------

```
WITH blocked AS (
    SELECT
        pid AS blocked_pid,
        unnest(pg_blocking_pids(pid)) AS blocker_pid
    FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0
),
blockers AS (
    SELECT DISTINCT blocker_pid FROM blocked
),
also_blocked AS (
    SELECT DISTINCT blocked_pid FROM blocked
)
SELECT
    a.pid AS root_blocker_pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    now() - a.xact_start AS xact_age,
    now() - a.query_start AS query_age,
    count(b.blocked_pid) AS directly_blocking_count,
    left(a.query, 1000) AS query
FROM blockers rb
JOIN pg_stat_activity a ON a.pid = rb.blocker_pid
LEFT JOIN blocked b ON b.blocker_pid = rb.blocker_pid
WHERE rb.blocker_pid NOT IN (SELECT blocked_pid FROM also_blocked)
GROUP BY
    a.pid, a.usename, a.application_name, a.client_addr,
    a.state, a.xact_start, a.query_start, a.query
ORDER BY directly_blocking_count DESC, xact_age DESC NULLS LAST;
```

* * *

3.6 Long-running transactions
-----------------------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    xact_start,
    now() - xact_start AS xact_age,
    query_start,
    now() - query_start AS query_age,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_age DESC;
```

Risk:

| Long transaction type | Production risk |
| --- | --- |
| Active report query | Holds snapshot, may delay vacuum cleanup |
| Open write transaction | Holds row/table locks |
| Idle in transaction | Often application bug |
| Migration transaction | Can block DDL/DML for long time |

* * *

3.7 Idle in transaction sessions
--------------------------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    xact_start,
    now() - xact_start AS idle_xact_age,
    state_change,
    now() - state_change AS idle_duration,
    wait_event_type,
    wait_event,
    left(query, 1000) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY idle_xact_age DESC;
```

Production meaning:

> The application started a transaction, executed something, then stopped without commit/rollback. Any locks from prior statements remain held until transaction end.

* * *

3.8 Deadlock evidence
---------------------

Deadlocks are normally visible in PostgreSQL logs, not as a persistent live state, because PostgreSQL detects the cycle and aborts one transaction.

Check current database deadlock count:

```
SELECT
    datname,
    deadlocks,
    temp_files,
    temp_bytes,
    xact_commit,
    xact_rollback,
    blks_read,
    blks_hit
FROM pg_stat_database
WHERE datname = current_database();
```

Check recent app errors/logs for:

```
ERROR: deadlock detected
DETAIL: Process ... waits for ... blocked by process ...
HINT: See server log for query details.
```

`log_lock_waits` can log waits that exceed `deadlock_timeout`, and PostgreSQL’s parameter documentation states that it is useful for determining whether lock waits are causing poor performance. [![](https://www.google.com/s2/favicons?domain=https://postgresqlco.nf&sz=128)postgresqlco.nf](https://postgresqlco.nf/doc/en/param/log_lock_waits/?utm_source=chatgpt.com)

* * *

3.9 `pg_stat_statements` for recurring offenders
------------------------------------------------

Enable `pg_stat_statements` in RDS parameter group using `shared_preload_libraries`, then:

```
SELECT
    queryid,
    calls,
    total_exec_time,
    mean_exec_time,
    max_exec_time,
    rows,
    shared_blks_hit,
    shared_blks_read,
    temp_blks_written,
    left(query, 1000) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Useful for finding:

| Pattern | Possible RCA |
| --- | --- |
| High mean time update/delete | Batch job causing locks |
| High calls same update | Hot row contention |
| High temp blocks | Poor query plan causing long transaction |
| High max time | Periodic blocking or reports |

* * *

4\. AWS RDS-Specific Investigation
==================================

4.1 RDS Performance Insights
----------------------------

Use Performance Insights during incident.

Check:

| PI area | What to inspect |
| --- | --- |
| DB Load | Is load above vCPU count? |
| Waits | Is top wait `Lock:*`, `LWLock:*`, `Client:*`, `IO:*`? |
| SQL | Which SQL has highest DB load? |
| Users | Which DB user is involved? |
| Hosts | Which app host/client generated load? |
| Sessions | Are many sessions waiting? |
| Time slice | Did issue start after deployment/job/migration? |

AWS RDS wait event documentation explains that wait events identify what resource a session is waiting for, including locks, client reads, I/O, and other resources. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.waits.html?utm_source=chatgpt.com)

Important lock-related wait categories:

| Wait event pattern | Meaning |
| --- | --- |
| `Lock:transactionid` | Waiting for transaction holding row lock |
| `Lock:relation` | Waiting on table/relation-level lock |
| `Lock:tuple` | Waiting on row tuple lock |
| `Lock:extend` | Waiting to extend relation file |
| `Client:ClientRead` | Backend waiting for client; dangerous if in transaction |
| `Activity:AutoVacuumMain` | Autovacuum activity context |

AWS provides RDS for PostgreSQL wait event documentation with common causes and corrective actions. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.summary.html?utm_source=chatgpt.com)

* * *

4.2 CloudWatch metrics
----------------------

Check these metrics:

| Metric | Why it matters |
| --- | --- |
| `DatabaseConnections` | Blocked sessions may consume all connections |
| `CPUUtilization` | High CPU may be blocker query or retry storm |
| `FreeableMemory` | Memory pressure from many sessions/sorts |
| `ReadIOPS`, `WriteIOPS` | Long query or batch workload |
| `ReadLatency`, `WriteLatency` | Storage pressure making transactions longer |
| `DiskQueueDepth` | I/O backlog |
| `FreeStorageSpace` | Vacuum/temp issues |
| `TransactionLogsDiskUsage` | Long transactions or replication lag |
| `Deadlocks` | Deadlock count |
| `DBLoad` | If available through Performance Insights/CloudWatch |
| `DBLoadCPU`, `DBLoadNonCPU` | CPU vs wait-based load |

* * *

4.3 Enhanced Monitoring
-----------------------

Enhanced Monitoring helps inspect OS-level symptoms, including:

| Signal | Meaning |
| --- | --- |
| Process list | Many PostgreSQL backends |
| CPU per process | Heavy blocker query |
| Memory usage | Backend memory pressure |
| Load average | High runnable or waiting tasks |
| Disk I/O | Storage saturation |

Use it to distinguish:

| Pattern | Interpretation |
| --- | --- |
| High DB connections, low CPU | Lock waits / client waits |
| High CPU, high active SQL | Query execution problem |
| High I/O latency | Slow storage extends transaction duration |
| Many idle sessions | Pool misconfiguration |

* * *

4.4 RDS PostgreSQL logs
-----------------------

RDS PostgreSQL logs can be viewed using the RDS console, AWS CLI, or API. AWS documents configuration and access methods for RDS PostgreSQL database log files. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.html?utm_source=chatgpt.com)

Search logs for:

```
deadlock detected
process ... still waiting
process ... acquired
duration:
canceling statement due to lock timeout
terminating connection due to idle-in-transaction timeout
could not obtain lock
```

* * *

4.5 Recommended production observability parameters
---------------------------------------------------

These are practical starting points. Tune per workload.

| Parameter | Suggested value | Purpose |
| --- | --- | --- |
| `log_lock_waits` | `on` | Log long lock waits |
| `deadlock_timeout` | `1s` to `2s` | Controls deadlock check and lock-wait logging threshold |
| `log_min_duration_statement` | `1000ms` to `5000ms` | Log slow SQL |
| `statement_timeout` | App-specific, e.g. `30s` API, `5m-30m` batch | Prevent runaway queries |
| `lock_timeout` | `2s-10s` for app writes/migrations | Avoid waiting forever for locks |
| `idle_in_transaction_session_timeout` | `60s-300s` | Kill forgotten open transactions |
| `track_activity_query_size` | `4096` or higher | Capture longer SQL text |
| `shared_preload_libraries` | include `pg_stat_statements` | Query-level analysis |
| `log_temp_files` | e.g. `100MB` | Detect large sorts/hash spills |
| `log_autovacuum_min_duration` | `1s-10s` or `0` temporarily | Observe autovacuum activity |

PostgreSQL client timeout settings include `statement_timeout`, `lock_timeout`, and `idle_in_transaction_session_timeout`; the documentation notes that zero disables these timeouts by default. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/runtime-config-client.html?utm_source=chatgpt.com)

Recommended approach:

```
-- Safer at role or database level than global, where possible.
ALTER ROLE app_user SET statement_timeout = '30s';
ALTER ROLE app_user SET lock_timeout = '5s';
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '120s';

-- For migration role
ALTER ROLE migration_user SET lock_timeout = '5s';
ALTER ROLE migration_user SET statement_timeout = '30min';
```

For migrations, prefer explicit session settings:

```
SET lock_timeout = '5s';
SET statement_timeout = '30min';
```

* * *

5\. Root Cause Classification
=============================

| RCA category | Typical evidence | Example fix |
| --- | --- | --- |
| App transaction not committing | `idle in transaction`, high `xact_age` | Fix transaction handling, add timeout |
| Large batch update/delete | Long active write query, many blocked rows | Batch smaller, commit frequently |
| Missing index | Slow blocker query, seq scan, high IO | Add index concurrently |
| DDL during peak | `ALTER TABLE` waiting/holding `AccessExclusiveLock` | Run off-peak, use safe migration pattern |
| FK without index | Child table scans during parent update/delete | Index FK columns |
| ORM misuse | Long transactions around API/business logic | Narrow transaction scope |
| Pool exhaustion | High DB connections, many blocked app sessions | Reduce pool, add timeouts, backpressure |
| Long report | Long `SELECT`, old snapshot, vacuum delay | Read replica, timeout, optimize query |
| Autovacuum conflict | Autovacuum waiting or blocked by long xact | Fix long transactions, tune autovacuum |
| Migration script | DDL/DML mixed in one large transaction | Split migration, use lock timeout |
| Hot row contention | Many sessions update same row/counter | Shard counter, queue, optimistic locking |
| Job queue contention | Workers lock same jobs | Use `FOR UPDATE SKIP LOCKED` |
| Application workflow blockage | Same logical entity updated by many services | Define lock order, idempotency, queue design |

* * *

6\. Simulation Scenarios
========================

Use a non-production test RDS PostgreSQL instance.

6.1 Common setup
----------------

```
DROP TABLE IF EXISTS lock_test_child;
DROP TABLE IF EXISTS lock_test_parent;
DROP TABLE IF EXISTS lock_test_jobs;
DROP TABLE IF EXISTS lock_test_accounts;

CREATE TABLE lock_test_accounts (
    id bigint PRIMARY KEY,
    balance numeric NOT NULL,
    status text NOT NULL DEFAULT 'active',
    updated_at timestamptz DEFAULT now()
);

INSERT INTO lock_test_accounts (id, balance)
SELECT g, 1000
FROM generate_series(1, 10) g;

CREATE TABLE lock_test_jobs (
    id bigserial PRIMARY KEY,
    status text NOT NULL DEFAULT 'pending',
    payload text,
    updated_at timestamptz DEFAULT now()
);

INSERT INTO lock_test_jobs(status, payload)
SELECT 'pending', 'job-' || g
FROM generate_series(1, 100) g;

CREATE TABLE lock_test_parent (
    id bigint PRIMARY KEY,
    name text
);

CREATE TABLE lock_test_child (
    id bigint PRIMARY KEY,
    parent_id bigint NOT NULL REFERENCES lock_test_parent(id),
    description text
);

INSERT INTO lock_test_parent VALUES (1, 'parent-1'), (2, 'parent-2');

INSERT INTO lock_test_child
SELECT g, 1, 'child-' || g
FROM generate_series(1, 1000) g;
```

Monitoring query for Session 3:

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.application_name AS blocked_app,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_for,
    left(blocked.query, 300) AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.application_name AS blocker_app,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    left(blocker.query, 300) AS blocker_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) b(blocker_pid) ON true
JOIN pg_stat_activity blocker ON blocker.pid = b.blocker_pid
ORDER BY blocked_for DESC;
```

* * *

6.2 Scenario 1: Simple row-level blocking
-----------------------------------------

### How it happens

Two sessions try to update the same row. The second session waits until the first commits or rolls back.

### Session 1

```
BEGIN;
UPDATE lock_test_accounts
SET balance = balance - 100
WHERE id = 1;

-- Do not commit yet.
```

### Session 2

```
BEGIN;
UPDATE lock_test_accounts
SET balance = balance + 50
WHERE id = 1;

-- This waits.
```

### Session 3 detection

```
SELECT * FROM pg_stat_activity
WHERE wait_event_type = 'Lock';
```

Or use the blocking query from section 3.2.

### Expected behavior

Session 2 waits on Session 1.

### Safe resolution

Preferred:

```
-- Session 1
COMMIT;
-- or
ROLLBACK;
```

Emergency:

```
SELECT pg_terminate_backend(<session_1_pid>);
```

### Prevention

Use short transactions. Avoid user/API calls inside open DB transactions.

* * *

6.3 Scenario 2: Table-level lock blocking
-----------------------------------------

### How it happens

A strong table lock blocks DML.

### Session 1

```
BEGIN;
LOCK TABLE lock_test_accounts IN ACCESS EXCLUSIVE MODE;

-- Keep transaction open.
```

### Session 2

```
UPDATE lock_test_accounts
SET balance = balance + 10
WHERE id = 2;

-- This waits.
```

### Detection

```
SELECT
    a.pid,
    a.state,
    l.mode,
    l.granted,
    l.relation::regclass,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation = 'lock_test_accounts'::regclass;
```

### Safe resolution

```
COMMIT;
-- or
ROLLBACK;
```

Emergency:

```
SELECT pg_terminate_backend(<blocker_pid>);
```

### Prevention

Avoid manual `LOCK TABLE` in production. For migrations, set `lock_timeout`.

* * *

6.4 Scenario 3: Deadlock between two transactions
-------------------------------------------------

### How it happens

Session 1 locks row 1 then wants row 2. Session 2 locks row 2 then wants row 1.

### Session 1

```
BEGIN;
UPDATE lock_test_accounts SET balance = balance - 10 WHERE id = 1;
```

### Session 2

```
BEGIN;
UPDATE lock_test_accounts SET balance = balance - 20 WHERE id = 2;
```

### Session 1

```
UPDATE lock_test_accounts SET balance = balance + 10 WHERE id = 2;
```

### Session 2

```
UPDATE lock_test_accounts SET balance = balance + 20 WHERE id = 1;
```

### Expected behavior

PostgreSQL detects the deadlock and aborts one transaction:

```
ERROR: deadlock detected
```

### Detection

```
SELECT datname, deadlocks
FROM pg_stat_database
WHERE datname = current_database();
```

Check PostgreSQL logs for deadlock details.

### Safe resolution

The database already aborts one transaction. Application must retry the failed transaction safely.

### Prevention

Always lock rows in a consistent order:

```
-- Good pattern
SELECT *
FROM lock_test_accounts
WHERE id IN (1, 2)
ORDER BY id
FOR UPDATE;
```

* * *

6.5 Scenario 4: Idle in transaction holding locks
-------------------------------------------------

### Session 1

```
BEGIN;
UPDATE lock_test_accounts
SET status = 'hold'
WHERE id = 3;

-- Now stop doing anything.
-- This session becomes idle in transaction.
```

### Session 2

```
UPDATE lock_test_accounts
SET status = 'active'
WHERE id = 3;

-- Waits.
```

### Detection

```
SELECT
    pid,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    now() - state_change AS idle_duration,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_age DESC;
```

### Safe resolution

Ask app owner to commit/rollback. If production is blocked:

```
SELECT pg_terminate_backend(<idle_pid>);
```

### Prevention

Set:

```
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '120s';
```

* * *

6.6 Scenario 5: DDL blocking DML
--------------------------------

### Session 1

```
BEGIN;
ALTER TABLE lock_test_accounts ADD COLUMN ddl_test_col text;

-- Keep transaction open.
```

### Session 2

```
UPDATE lock_test_accounts
SET balance = balance + 1
WHERE id = 4;

-- May block depending on timing/lock.
```

### Alternative safer simulation

Session 1:

```
BEGIN;
LOCK TABLE lock_test_accounts IN ACCESS EXCLUSIVE MODE;
```

Session 2:

```
SELECT * FROM lock_test_accounts WHERE id = 4;
-- Blocks because ACCESS EXCLUSIVE conflicts even with SELECT.
```

### Detection

```
SELECT
    a.pid,
    l.mode,
    l.granted,
    l.relation::regclass,
    a.state,
    now() - a.xact_start AS xact_age,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation = 'lock_test_accounts'::regclass
ORDER BY l.granted;
```

### Safe resolution

If migration is blocking production:

```
SELECT pg_cancel_backend(<migration_pid>);
```

If cancellation does not work:

```
SELECT pg_terminate_backend(<migration_pid>);
```

### Prevention

Use migration settings:

```
SET lock_timeout = '5s';
SET statement_timeout = '30min';
```

Avoid peak-hour DDL.

* * *

6.7 Scenario 6: Long-running update blocking application workflow
-----------------------------------------------------------------

### Session 1

```
BEGIN;

UPDATE lock_test_jobs
SET status = 'processing',
    updated_at = now()
WHERE id BETWEEN 1 AND 80;

-- Keep transaction open.
```

### Session 2

```
UPDATE lock_test_jobs
SET status = 'done'
WHERE id = 10;

-- Waits.
```

### Expected behavior

Application workflow that needs job 10 is blocked.

### Detection

```
SELECT
    pid,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    query
FROM pg_stat_activity
WHERE query ILIKE '%lock_test_jobs%'
ORDER BY xact_age DESC NULLS LAST;
```

### Safe resolution

Commit or rollback Session 1.

### Prevention

Batch smaller:

```
UPDATE lock_test_jobs
SET status = 'processing'
WHERE id IN (
    SELECT id
    FROM lock_test_jobs
    WHERE status = 'pending'
    ORDER BY id
    LIMIT 100
    FOR UPDATE SKIP LOCKED
);
```

* * *

6.8 Scenario 7: Foreign key locking/contention
----------------------------------------------

### How it happens

Parent deletes/updates and child inserts/updates can conflict due to referential integrity checks. Missing indexes on child FK columns can also make parent changes scan child rows for longer.

### Check missing FK indexes

```
SELECT
    conrelid::regclass AS child_table,
    conname AS fk_name,
    pg_get_constraintdef(oid) AS fk_definition
FROM pg_constraint
WHERE contype = 'f'
  AND NOT EXISTS (
      SELECT 1
      FROM pg_index i
      WHERE i.indrelid = conrelid
        AND i.indkey::int2[] @> conkey
  );
```

### Session 1

```
BEGIN;
DELETE FROM lock_test_parent WHERE id = 1;

-- This may scan/check child table and will fail eventually because child rows exist,
-- but it can still create contention during the operation.
```

### Session 2

```
INSERT INTO lock_test_child(id, parent_id, description)
VALUES (2001, 1, 'new-child');

-- May wait depending on FK lock interaction.
```

### Detection

```
SELECT
    a.pid,
    a.wait_event_type,
    a.wait_event,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE a.query ILIKE '%lock_test_parent%'
   OR a.query ILIKE '%lock_test_child%';
```

### Resolution

Rollback conflicting transaction:

```
ROLLBACK;
```

### Prevention

Create indexes on FK columns:

```
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_lock_test_child_parent_id
ON lock_test_child(parent_id);
```

* * *

6.9 Scenario 8: Index creation behavior
---------------------------------------

### Normal `CREATE INDEX`

`CREATE INDEX` can block writes more than `CREATE INDEX CONCURRENTLY`.

### Session 1

```
BEGIN;
UPDATE lock_test_accounts
SET balance = balance + 1
WHERE id = 5;

-- Keep open.
```

### Session 2

```
CREATE INDEX idx_lock_test_accounts_status
ON lock_test_accounts(status);

-- May wait for conflicting transaction.
```

### Safer production pattern

```
CREATE INDEX CONCURRENTLY idx_lock_test_accounts_status
ON lock_test_accounts(status);
```

Important: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block.

### Detection

```
SELECT
    pid,
    datname,
    relid::regclass AS table_name,
    index_relid::regclass AS index_name,
    phase,
    lockers_total,
    lockers_done,
    current_locker_pid,
    blocks_total,
    blocks_done,
    tuples_total,
    tuples_done
FROM pg_stat_progress_create_index;
```

### Resolution

Cancel index creation if causing issue:

```
SELECT pg_cancel_backend(<index_pid>);
```

If using `CREATE INDEX CONCURRENTLY` and it fails, check for invalid index:

```
SELECT
    indexrelid::regclass AS index_name,
    indisvalid,
    indisready
FROM pg_index
WHERE indexrelid::regclass::text LIKE 'idx_lock_test_accounts_status%';
```

Drop invalid index if needed:

```
DROP INDEX CONCURRENTLY IF EXISTS idx_lock_test_accounts_status;
```

* * *

6.10 Scenario 9: Vacuum/autovacuum-related contention
-----------------------------------------------------

### Important reality

Regular `VACUUM` usually does not block normal reads/writes heavily, but it can be affected by long-running transactions. `VACUUM FULL` takes a strong lock and blocks access.

### Session 1

```
BEGIN;
SELECT * FROM lock_test_accounts WHERE id = 1;

-- Keep transaction open for a long time.
```

### Session 2

```
DELETE FROM lock_test_accounts WHERE id BETWEEN 6 AND 10;
VACUUM lock_test_accounts;
```

### Detection

```
SELECT
    pid,
    datname,
    relid::regclass AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    index_vacuum_count,
    max_dead_tuples,
    num_dead_tuples
FROM pg_stat_progress_vacuum;
```

Long transactions preventing cleanup:

```
SELECT
    pid,
    usename,
    application_name,
    state,
    backend_xmin,
    xact_start,
    now() - xact_start AS xact_age,
    query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start;
```

### Strong lock simulation with `VACUUM FULL`

Session 1:

```
VACUUM FULL lock_test_accounts;
```

Session 2:

```
SELECT * FROM lock_test_accounts;
-- Can block while VACUUM FULL holds strong lock.
```

### Prevention

Avoid `VACUUM FULL` in production peak hours. Prefer regular vacuum, autovacuum tuning, partitioning, or table rewrite strategies.

* * *

6.11 Scenario 10: Connection pool exhaustion due to blocked queries
-------------------------------------------------------------------

### How it happens

One blocker causes many app sessions to wait. Each blocked request holds a DB connection. Eventually:

| Layer | Failure |
| --- | --- |
| App pool | Pool exhausted |
| PgBouncer | Clients wait |
| RDS | `max_connections` reached |
| API | Timeouts and 5xx errors |

### Session 1 blocker

```
BEGIN;
UPDATE lock_test_accounts
SET balance = balance + 100
WHERE id = 1;
```

### Sessions 2 to N

Open many sessions and run:

```
UPDATE lock_test_accounts
SET balance = balance + 1
WHERE id = 1;
```

### Detection

```
SELECT
    count(*) AS total_connections,
    count(*) FILTER (WHERE state = 'active') AS active_connections,
    count(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waiting_connections,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction_connections
FROM pg_stat_activity
WHERE datname = current_database();
```

Connection usage by app:

```
SELECT
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    count(*) AS sessions
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY application_name, client_addr, state, wait_event_type, wait_event
ORDER BY sessions DESC;
```

### Resolution

1.  Identify root blocker.
2.  Commit/rollback or terminate blocker.
3.  Pause/reduce app workers.
4.  Recover pool gradually.
5.  Review pool timeout and DB timeout settings.

* * *

7\. Agent-Based RCA Design
==========================

7.1 Lock Monitoring Agent
-------------------------

| Item | Details |
| --- | --- |
| Inputs | DB connection, database name, thresholds |
| SQL | `pg_stat_activity`, `pg_locks`, `pg_blocking_pids()` |
| Frequency | Every 30–60 seconds |
| Detection | Count sessions where `wait_event_type='Lock'` |
| Severity | Based on wait duration, count, application, relation |
| Output | Current lock wait summary |

Example output:

```
{
  "incident_type": "LOCK_WAIT_CONTENTION",
  "severity": "HIGH",
  "waiting_sessions": 18,
  "max_wait_seconds": 240,
  "top_blocker_pid": 12345,
  "top_blocker_application": "api-service",
  "affected_relations": ["orders", "job_queue"],
  "recommended_action": "Investigate blocker transaction and consider pg_terminate_backend after evidence collection"
}
```

* * *

7.2 Blocking-Chain Detection Agent
----------------------------------

| Item | Details |
| --- | --- |
| Inputs | Live activity snapshot |
| SQL | Recursive blocking chain query |
| Logic | Build blocker → blocked graph |
| Severity | Higher if one root blocker blocks many sessions |
| Output | Root blocker, chain depth, affected apps |

Severity example:

| Condition | Severity |
| --- | --- |
| 1–2 blocked sessions under 30s | Low |
| \>5 blocked sessions or >60s | Medium |
| \>20 blocked sessions or production app affected | High |
| Root blocker blocks critical workflow | Critical |

* * *

7.3 Deadlock Evidence Collector
-------------------------------

| Item | Details |
| --- | --- |
| Inputs | `pg_stat_database.deadlocks`, PostgreSQL logs, app errors |
| Logic | Detect increase in deadlock count |
| Evidence | Log lines around `deadlock detected` |
| Output | Queries, PIDs, relations, application names |

Example output:

```
{
  "incident_type": "DEADLOCK",
  "severity": "HIGH",
  "deadlocks_delta_5m": 4,
  "suspected_pattern": "Inconsistent row update order",
  "queries_involved": [
    "UPDATE account SET ... WHERE id=$1",
    "UPDATE account SET ... WHERE id=$2"
  ],
  "recommendation": "Enforce deterministic locking order and retry deadlock victims"
}
```

* * *

7.4 Long-Running Transaction Detector
-------------------------------------

| Item | Details |
| --- | --- |
| Inputs | `pg_stat_activity` |
| Detection | `xact_age > threshold` |
| Thresholds | API: 30–60s, batch: configurable |
| Risk score | Write transaction > read transaction |
| Output | Longest transactions with app/user/client |

Detection SQL:

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes';
```

* * *

7.5 Idle-in-Transaction Detector
--------------------------------

| Item | Details |
| --- | --- |
| Inputs | `pg_stat_activity` |
| Detection | `state='idle in transaction'` |
| Severity | High if holding locks or old snapshot |
| Action | Recommend terminate if blocking production |

Logic:

```
IF state = idle in transaction
AND xact_age > 120 seconds
AND blocking_count > 0
THEN severity = CRITICAL
```

* * *

7.6 Query Impact Classifier
---------------------------

Classify impact by relation and app.

| Signal | Impact |
| --- | --- |
| Relation is `orders`, `payments`, `users`, `job_queue` | High |
| App is API service | High |
| App is report service | Medium |
| App is migration tool | High during business hours |
| Blocked sessions > worker pool size | Critical |
| Client retry storm detected | Critical |

Output:

```
{
  "business_impact": "ORDER_PROCESSING_BLOCKED",
  "affected_tables": ["orders", "order_items"],
  "affected_apps": ["checkout-api", "order-worker"],
  "symptom": "job queue backlog and API timeout"
}
```

* * *

7.7 RDS Metrics Correlation Agent
---------------------------------

| Input | Source |
| --- | --- |
| DB connections | CloudWatch |
| Deadlocks | CloudWatch / `pg_stat_database` |
| DB load | Performance Insights |
| Wait events | Performance Insights |
| CPU/memory/I/O | CloudWatch / Enhanced Monitoring |
| Logs | RDS PostgreSQL logs / CloudWatch Logs |

Correlation logic:

```
IF lock_wait_sessions increased
AND DatabaseConnections increased
AND DBLoadNonCPU increased
AND top wait = Lock
THEN RCA = lock contention causing connection pile-up
```

* * *

7.8 Remediation Recommendation Agent
------------------------------------

Inputs:

| Input | Example |
| --- | --- |
| Root blocker PID | `12345` |
| Blocker state | `idle in transaction` |
| Blocker app | `migration-service` |
| Blocked count | `42` |
| Blocker xact age | `18 minutes` |
| Query type | `ALTER TABLE` |
| Relation | `orders` |
| Business impact | `checkout blocked` |

Decision:

```
IF blocker is idle in transaction
AND blocking critical workload
THEN recommend pg_terminate_backend(pid)

IF blocker is active SELECT report
AND not modifying data
THEN recommend pg_cancel_backend(pid)

IF blocker is migration DDL
AND production DML blocked
THEN recommend pg_cancel_backend(pid), then pg_terminate_backend(pid) if needed

IF blocker is autovacuum
THEN do not terminate by default; first inspect blocked relation and long transactions
```

Output:

```
{
  "recommended_action": "TERMINATE_BACKEND",
  "sql": "SELECT pg_terminate_backend(12345);",
  "risk": "Uncommitted transaction will rollback",
  "evidence_required": [
    "blocked session count",
    "blocker query",
    "application_name",
    "xact_age",
    "affected relation"
  ],
  "post_action_validation": [
    "blocked sessions cleared",
    "DatabaseConnections decreasing",
    "API latency recovered"
  ]
}
```

* * *

8\. Decision Tree for Production Incidents
==========================================

Step 1: Confirm production impact
---------------------------------

Ask:

| Question | Evidence |
| --- | --- |
| Are APIs slow or failing? | APM, logs, 5xx, latency |
| Are workers stuck? | Queue depth, job age |
| Are DB sessions waiting? | `pg_stat_activity` |
| Are DB connections high? | CloudWatch `DatabaseConnections` |
| Is DB load lock-heavy? | Performance Insights waits |

* * *

Step 2: Find blocked sessions
-----------------------------

Run:

```
SELECT
    pid,
    application_name,
    wait_event_type,
    wait_event,
    now() - query_start AS wait_age,
    pg_blocking_pids(pid) AS blockers,
    query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY wait_age DESC;
```

* * *

Step 3: Find root blocker
-------------------------

Run root blocker query from section 3.5.

Classify blocker:

| Blocker type | Action |
| --- | --- |
| `idle in transaction` app session | Usually terminate after evidence |
| Active long DML | Check business impact before cancel/terminate |
| Migration DDL | Cancel first |
| Report query | Cancel if blocking production |
| Autovacuum | Avoid killing unless exceptional |
| Unknown app/client | Escalate but collect evidence quickly |

* * *

Step 4: Collect evidence before action
--------------------------------------

Minimum evidence:

```
SELECT now();

SELECT * FROM pg_stat_activity WHERE pid = <blocker_pid>;

SELECT * FROM pg_locks WHERE pid = <blocker_pid>;

SELECT
    pid,
    application_name,
    client_addr,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE <blocker_pid> = ANY(pg_blocking_pids(pid));
```

Also capture:

| Evidence | Source |
| --- | --- |
| Top wait events | Performance Insights |
| DatabaseConnections | CloudWatch |
| Deadlock count | CloudWatch / `pg_stat_database` |
| App error sample | Application logs |
| PostgreSQL log lines | RDS logs |

* * *

Step 5: Decide cancel vs terminate
----------------------------------

| Situation | Preferred action |
| --- | --- |
| Active SELECT/report blocker | `pg_cancel_backend(pid)` |
| Active migration DDL | `pg_cancel_backend(pid)` first |
| Idle in transaction blocker | `pg_terminate_backend(pid)` |
| Query ignores cancel or transaction remains open | `pg_terminate_backend(pid)` |
| Critical production outage | Terminate root blocker after evidence |
| Unsure if data-changing transaction is safe | Escalate to app owner, but do not delay if outage is severe |

* * *

9\. Safe Remediation
====================

9.1 `pg_cancel_backend(pid)`
----------------------------

Cancels the current query but keeps the connection alive.

Use for:

| Good use case |
| --- |
| Long-running SELECT |
| Migration statement currently waiting |
| Index creation |
| Report query |
| Query consuming CPU/I/O |

Command:

```
SELECT pg_cancel_backend(<pid>);
```

Risk:

| Risk |
| --- |
| Transaction may remain open |
| App may retry immediately |
| Does not kill idle transaction |

* * *

9.2 `pg_terminate_backend(pid)`
-------------------------------

Terminates the session and rolls back open transaction.

Use for:

| Good use case |
| --- |
| Idle in transaction holding locks |
| Blocker did not release after cancel |
| App session abandoned |
| Critical production blockage |
| Connection leak |

Command:

```
SELECT pg_terminate_backend(<pid>);
```

Risk:

| Risk |
| --- |
| Uncommitted work rolls back |
| App may show error |
| Long rollback may take time |
| Retrying app may recreate contention |

* * *

9.3 Pause worker/job queue
--------------------------

Use when many workers are amplifying contention.

Actions:

| Action |
| --- |
| Pause consumers |
| Reduce concurrency |
| Stop retry storm |
| Let blocker finish or terminate blocker |
| Resume gradually |

* * *

9.4 Stop migration
------------------

Use when DDL blocks production.

Safe migration pattern:

```
SET lock_timeout = '5s';
SET statement_timeout = '30min';

ALTER TABLE ...;
```

If lock cannot be acquired quickly, migration fails instead of blocking production.

* * *

9.5 Add index
-------------

Use when lock contention is caused by slow scans or FK checks.

Production-safe pattern:

```
CREATE INDEX CONCURRENTLY idx_table_column
ON table_name(column_name);
```

Do not run inside transaction block.

* * *

9.6 Tune timeout settings
-------------------------

Recommended layered timeout model:

| Layer | Timeout |
| --- | --- |
| Application request timeout | e.g. 30s |
| DB `statement_timeout` | slightly below or aligned with app |
| DB `lock_timeout` | short, e.g. 2–10s |
| Pool acquire timeout | short, e.g. 1–5s |
| Idle transaction timeout | 60–300s |

* * *

10\. Preventive Best Practices
==============================

10.1 Transaction design
-----------------------

Good:

```
BEGIN;
UPDATE orders SET status = 'paid' WHERE id = $1;
INSERT INTO order_events(order_id, event_type) VALUES ($1, 'paid');
COMMIT;
```

Bad:

```
BEGIN;
UPDATE order;
Call external payment API;
Call another service;
Write logs;
Wait for user confirmation;
COMMIT;
```

Rules:

| Best practice |
| --- |
| Keep transactions short |
| Never call external APIs inside transaction |
| Commit after each safe batch |
| Lock rows in consistent order |
| Avoid user think-time inside transaction |
| Use retry logic for deadlocks and serialization failures |

* * *

10.2 Lock timeout
-----------------

Set for app roles:

```
ALTER ROLE app_user SET lock_timeout = '5s';
```

For critical workflows:

```
SET LOCAL lock_timeout = '2s';
```

* * *

10.3 Statement timeout
----------------------

Use different values by workload:

| Workload | Suggested |
| --- | --- |
| API | 15s–60s |
| Worker | 1m–10m |
| Reports | 5m–30m |
| Migration | Explicit per script |
| DBA session | Manual, not global |

* * *

10.4 Idle transaction timeout
-----------------------------

```
ALTER ROLE app_user
SET idle_in_transaction_session_timeout = '120s';
```

This protects production from forgotten open transactions.

* * *

10.5 Index foreign keys
-----------------------

Find missing FK indexes regularly:

```
SELECT
    conrelid::regclass AS child_table,
    conname,
    pg_get_constraintdef(oid) AS fk_def
FROM pg_constraint
WHERE contype = 'f'
  AND NOT EXISTS (
      SELECT 1
      FROM pg_index i
      WHERE i.indrelid = conrelid
        AND i.indkey::int2[] @> conkey
  );
```

* * *

10.6 Migration safety
---------------------

Migration checklist:

| Rule |
| --- |
| Run during low traffic |
| Use `lock_timeout` |
| Avoid wrapping all migrations in one large transaction |
| Use `CREATE INDEX CONCURRENTLY` |
| Avoid `VACUUM FULL` during peak |
| Avoid table rewrite operations on large tables |
| Test lock behavior in staging |
| Monitor `pg_locks` during deployment |
| Have rollback/cancel plan |

* * *

10.7 Batch processing
---------------------

Bad:

```
UPDATE jobs SET status = 'done' WHERE status = 'pending';
```

Better:

```
WITH batch AS (
    SELECT id
    FROM jobs
    WHERE status = 'pending'
    ORDER BY id
    LIMIT 1000
    FOR UPDATE SKIP LOCKED
)
UPDATE jobs j
SET status = 'done'
FROM batch
WHERE j.id = batch.id;
```

* * *

10.8 Job queue design
---------------------

Use:

```
SELECT id
FROM jobs
WHERE status = 'pending'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Benefits:

| Benefit |
| --- |
| Workers do not block each other |
| Stuck job does not stop queue |
| Better concurrency |
| Lower connection pile-up |

* * *

10.9 Connection pool sizing
---------------------------

Avoid setting pool size too high.

Rule of thumb:

```
total_possible_connections =
    app_instances × pool_size_per_instance
```

This must be lower than safe DB capacity.

Example:

```
20 app pods × pool size 30 = 600 possible DB sessions
```

That may be dangerous for RDS PostgreSQL.

Better:

| Layer | Recommendation |
| --- | --- |
| App pool | Small and bounded |
| Pool timeout | Short |
| PgBouncer | Use transaction pooling where compatible |
| Worker concurrency | Controlled |
| Retries | Exponential backoff |
| DB max connections | Not treated as capacity target |

* * *

10.10 Monitoring and alerting
-----------------------------

Recommended alerts:

| Alert | Suggested condition |
| --- | --- |
| Lock wait sessions | `count(wait_event_type='Lock') > 5 for 5 min` |
| Critical blocker | one PID blocking > 10 sessions |
| Idle in transaction | age > 5 min |
| Long transaction | age > 15 min |
| Deadlocks | increase > 0 in 5 min |
| DB connections | \> 80% max connections |
| DB load | \> vCPU count sustained |
| API latency | p95/p99 increase |
| Queue backlog | age/depth above threshold |
| Migration lock wait | any DDL waiting > 30s |

* * *

11\. Deliverables
=================

11.1 SQL Diagnostic Script
--------------------------

```
\echo '===== Capture Time ====='
SELECT now();

\echo '===== Connection Summary ====='
SELECT
    count(*) AS total,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
    count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock
FROM pg_stat_activity
WHERE datname = current_database();

\echo '===== Active and Waiting Sessions ====='
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    backend_type,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    pg_blocking_pids(pid) AS blocking_pids,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY
    cardinality(pg_blocking_pids(pid)) DESC,
    wait_event_type,
    xact_start NULLS LAST;

\echo '===== Blocked -> Blocker Mapping ====='
SELECT
    blocked.pid AS blocked_pid,
    blocked.application_name AS blocked_app,
    blocked.client_addr AS blocked_client,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_age,
    left(blocked.query, 800) AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.application_name AS blocker_app,
    blocker.client_addr AS blocker_client,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    left(blocker.query, 800) AS blocker_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bpid(blocker_pid) ON true
JOIN pg_stat_activity blocker ON blocker.pid = bpid.blocker_pid
ORDER BY blocked_age DESC;

\echo '===== Root Blockers ====='
WITH blocked AS (
    SELECT
        pid AS blocked_pid,
        unnest(pg_blocking_pids(pid)) AS blocker_pid
    FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0
),
blockers AS (
    SELECT DISTINCT blocker_pid FROM blocked
),
also_blocked AS (
    SELECT DISTINCT blocked_pid FROM blocked
)
SELECT
    a.pid AS root_blocker_pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    now() - a.xact_start AS xact_age,
    now() - a.query_start AS query_age,
    count(b.blocked_pid) AS directly_blocking_count,
    left(a.query, 1000) AS query
FROM blockers rb
JOIN pg_stat_activity a ON a.pid = rb.blocker_pid
LEFT JOIN blocked b ON b.blocker_pid = rb.blocker_pid
WHERE rb.blocker_pid NOT IN (SELECT blocked_pid FROM also_blocked)
GROUP BY
    a.pid, a.usename, a.application_name, a.client_addr,
    a.state, a.xact_start, a.query_start, a.query
ORDER BY directly_blocking_count DESC, xact_age DESC NULLS LAST;

\echo '===== Lock Details ====='
SELECT
    a.pid,
    a.application_name,
    a.client_addr,
    a.state,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    l.transactionid,
    l.virtualxid,
    now() - a.xact_start AS xact_age,
    left(a.query, 800) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE a.datname = current_database()
ORDER BY l.granted, relation_name, mode;

\echo '===== Idle in Transaction ====='
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    now() - state_change AS idle_duration,
    wait_event_type,
    wait_event,
    left(query, 1000) AS last_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'idle in transaction'
ORDER BY xact_age DESC;

\echo '===== Long Running Transactions ====='
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND xact_start IS NOT NULL
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_age DESC;

\echo '===== Database Deadlock Count ====='
SELECT
    datname,
    deadlocks,
    xact_commit,
    xact_rollback,
    temp_files,
    temp_bytes
FROM pg_stat_database
WHERE datname = current_database();

\echo '===== Progress: Create Index ====='
SELECT * FROM pg_stat_progress_create_index;

\echo '===== Progress: Vacuum ====='
SELECT * FROM pg_stat_progress_vacuum;
```

* * *

11.2 Simulation SQL Script
--------------------------

Use the setup from section 6.1, then run each scenario in separate sessions.

Minimum simulation list:

```
-- Scenario A: Row lock
BEGIN;
UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 1;

-- Scenario B: Table lock
BEGIN;
LOCK TABLE lock_test_accounts IN ACCESS EXCLUSIVE MODE;

-- Scenario C: Idle transaction
BEGIN;
UPDATE lock_test_accounts SET status = 'hold' WHERE id = 3;

-- Scenario D: Deadlock
-- Session 1: update id 1, then id 2
-- Session 2: update id 2, then id 1

-- Scenario E: DDL blocking
BEGIN;
ALTER TABLE lock_test_accounts ADD COLUMN test_col text;

-- Scenario F: Worker contention
BEGIN;
UPDATE lock_test_jobs SET status = 'processing' WHERE id BETWEEN 1 AND 80;

-- Scenario G: Safer queue pattern
WITH batch AS (
    SELECT id
    FROM lock_test_jobs
    WHERE status = 'pending'
    ORDER BY id
    LIMIT 10
    FOR UPDATE SKIP LOCKED
)
UPDATE lock_test_jobs j
SET status = 'processing'
FROM batch
WHERE j.id = batch.id;

-- Scenario H: Index behavior
CREATE INDEX CONCURRENTLY idx_lock_test_jobs_status
ON lock_test_jobs(status);
```

* * *

11.3 Production Incident Runbook
--------------------------------

### Immediate actions

1.  Confirm production impact.
2.  Capture DB activity snapshot.
3.  Identify blocked sessions.
4.  Identify root blocker.
5.  Capture blocker evidence.
6.  Check Performance Insights top waits.
7.  Check CloudWatch `DatabaseConnections`, CPU, DB load, deadlocks.
8.  Decide cancel vs terminate.
9.  Pause workers if retry storm exists.
10.  Validate recovery.

### Evidence package

```
Incident time:
Affected application:
Affected workflow:
Root blocker PID:
Root blocker user:
Root blocker app:
Root blocker client:
Root blocker query:
Root blocker transaction age:
Blocked sessions count:
Affected tables:
Wait event:
Action taken:
Recovery time:
Permanent fix:
```

* * *

11.4 Agent RCA Workflow
-----------------------

```
Every 60 seconds:
    Collect pg_stat_activity
    Collect pg_locks
    Collect blocking graph
    Collect long transactions
    Collect idle-in-transaction sessions
    Collect deadlock delta
    Collect RDS metrics
    Collect Performance Insights top waits

If lock wait detected:
    Build blocker chain
    Identify root blocker
    Classify blocker type
    Classify business impact
    Calculate severity
    Generate recommendation

If severity >= HIGH:
    Notify on-call with:
        Root blocker PID
        Blocked sessions
        Affected app/table
        Safe action
        Evidence queries
        Rollback risk

If severity == CRITICAL:
    Recommend immediate cancel/terminate path
    Recommend pausing workers if connection pile-up exists
```

* * *

11.5 Monitoring and Alert Recommendations
-----------------------------------------

| Alert | Severity |
| --- | --- |
| Any deadlock detected | Medium/High |
| Lock waits > 5 sessions for 5 minutes | High |
| One blocker blocking > 10 sessions | Critical |
| Idle in transaction > 5 minutes | High |
| Idle in transaction blocking others | Critical |
| DB connections > 80% | High |
| DB connections > 90% | Critical |
| Long transaction > 30 minutes | High |
| Migration DDL waiting > 1 minute | High |
| API p95 latency + lock waits | Critical |
| Queue backlog + lock waits | Critical |

* * *

11.6 Developer Checklist
------------------------

| Checklist item |
| --- |
| Keep DB transactions short |
| Never call external services inside DB transaction |
| Always commit or rollback |
| Use consistent row locking order |
| Add retry logic for deadlocks |
| Add retry logic for serialization failures |
| Use `FOR UPDATE SKIP LOCKED` for worker queues |
| Avoid large single-transaction batch updates |
| Add indexes for FK columns |
| Set app-level query timeout |
| Set pool acquire timeout |
| Use meaningful `application_name` |
| Do not run DDL from app request path |
| Test migration lock behavior before production |
| Avoid unbounded ORM transactions |

* * *

11.7 DBA/SRE Checklist
----------------------

| Checklist item |
| --- |
| Enable Performance Insights |
| Export PostgreSQL logs to CloudWatch Logs |
| Enable `log_lock_waits` |
| Tune `deadlock_timeout` |
| Configure `statement_timeout` per role/workload |
| Configure `lock_timeout` for app and migration users |
| Configure `idle_in_transaction_session_timeout` |
| Enable `pg_stat_statements` |
| Monitor deadlocks |
| Monitor lock waits |
| Monitor idle transactions |
| Monitor long transactions |
| Monitor DB connection usage |
| Review FK indexes periodically |
| Review migration scripts before release |
| Maintain emergency blocker-kill runbook |
| Document app owner per `application_name` |
| Test lock simulations in staging |

* * *

Practical Final Recommendation
==============================

For a real AWS RDS PostgreSQL production environment, I would implement this in phases:

| Phase | Action |
| --- | --- |
| Phase 1 | Enable observability: `log_lock_waits`, Performance Insights, CloudWatch logs, `pg_stat_statements` |
| Phase 2 | Create DBA diagnostic SQL script and on-call runbook |
| Phase 3 | Add alerts for lock waits, blockers, deadlocks, idle transactions, and connection usage |
| Phase 4 | Build lock RCA agent using `pg_stat_activity`, `pg_locks`, `pg_blocking_pids()`, RDS metrics, and logs |
| Phase 5 | Fix prevention gaps: FK indexes, migration safety, transaction timeouts, pool sizing, queue locking pattern |
| Phase 6 | Run simulations in staging and train support/on-call engineers |

The most important production habit is this:

> During a lock incident, do not randomly kill sessions. First identify the **root blocker**, capture evidence, classify the blocker, then choose between `pg_cancel_backend()` and `pg_terminate_backend()` based on impact and rollback risk.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)