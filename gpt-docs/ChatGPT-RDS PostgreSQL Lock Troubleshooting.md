# RDS PostgreSQL Lock Troubleshooting

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:01  
**Link:** [https://chatgpt.com/share/e/6a26349c-0990-8013-8943-722f2e6e8327](https://chatgpt.com/share/e/6a26349c-0990-8013-8943-722f2e6e8327)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL expert.

Create a complete guide for investigating, simulating, and resolving locks, deadlocks, blocked queries, and blocked production workflows in AWS RDS PostgreSQL.

Include manual troubleshooting steps, SQL diagnostic queries, RDS Performance Insights and CloudWatch analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices.

Ensure all major scenarios are covered, including row locks, table locks, deadlocks, idle transactions, long-running transactions, DDL blocking DML, foreign key contention, vacuum/autovacuum contention, index operations, connection pool exhaustion, and application workflow blockage.

For every scenario, provide:

How it happens
How to simulate it
How to detect it
How to identify the blocker
How to resolve it safely
How to prevent it in production

Show moreShow less

## Response:
I’ll structure this as a DBA runbook: first the investigation workflow and reusable diagnostic SQL, then scenario-by-scenario simulations, RCA workflow, safe remediation, and prevention controls. I’ll verify AWS/PostgreSQL RDS-specific details against current official docs where needed.

Thought for 15s

Below is a complete senior DBA-style runbook for **AWS RDS PostgreSQL locks, deadlocks, blocked queries, and blocked production workflows**. Use all simulation steps only in a **non-production database**.

1\. Mental model: what is happening during blocking
===================================================

PostgreSQL uses MVCC, so normal `SELECT` queries usually do not block `INSERT`, `UPDATE`, or `DELETE`. Blocking happens mainly when a session needs a conflicting lock that another transaction is holding. Table-level locks, row-level locks, DDL locks, foreign-key validation locks, autovacuum-related locks, and connection exhaustion can all create production workflow blockage. PostgreSQL lock compatibility and deadlock behavior are defined by lock modes; conflicting lock modes cannot be held at the same time on the same object. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/explicit-locking.html?utm_source=chatgpt.com)

In AWS RDS PostgreSQL, you normally investigate blocking from:

1.  `pg_stat_activity`
2.  `pg_locks`
3.  `pg_blocking_pids(pid)`
4.  RDS Performance Insights wait events
5.  CloudWatch metrics
6.  PostgreSQL logs exported to CloudWatch Logs

RDS Performance Insights uses **DB Load / Average Active Sessions** to show how many sessions are active or waiting, and it breaks load down by SQL, wait event, user, host, and database. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.Overview.ActiveSessions.html?utm_source=chatgpt.com)

* * *

2\. Immediate production triage workflow
========================================

Step 1: Confirm whether the database is blocked, overloaded, or connection-exhausted
------------------------------------------------------------------------------------

Check these symptoms:

| Symptom | Likely issue |
| --- | --- |
| Many sessions show `wait_event_type = 'Lock'` | Lock blocking |
| Many sessions are `active` but waiting on I/O | Slow storage / query pressure |
| Many sessions are `idle in transaction` | Application did not commit/rollback |
| `DatabaseConnections` near `max_connections` | Connection exhaustion |
| PgBouncer clients waiting | Pool exhaustion |
| `DBLoad` much higher than vCPU line | Database saturation |
| Application requests stuck but DB CPU low | Lock wait, pool wait, network wait, or app-level transaction issue |

CloudWatch gives infrastructure-level RDS metrics such as CPU, memory, storage, I/O, and database connections, while Performance Insights gives database-load dimensions such as SQL and waits. RDS sends metric data to CloudWatch, commonly at one-minute resolution by default. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-metrics.html?utm_source=chatgpt.com)

* * *

Step 2: Find currently blocked sessions
---------------------------------------

```
SELECT
    now() AS snapshot_time,
    a.pid AS blocked_pid,
    a.usename AS blocked_user,
    a.datname AS database_name,
    a.application_name,
    a.client_addr,
    a.state,
    a.wait_event_type,
    a.wait_event,
    now() - a.query_start AS blocked_query_age,
    now() - a.xact_start AS blocked_xact_age,
    pg_blocking_pids(a.pid) AS blocker_pids,
    a.query AS blocked_query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY blocked_query_age DESC;
```

`pg_blocking_pids()` is the fastest practical starting point because it directly returns the backend PIDs blocking a session.

* * *

Step 3: Show blocked query and blocker query side by side
---------------------------------------------------------

```
WITH blocked AS (
    SELECT
        a.pid AS blocked_pid,
        unnest(pg_blocking_pids(a.pid)) AS blocker_pid
    FROM pg_stat_activity a
    WHERE cardinality(pg_blocking_pids(a.pid)) > 0
)
SELECT
    now() AS snapshot_time,

    b.blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocked_activity.application_name AS blocked_app,
    blocked_activity.client_addr AS blocked_client,
    blocked_activity.wait_event_type AS blocked_wait_type,
    blocked_activity.wait_event AS blocked_wait_event,
    now() - blocked_activity.query_start AS blocked_query_age,
    now() - blocked_activity.xact_start AS blocked_xact_age,
    blocked_activity.query AS blocked_query,

    b.blocker_pid,
    blocker_activity.usename AS blocker_user,
    blocker_activity.application_name AS blocker_app,
    blocker_activity.client_addr AS blocker_client,
    blocker_activity.state AS blocker_state,
    now() - blocker_activity.query_start AS blocker_query_age,
    now() - blocker_activity.xact_start AS blocker_xact_age,
    blocker_activity.query AS blocker_query
FROM blocked b
JOIN pg_stat_activity blocked_activity
    ON blocked_activity.pid = b.blocked_pid
JOIN pg_stat_activity blocker_activity
    ON blocker_activity.pid = b.blocker_pid
ORDER BY blocked_query_age DESC;
```

* * *

Step 4: Identify exact lock type and object
-------------------------------------------

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
    l.relation::regclass AS locked_relation,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    now() - a.xact_start AS xact_age,
    now() - a.query_start AS query_age,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a
    ON a.pid = l.pid
ORDER BY
    l.granted ASC,
    xact_age DESC NULLS LAST,
    query_age DESC NULLS LAST;
```

* * *

Step 5: Build a full blocking chain
-----------------------------------

This helps when session A blocks B, B blocks C, and C blocks many application requests.

```
WITH RECURSIVE blocking_tree AS (
    SELECT
        a.pid AS blocked_pid,
        unnest(pg_blocking_pids(a.pid)) AS blocker_pid,
        1 AS level,
        ARRAY[a.pid] AS path
    FROM pg_stat_activity a
    WHERE cardinality(pg_blocking_pids(a.pid)) > 0

    UNION ALL

    SELECT
        bt.blocker_pid AS blocked_pid,
        unnest(pg_blocking_pids(bt.blocker_pid)) AS blocker_pid,
        bt.level + 1,
        bt.path || bt.blocker_pid
    FROM blocking_tree bt
    JOIN pg_stat_activity a
        ON a.pid = bt.blocker_pid
    WHERE cardinality(pg_blocking_pids(bt.blocker_pid)) > 0
      AND NOT bt.blocker_pid = ANY(bt.path)
)
SELECT
    bt.level,
    bt.blocked_pid,
    blocked.query AS blocked_query,
    bt.blocker_pid,
    blocker.state AS blocker_state,
    blocker.query AS blocker_query,
    now() - blocker.xact_start AS blocker_xact_age
FROM blocking_tree bt
JOIN pg_stat_activity blocked
    ON blocked.pid = bt.blocked_pid
JOIN pg_stat_activity blocker
    ON blocker.pid = bt.blocker_pid
ORDER BY bt.level, blocker_xact_age DESC;
```

* * *

3\. Safe remediation decision tree
==================================

Preferred order
---------------

1.  **Understand the blocker before killing it.**
2.  **Cancel the blocker query** if it is actively running and safe to retry.
3.  **Terminate the blocker session** only if it is idle in transaction, abandoned, or causing severe outage.
4.  **Avoid killing autovacuum or critical maintenance blindly.**
5.  **Coordinate with application owner before terminating business-critical writes.**

On RDS PostgreSQL, users with the `rds_superuser` role can view connection status and can use `pg_cancel_backend` or `pg_terminate_backend` when needed. AWS recommends limiting this role to DBA or system-administration users. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Roles.rds_superuser.html?utm_source=chatgpt.com)

Cancel active query
-------------------

```
SELECT pg_cancel_backend(<pid>);
```

Use this when the session is actively running a long query and cancellation is enough.

Terminate backend
-----------------

```
SELECT pg_terminate_backend(<pid>);
```

Use this when:

| Condition | Action |
| --- | --- |
| Blocker is `idle in transaction` for long time | Terminate after validation |
| Blocker is application session abandoned by client | Terminate |
| Blocker is migration script holding DDL lock | Cancel or terminate after confirming rollback impact |
| Blocker is core batch job | Coordinate first |
| Blocker is autovacuum | Usually avoid; fix root cause instead |

AWS also documents using `pg_cancel_backend` and `pg_terminate_backend` for ending long-running RDS PostgreSQL sessions. [![](https://www.google.com/s2/favicons?domain=https://www.repost.aws&sz=128)Repost](https://www.repost.aws/knowledge-center/rds-cancel-long-running-queries?utm_source=chatgpt.com)

* * *

4\. Baseline setup for simulations
==================================

Run this in a test database.

```
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS accounts;
DROP TABLE IF EXISTS workflow_jobs;

CREATE TABLE accounts (
    id BIGSERIAL PRIMARY KEY,
    account_no TEXT UNIQUE NOT NULL,
    balance NUMERIC(12,2) NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts(id),
    order_status TEXT NOT NULL DEFAULT 'NEW',
    amount NUMERIC(12,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE order_items (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id),
    sku TEXT NOT NULL,
    qty INT NOT NULL
);

CREATE TABLE workflow_jobs (
    id BIGSERIAL PRIMARY KEY,
    job_key TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    payload JSONB,
    updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO accounts(account_no, balance)
SELECT 'ACC-' || g, 1000
FROM generate_series(1, 1000) g;

INSERT INTO orders(account_id, amount)
SELECT id, 100
FROM accounts
WHERE id <= 100;

INSERT INTO order_items(order_id, sku, qty)
SELECT id, 'SKU-' || id, 1
FROM orders;
```

Use separate database sessions named **Session 1**, **Session 2**, and **DBA Session**.

Set application names so the sessions are easy to identify:

```
SET application_name = 'lock-simulation-session-1';
```

```
SET application_name = 'lock-simulation-session-2';
```

* * *

5\. Scenario 1: Row lock blocking
=================================

How it happens
--------------

One transaction updates a row and does not commit. Another transaction tries to update the same row. The second transaction waits for the first transaction to commit or roll back.

How to simulate it
------------------

**Session 1**

```
BEGIN;

UPDATE accounts
SET balance = balance + 100
WHERE id = 1;

-- Do not commit.
```

**Session 2**

```
BEGIN;

UPDATE accounts
SET balance = balance - 50
WHERE id = 1;

-- This waits.
```

How to detect it
----------------

```
SELECT
    pid,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_age,
    pg_blocking_pids(pid) AS blockers,
    query
FROM pg_stat_activity
WHERE application_name LIKE 'lock-simulation%';
```

Expected result: Session 2 waits with `wait_event_type = 'Lock'`.

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.application_name LIKE 'lock-simulation%';
```

How to resolve it safely
------------------------

Preferred:

```
COMMIT;
-- or
ROLLBACK;
```

Emergency DBA action:

```
SELECT pg_terminate_backend(<session_1_pid>);
```

How to prevent it in production
-------------------------------

Use short transactions, commit quickly, avoid user-interactive transactions, update rows in consistent order, add `lock_timeout`, and ensure application code always commits or rolls back.

Example:

```
SET lock_timeout = '5s';
SET statement_timeout = '60s';
```

* * *

6\. Scenario 2: Table lock blocking
===================================

How it happens
--------------

A session explicitly locks a table using a strong table lock. Other sessions trying to modify or read depending on the lock mode may wait.

How to simulate it
------------------

**Session 1**

```
BEGIN;

LOCK TABLE accounts IN ACCESS EXCLUSIVE MODE;

-- Hold the lock.
SELECT pg_sleep(300);
```

**Session 2**

```
SELECT *
FROM accounts
WHERE id = 1;

-- This waits because ACCESS EXCLUSIVE conflicts even with SELECT.
```

`ACCESS EXCLUSIVE` is the strongest common table lock mode and conflicts broadly. PostgreSQL documentation describes table lock modes and their conflicts. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/explicit-locking.html?utm_source=chatgpt.com)

How to detect it
----------------

```
SELECT
    a.pid,
    a.application_name,
    a.state,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    a.wait_event_type,
    a.wait_event,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.relation = 'accounts'::regclass
ORDER BY l.granted, a.query_start;
```

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.query AS blocker_query,
    blocker.state,
    now() - blocker.xact_start AS blocker_xact_age
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid));
```

How to resolve it safely
------------------------

If Session 1 is a manual maintenance session, commit or roll back:

```
ROLLBACK;
```

If it is an accidental production lock:

```
SELECT pg_cancel_backend(<pid>);
-- If not enough:
SELECT pg_terminate_backend(<pid>);
```

How to prevent it
-----------------

Avoid explicit `LOCK TABLE` in application code. For maintenance, use timeouts:

```
SET lock_timeout = '5s';
LOCK TABLE accounts IN ACCESS EXCLUSIVE MODE;
```

Schedule strong-lock operations during maintenance windows.

* * *

7\. Scenario 3: Deadlock
========================

How it happens
--------------

Two or more transactions hold locks that each other needs. PostgreSQL detects the cycle and aborts one transaction. Explicit locking increases deadlock risk when transactions acquire locks in inconsistent order. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/explicit-locking.html?utm_source=chatgpt.com)

How to simulate it
------------------

**Session 1**

```
BEGIN;

UPDATE accounts
SET balance = balance + 10
WHERE id = 1;
```

**Session 2**

```
BEGIN;

UPDATE accounts
SET balance = balance + 20
WHERE id = 2;
```

**Session 1**

```
UPDATE accounts
SET balance = balance + 10
WHERE id = 2;

-- waits
```

**Session 2**

```
UPDATE accounts
SET balance = balance + 20
WHERE id = 1;

-- deadlock detected; one transaction is aborted
```

How to detect it
----------------

PostgreSQL raises an error similar to:

```
ERROR: deadlock detected
```

Check logs in RDS Console or CloudWatch Logs if PostgreSQL logs are exported. RDS PostgreSQL logs can be viewed through the RDS console, AWS CLI, RDS API, or CloudWatch Logs configuration. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.html?utm_source=chatgpt.com)

Enable lock-wait logging in a parameter group:

```
-- Parameter group settings, not ordinary SQL for all cases:
log_lock_waits = on
deadlock_timeout = '1s'
```

`log_lock_waits` logs waits longer than `deadlock_timeout`; PostgreSQL documentation notes that reducing `deadlock_timeout` can help during lock-delay investigation. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/16//runtime-config-locks.html?utm_source=chatgpt.com)

How to identify the blocker
---------------------------

For deadlocks, one transaction is automatically cancelled, so the live blocker may disappear. Use:

```
SELECT *
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY xact_start NULLS LAST;
```

And review PostgreSQL logs for the deadlock graph.

How to resolve it safely
------------------------

The database resolves the deadlock by aborting one transaction. Application code must catch the error and retry the transaction safely.

How to prevent it
-----------------

Always lock rows in the same order:

```
-- Good pattern
SELECT id
FROM accounts
WHERE id IN (1,2)
ORDER BY id
FOR UPDATE;
```

Then perform updates.

Also use short transactions, avoid mixed object access order, and implement retry logic for deadlock errors.

* * *

8\. Scenario 4: Idle transaction blocking production
====================================================

How it happens
--------------

Application starts a transaction, updates data or acquires locks, then becomes `idle in transaction`. Locks remain held until commit or rollback.

How to simulate it
------------------

**Session 1**

```
BEGIN;

UPDATE accounts
SET status = 'REVIEW'
WHERE id = 10;

-- Now do nothing.
```

**Session 2**

```
UPDATE accounts
SET status = 'ACTIVE'
WHERE id = 10;

-- waits
```

How to detect it
----------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    now() - state_change AS idle_age,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_age DESC;
```

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocker.pid AS idle_blocker_pid,
    blocker.application_name,
    blocker.client_addr,
    now() - blocker.xact_start AS idle_xact_age,
    blocker.query AS last_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocker.state = 'idle in transaction';
```

How to resolve it safely
------------------------

If confirmed abandoned:

```
SELECT pg_terminate_backend(<idle_blocker_pid>);
```

How to prevent it
-----------------

Set:

```
idle_in_transaction_session_timeout = '5min'
```

Also enforce transaction management in application code:

```
begin
  start transaction
  execute work
  commit
catch
  rollback
finally
  release connection
```

* * *

9\. Scenario 5: Long-running transaction blocking vacuum and causing bloat
==========================================================================

How it happens
--------------

A long transaction keeps an old snapshot open. Vacuum cannot fully clean old row versions that are still visible to that transaction. This may increase table bloat, slow queries, and increase storage pressure.

How to simulate it
------------------

**Session 1**

```
BEGIN;

SELECT *
FROM accounts
WHERE id <= 100;

-- Keep transaction open.
```

**Session 2**

```
UPDATE accounts
SET balance = balance + 1
WHERE id <= 100;

DELETE FROM accounts
WHERE id > 900;

VACUUM VERBOSE accounts;
```

How to detect it
----------------

```
SELECT
    pid,
    usename,
    application_name,
    state,
    backend_xmin,
    now() - xact_start AS xact_age,
    query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

Check table vacuum stats:

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    vacuum_count,
    autovacuum_count
FROM pg_stat_user_tables
WHERE relname = 'accounts';
```

PostgreSQL’s statistics views track table activity and vacuum/analyze information, which is useful for this investigation. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/monitoring-stats.html?utm_source=chatgpt.com)

How to identify the blocker
---------------------------

Look for old `backend_xmin` and old `xact_start`:

```
SELECT
    pid,
    application_name,
    client_addr,
    backend_xmin,
    now() - xact_start AS xact_age,
    state,
    query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start;
```

How to resolve it safely
------------------------

Ask application owner to complete the transaction. If abandoned:

```
SELECT pg_terminate_backend(<pid>);
```

Then run:

```
VACUUM (VERBOSE, ANALYZE) accounts;
```

How to prevent it
-----------------

Use transaction timeouts, avoid long read-write transactions, avoid keeping cursors open too long, and monitor long `xact_start` age.

* * *

10\. Scenario 6: DDL blocking DML
=================================

How it happens
--------------

DDL often needs strong locks. For example, `ALTER TABLE` may wait behind active queries and then block new DML once it is queued.

How to simulate it
------------------

**Session 1**

```
BEGIN;

UPDATE accounts
SET balance = balance + 1
WHERE id = 20;

-- Hold transaction open.
```

**Session 2**

```
ALTER TABLE accounts
ADD COLUMN test_col TEXT;

-- waits for Session 1
```

**Session 3**

```
UPDATE accounts
SET balance = balance + 1
WHERE id = 21;

-- may now queue behind the waiting DDL
```

How to detect it
----------------

```
SELECT
    a.pid,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    now() - a.query_start AS query_age,
    a.query
FROM pg_stat_activity a
JOIN pg_locks l ON l.pid = a.pid
WHERE l.relation = 'accounts'::regclass
ORDER BY l.granted, a.query_start;
```

How to identify the blocker
---------------------------

Use the blocker tree query from section 2. DDL blocking often has a chain:

```
Old transaction -> waiting DDL -> new application DML
```

How to resolve it safely
------------------------

Options:

1.  Cancel the DDL if it is blocking production.
2.  Let the old transaction finish.
3.  Terminate the old transaction only if abandoned.
4.  Retry DDL later with `lock_timeout`.

```
SELECT pg_cancel_backend(<ddl_pid>);
```

How to prevent it
-----------------

Use safe migration pattern:

```
SET lock_timeout = '5s';
SET statement_timeout = '5min';

ALTER TABLE accounts ADD COLUMN test_col TEXT;
```

For large tables:

| Bad | Better |
| --- | --- |
| Add column with heavy default in one step | Add nullable column, backfill in batches, add constraint later |
| `CREATE INDEX` | `CREATE INDEX CONCURRENTLY` |
| Long transaction migration | Small, retryable migration steps |

* * *

11\. Scenario 7: Foreign key contention
=======================================

How it happens
--------------

When inserting or updating child rows, PostgreSQL checks parent rows. Concurrent deletes or updates on parent rows can block child inserts/updates, and child table activity can block parent deletes.

How to simulate it
------------------

**Session 1**

```
BEGIN;

DELETE FROM accounts
WHERE id = 30;

-- Do not commit.
```

**Session 2**

```
INSERT INTO orders(account_id, amount)
VALUES (30, 500);

-- waits or fails depending on Session 1 outcome
```

Alternative:

**Session 1**

```
BEGIN;

INSERT INTO orders(account_id, amount)
VALUES (31, 100);

-- hold transaction
```

**Session 2**

```
DELETE FROM accounts
WHERE id = 31;

-- waits because child row may reference parent
```

How to detect it
----------------

```
SELECT
    a.pid,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    a.query
FROM pg_stat_activity a
JOIN pg_locks l ON l.pid = a.pid
WHERE a.query ILIKE '%orders%'
   OR a.query ILIKE '%accounts%'
ORDER BY l.granted, a.query_start;
```

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.query AS blocker_query,
    blocker.state,
    now() - blocker.xact_start AS blocker_xact_age
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid));
```

How to resolve it safely
------------------------

Let the parent/child transaction commit or roll back. If abandoned, terminate the blocker.

```
SELECT pg_terminate_backend(<pid>);
```

How to prevent it
-----------------

Index foreign key columns on child tables:

```
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_account_id
ON orders(account_id);
```

Also avoid large parent deletes during peak hours. Delete in batches.

* * *

12\. Scenario 8: Autovacuum / vacuum contention
===============================================

How it happens
--------------

Autovacuum normally does not block ordinary DML heavily, but it can conflict with DDL or maintenance operations. Conversely, long-running transactions can prevent vacuum cleanup. Manual `VACUUM FULL` is different: it requires a strong lock and can block application traffic.

How to simulate manual vacuum blocking
--------------------------------------

**Session 1**

```
BEGIN;

SELECT *
FROM accounts
WHERE id = 1;

-- Keep transaction open.
```

**Session 2**

```
VACUUM FULL accounts;

-- waits for ACCESS EXCLUSIVE lock
```

**Session 3**

```
UPDATE accounts
SET balance = balance + 1
WHERE id = 2;

-- may become blocked behind VACUUM FULL
```

How to detect it
----------------

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

Check blockers:

```
SELECT
    a.pid,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    now() - a.xact_start AS xact_age,
    a.query,
    pg_blocking_pids(a.pid) AS blockers
FROM pg_stat_activity a
WHERE a.query ILIKE '%vacuum%'
   OR cardinality(pg_blocking_pids(a.pid)) > 0;
```

How to identify the blocker
---------------------------

Look for long transactions and blockers of the vacuum backend:

```
SELECT
    blocked.pid AS vacuum_or_blocked_pid,
    blocked.query AS waiting_query,
    blocker.pid AS blocker_pid,
    blocker.state,
    now() - blocker.xact_start AS blocker_xact_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.query ILIKE '%vacuum%';
```

How to resolve it safely
------------------------

Avoid killing autovacuum unless there is a severe emergency. Prefer resolving the transaction blocking vacuum.

For manual `VACUUM FULL`, cancel it if it is blocking production:

```
SELECT pg_cancel_backend(<vacuum_full_pid>);
```

How to prevent it
-----------------

Use normal autovacuum tuning, avoid `VACUUM FULL` during business hours, prefer `pg_repack` where available and approved, batch deletes, and monitor dead tuples.

* * *

13\. Scenario 9: Index operation blocking
=========================================

How it happens
--------------

Regular `CREATE INDEX` can block writes. `CREATE INDEX CONCURRENTLY` reduces blocking but takes longer and has restrictions. It cannot run inside a transaction block.

How to simulate blocking index creation
---------------------------------------

**Session 1**

```
BEGIN;

UPDATE orders
SET amount = amount + 1
WHERE id = 1;

-- Hold transaction.
```

**Session 2**

```
CREATE INDEX idx_orders_amount_blocking
ON orders(amount);

-- waits
```

**Session 3**

```
INSERT INTO orders(account_id, amount)
VALUES (1, 200);

-- may be blocked depending on lock queue
```

How to detect it
----------------

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

Also:

```
SELECT
    a.pid,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    l.mode,
    l.granted,
    l.relation::regclass,
    a.query
FROM pg_stat_activity a
JOIN pg_locks l ON l.pid = a.pid
WHERE a.query ILIKE '%index%'
   OR l.relation = 'orders'::regclass
ORDER BY l.granted, a.query_start;
```

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.query AS blocker_query,
    now() - blocker.xact_start AS blocker_xact_age
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.query ILIKE '%index%';
```

How to resolve it safely
------------------------

Cancel blocking index build:

```
SELECT pg_cancel_backend(<create_index_pid>);
```

If using `CREATE INDEX CONCURRENTLY` and it fails, check for invalid indexes:

```
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE tablename = 'orders';
```

Drop invalid or failed index if needed:

```
DROP INDEX CONCURRENTLY IF EXISTS idx_orders_amount_blocking;
```

How to prevent it
-----------------

Use:

```
CREATE INDEX CONCURRENTLY idx_orders_amount
ON orders(amount);
```

For production, always use:

```
SET lock_timeout = '5s';
SET statement_timeout = '30min';
```

* * *

14\. Scenario 10: Connection pool exhaustion / PgBouncer exhaustion
===================================================================

How it happens
--------------

Application opens more sessions than PostgreSQL or PgBouncer can serve. Sessions wait for pool slots or fail with connection errors. This may look like database blocking even when no row/table lock exists.

PgBouncer has client-side and server-side limits. `max_client_conn` controls how many clients can connect to PgBouncer, and `pool_mode` controls when server connections are returned to the pool: session, transaction, or statement. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)pgbouncer.org](https://www.pgbouncer.org/config.html?utm_source=chatgpt.com)

How to simulate it
------------------

From multiple shells or app workers, open many connections and keep them idle or in transaction.

Example with `psql`:

```
for i in $(seq 1 200); do
  psql "$DATABASE_URL" -c "SELECT pg_sleep(300);" &
done
```

For transaction pool exhaustion:

```
BEGIN;
SELECT pg_sleep(300);
```

Run this from many sessions.

How to detect it inside PostgreSQL
----------------------------------

```
SELECT
    state,
    wait_event_type,
    wait_event,
    count(*) AS session_count
FROM pg_stat_activity
GROUP BY state, wait_event_type, wait_event
ORDER BY session_count DESC;
```

Check total connections:

```
SELECT
    count(*) AS current_connections,
    current_setting('max_connections')::int AS max_connections,
    round(100.0 * count(*) / current_setting('max_connections')::int, 2) AS pct_used
FROM pg_stat_activity;
```

Find connection-heavy users/apps:

```
SELECT
    usename,
    application_name,
    client_addr,
    state,
    count(*) AS connections
FROM pg_stat_activity
GROUP BY usename, application_name, client_addr, state
ORDER BY connections DESC;
```

How to detect in PgBouncer
--------------------------

Run on PgBouncer admin database:

```
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
```

Look for:

| PgBouncer field | Meaning |
| --- | --- |
| `cl_waiting` | Clients waiting for server connection |
| `sv_active` | Active server connections |
| `sv_idle` | Idle server connections |
| `maxwait` | Longest wait time |
| Pool at `default_pool_size` | Server-side pool limit reached |

How to identify the blocker
---------------------------

In pool exhaustion, there may be no single blocker. Root cause may be:

| Root cause | Evidence |
| --- | --- |
| Leaked app connections | Many idle sessions from same app/client |
| Long transactions | Many sessions with old `xact_start` |
| Slow queries | Many active sessions with same SQL |
| PgBouncer pool too small | High `cl_waiting`, low DB pressure |
| DB max connections reached | RDS `DatabaseConnections` near max |

How to resolve it safely
------------------------

Short-term:

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND now() - state_change > interval '30 minutes'
  AND usename = '<app_user>';
```

Be careful: killing active business transactions may roll back work.

PgBouncer emergency options:

```
PAUSE;
KILL <database>;
RESUME;
```

Use only if you understand impact.

How to prevent it
-----------------

Use PgBouncer transaction pooling where application-compatible, set sane app pool limits, use connection leak detection, configure `idle_session_timeout`, `idle_in_transaction_session_timeout`, and keep RDS `max_connections` below memory-safe limits.

* * *

15\. Scenario 11: Application workflow blockage
===============================================

How it happens
--------------

A business workflow gets stuck because a database row represents a workflow state, job, tenant, user, subscription, backup job, restore job, or queue item. One worker locks the workflow row and does not complete. Other workers wait.

How to simulate it
------------------

**Session 1**

```
INSERT INTO workflow_jobs(job_key, status, payload)
VALUES ('backup-user-1001', 'RUNNING', '{"user_id":1001}')
ON CONFLICT (job_key) DO UPDATE
SET status = excluded.status,
    payload = excluded.payload;

BEGIN;

SELECT *
FROM workflow_jobs
WHERE job_key = 'backup-user-1001'
FOR UPDATE;

-- Hold lock.
```

**Session 2**

```
BEGIN;

SELECT *
FROM workflow_jobs
WHERE job_key = 'backup-user-1001'
FOR UPDATE;

-- waits
```

How to detect it
----------------

```
SELECT
    a.pid,
    a.application_name,
    a.client_addr,
    a.state,
    a.wait_event_type,
    a.wait_event,
    now() - a.query_start AS query_age,
    pg_blocking_pids(a.pid) AS blockers,
    a.query
FROM pg_stat_activity a
WHERE a.query ILIKE '%workflow_jobs%'
ORDER BY query_age DESC;
```

How to identify the blocker
---------------------------

```
SELECT
    blocked.pid AS blocked_worker_pid,
    blocked.application_name AS blocked_worker,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_worker_pid,
    blocker.application_name AS blocker_worker,
    blocker.client_addr,
    blocker.state,
    now() - blocker.xact_start AS blocker_xact_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
    ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.query ILIKE '%workflow_jobs%';
```

How to resolve it safely
------------------------

1.  Confirm whether the worker is still alive.
2.  Check application logs for the job ID.
3.  If worker crashed or is idle in transaction, terminate DB session.
4.  Reset workflow state only after verifying idempotency.

Example:

```
UPDATE workflow_jobs
SET status = 'PENDING',
    updated_at = now()
WHERE job_key = 'backup-user-1001'
  AND status = 'RUNNING'
  AND updated_at < now() - interval '30 minutes';
```

How to prevent it
-----------------

Use `FOR UPDATE SKIP LOCKED` for queue-style workers:

```
WITH next_job AS (
    SELECT id
    FROM workflow_jobs
    WHERE status = 'PENDING'
    ORDER BY id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
UPDATE workflow_jobs j
SET status = 'RUNNING',
    updated_at = now()
FROM next_job
WHERE j.id = next_job.id
RETURNING j.*;
```

Also add job heartbeats, retry counters, idempotency keys, and stuck-job recovery.

* * *

16\. Scenario 12: Lock queue amplification
==========================================

How it happens
--------------

A waiting DDL or strong lock request queues behind an old transaction. New DML that would normally be compatible can queue behind the waiting strong lock. This creates sudden production impact.

How to simulate it
------------------

**Session 1**

```
BEGIN;

SELECT *
FROM accounts
WHERE id = 1;

-- Hold transaction.
```

**Session 2**

```
ALTER TABLE accounts ADD COLUMN queue_test TEXT;

-- waits
```

**Session 3**

```
UPDATE accounts
SET balance = balance + 1
WHERE id = 2;

-- may wait behind DDL
```

How to detect it
----------------

Use blocking tree:

```
WITH blocked AS (
    SELECT
        pid AS blocked_pid,
        unnest(pg_blocking_pids(pid)) AS blocker_pid
    FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0
)
SELECT
    blocked.blocked_pid,
    ba.query AS blocked_query,
    blocked.blocker_pid,
    ka.query AS blocker_query,
    ka.state AS blocker_state,
    now() - ka.xact_start AS blocker_xact_age
FROM blocked
JOIN pg_stat_activity ba ON ba.pid = blocked.blocked_pid
JOIN pg_stat_activity ka ON ka.pid = blocked.blocker_pid
ORDER BY blocker_xact_age DESC NULLS LAST;
```

How to resolve it safely
------------------------

Usually cancel the queued DDL first:

```
SELECT pg_cancel_backend(<ddl_pid>);
```

If application still blocked, resolve the original old transaction.

How to prevent it
-----------------

All production DDL should use short `lock_timeout`. Migration tooling should fail fast instead of waiting indefinitely.

* * *

17\. RDS Performance Insights investigation
===========================================

Use Performance Insights during incidents like this:

View
----

RDS Console → Databases → DB instance → Performance Insights

Analyze
-------

| PI area | What to check |
| --- | --- |
| DB Load chart | Is DBLoad above vCPU line? |
| Waits | Are waits dominated by `Lock`, `LWLock`, I/O, CPU, Client? |
| Top SQL | Which SQL contributes most to load? |
| Top users | Which DB user is responsible? |
| Top hosts | Which app server is responsible? |
| Top databases | Which database is impacted? |

AWS RDS wait-event documentation provides RDS PostgreSQL wait events, common causes, and corrective actions; use it to map symptoms to root causes. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.summary.html?utm_source=chatgpt.com)

Common wait interpretation
--------------------------

| Wait type/event | Meaning |
| --- | --- |
| `Lock` | Session waiting on relation, tuple, transaction, advisory, or DDL lock |
| `ClientRead` | DB waiting for client to send more data; sometimes idle app behavior |
| `ClientWrite` | DB waiting to send data to client; slow client/network |
| `IO:*` | Storage/page read/write pressure |
| `LWLock:*` | Internal lightweight lock contention |
| CPU with high DBLoad | CPU saturation or inefficient SQL |

* * *

18\. CloudWatch and RDS log analysis
====================================

CloudWatch metrics to check
---------------------------

| Metric | Why it matters |
| --- | --- |
| `DatabaseConnections` | Detect connection exhaustion |
| `CPUUtilization` | CPU saturation |
| `FreeableMemory` | Memory pressure |
| `ReadIOPS` / `WriteIOPS` | I/O pressure |
| `ReadLatency` / `WriteLatency` | Storage latency |
| `DiskQueueDepth` | Storage backlog |
| `FreeStorageSpace` | Bloat or WAL/storage growth |
| `TransactionLogsGeneration` if available | Heavy write/WAL pressure |
| `Deadlocks` if available in monitoring stack | Deadlock trend |

Amazon RDS publishes CloudWatch metrics in the `AWS/RDS` namespace, and the metrics reference documents RDS, Performance Insights, and Enhanced Monitoring metrics. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-metrics.html?utm_source=chatgpt.com)

PostgreSQL logging parameters for lock investigations
-----------------------------------------------------

Recommended for investigation:

```
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 1000ms
log_line_prefix = '%m [%p] %u@%d app=%a client=%h '
```

Be careful with verbose logging on high-throughput production systems.

CloudWatch Logs Insights examples
---------------------------------

Find deadlocks:

```
fields @timestamp, @message
| filter @message like /deadlock detected/
| sort @timestamp desc
| limit 50
```

Find lock waits:

```
fields @timestamp, @message
| filter @message like /still waiting for/
   or @message like /acquired/
   or @message like /Process/
| sort @timestamp desc
| limit 100
```

Find statements by application name:

```
fields @timestamp, @message
| filter @message like /app=/
| sort @timestamp desc
| limit 100
```

* * *

19\. Root-cause classification matrix
=====================================

| Category | Evidence | Root cause | Remediation |
| --- | --- | --- | --- |
| Row lock | Blocked on tuple/transactionid | Same row updated by another open transaction | Commit/rollback blocker |
| Table lock | Relation lock, strong mode | Explicit lock, DDL, maintenance | Cancel DDL or terminate abandoned blocker |
| Deadlock | Deadlock error in logs | Inconsistent lock order | Retry transaction, fix access order |
| Idle transaction | `state = idle in transaction` | App forgot commit/rollback | Terminate session, fix app |
| Long transaction | Old `xact_start`, `backend_xmin` | Batch/report/cursor open too long | End transaction, split work |
| DDL blocking | Waiting `ALTER TABLE`, `CREATE INDEX` | Migration without timeout | Cancel, retry with safe migration |
| FK contention | Parent/child table locks | Missing FK index, parent delete/update | Add FK indexes, batch deletes |
| Vacuum contention | Vacuum waiting or blocked cleanup | Long transaction or `VACUUM FULL` | End long xact, avoid `VACUUM FULL` |
| Index operation | `pg_stat_progress_create_index` | Regular index build on busy table | Use `CONCURRENTLY` |
| Pool exhaustion | High connections or PgBouncer `cl_waiting` | App pool leak, small pool, slow queries | Kill idle, tune pool |
| Workflow blockage | Business rows locked | Worker stuck holding job row | Terminate worker, reset idempotently |

* * *

20\. Agent-based RCA workflow
=============================

This is a practical workflow for an AI/automation agent that investigates and reports root cause.

Agent input
-----------

```
{
  "db_instance": "prod-rds-postgres-01",
  "database": "appdb",
  "incident_time": "2026-06-07T10:30:00+05:30",
  "symptom": "backup workflow stuck",
  "safe_mode": true
}
```

Agent workflow
--------------

### Step 1: Collect database session snapshot

Run:

```
SELECT
    now() AS snapshot_time,
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    backend_type,
    xact_start,
    query_start,
    state_change,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    pg_blocking_pids(pid) AS blocking_pids,
    left(query, 4000) AS query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
ORDER BY xact_start NULLS LAST, query_start NULLS LAST;
```

### Step 2: Collect lock snapshot

```
SELECT
    now() AS snapshot_time,
    l.pid,
    a.application_name,
    a.usename,
    a.client_addr,
    l.locktype,
    l.database,
    l.relation::regclass AS relation_name,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    l.classid,
    l.objid,
    l.objsubid,
    l.mode,
    l.granted,
    a.state,
    a.wait_event_type,
    a.wait_event,
    left(a.query, 4000) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
ORDER BY l.granted, l.pid;
```

### Step 3: Classify incident

Pseudo-logic:

```
IF blocked_sessions > 0 AND blockers include idle in transaction:
    category = "Idle transaction blocking"
ELSE IF deadlock found in logs:
    category = "Deadlock"
ELSE IF waiting query is ALTER/CREATE/DROP/TRUNCATE:
    category = "DDL blocking"
ELSE IF relation involves child/parent FK tables:
    category = "Foreign key contention"
ELSE IF DatabaseConnections near max_connections:
    category = "Connection exhaustion"
ELSE IF PgBouncer cl_waiting > 0:
    category = "PgBouncer pool exhaustion"
ELSE IF long xact with backend_xmin:
    category = "Long transaction / vacuum blocker"
ELSE IF wait_event_type = Lock:
    category = "Generic lock contention"
ELSE:
    category = "Non-lock performance issue"
```

### Step 4: Identify blast radius

```
SELECT
    unnest(pg_blocking_pids(pid)) AS blocker_pid,
    count(*) AS blocked_session_count
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
GROUP BY blocker_pid
ORDER BY blocked_session_count DESC;
```

### Step 5: Generate RCA

Agent should output:

```
Incident type:
Primary blocker:
Blocked sessions:
Blocked SQL:
Blocking SQL:
Application name:
Client IP:
Transaction age:
Business object affected:
Recommended action:
Risk of termination:
Prevention:
```

### Step 6: Remediation mode

In **safe mode**, the agent should only recommend.

In **controlled remediation mode**, the agent may execute:

```
SELECT pg_cancel_backend(<pid>);
```

Only with policy approval should it execute:

```
SELECT pg_terminate_backend(<pid>);
```

* * *

21\. Production-safe remediation playbook
=========================================

Case A: Blocker is idle in transaction
--------------------------------------

```
SELECT pg_terminate_backend(<pid>);
```

Risk: rolls back uncommitted work.

Case B: Blocker is active reporting query
-----------------------------------------

```
SELECT pg_cancel_backend(<pid>);
```

Risk: report fails, transaction may remain open depending on client behavior.

Case C: Blocker is DDL migration
--------------------------------

```
SELECT pg_cancel_backend(<ddl_pid>);
```

Risk: migration fails and must be retried.

Case D: Blocker is application worker
-------------------------------------

1.  Check application logs.
2.  Confirm job id / tenant id / user id.
3.  Kill only if worker is stuck.
4.  Reset workflow state idempotently.

Case E: Database connections exhausted
--------------------------------------

Terminate old idle sessions first:

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND now() - state_change > interval '1 hour'
  AND usename NOT IN ('rdsadmin');
```

Then review app pool settings.

* * *

22\. Preventive best practices
==============================

Database-level settings
-----------------------

Use these through RDS parameter group where appropriate:

```
log_lock_waits = on
deadlock_timeout = 1s or 2s during investigation
idle_in_transaction_session_timeout = 5min to 15min
statement_timeout = workload-specific
lock_timeout = migration/session-specific
track_activity_query_size = 4096 or higher
shared_preload_libraries = pg_stat_statements
```

For RDS PostgreSQL, AWS notes that `pg_stat_statements` is the default shared preload library for RDS PostgreSQL 10 and higher, and it is used for query analysis. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.html?utm_source=chatgpt.com)

Application best practices
--------------------------

1.  Always commit or rollback.
2.  Keep transactions short.
3.  Never wait for external APIs while holding DB transaction.
4.  Lock rows in consistent order.
5.  Use retries for deadlocks.
6.  Use `FOR UPDATE SKIP LOCKED` for worker queues.
7.  Use idempotency keys for retried workflows.
8.  Set application name per service/module.
9.  Right-size app connection pools.
10.  Monitor idle-in-transaction sessions.

Migration best practices
------------------------

Use:

```
SET lock_timeout = '5s';
SET statement_timeout = '10min';
```

Prefer:

```
CREATE INDEX CONCURRENTLY
```

Avoid:

```
VACUUM FULL
ALTER TABLE huge_table ADD COLUMN col DEFAULT expensive_value NOT NULL
CREATE INDEX on huge busy table without CONCURRENTLY
```

Foreign key best practices
--------------------------

Always index child-side FK columns:

```
CREATE INDEX CONCURRENTLY idx_order_items_order_id
ON order_items(order_id);

CREATE INDEX CONCURRENTLY idx_orders_account_id
ON orders(account_id);
```

Monitoring alerts
-----------------

Create alerts for:

| Alert | Suggested condition |
| --- | --- |
| High connections | `DatabaseConnections > 80% max_connections` |
| Lock waits | Count of sessions with `wait_event_type = 'Lock' > threshold` |
| Long transaction | `xact_age > 10 minutes` |
| Idle in transaction | `idle_xact_age > 5 minutes` |
| Deadlocks | Any deadlock count > 0 |
| DBLoad | DBLoad above vCPU line for sustained period |
| PgBouncer waiting clients | `cl_waiting > 0` |
| Autovacuum lag | high `n_dead_tup`, old `last_autovacuum` |
| Storage pressure | falling `FreeStorageSpace` |

* * *

23\. One-page incident checklist
================================

Use this during production incidents.

```
-- 1. Current blockers
SELECT
    pid,
    state,
    wait_event_type,
    wait_event,
    pg_blocking_pids(pid) AS blockers,
    now() - query_start AS query_age,
    now() - xact_start AS xact_age,
    query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY query_age DESC;

-- 2. Idle transactions
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - xact_start AS xact_age,
    now() - state_change AS idle_age,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_age DESC;

-- 3. Long transactions
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    backend_xmin,
    now() - xact_start AS xact_age,
    query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;

-- 4. Connection usage
SELECT
    count(*) AS current_connections,
    current_setting('max_connections')::int AS max_connections,
    round(100.0 * count(*) / current_setting('max_connections')::int, 2) AS pct_used
FROM pg_stat_activity;

-- 5. Connection distribution
SELECT
    usename,
    application_name,
    client_addr,
    state,
    count(*) AS connections
FROM pg_stat_activity
GROUP BY usename, application_name, client_addr, state
ORDER BY connections DESC;

-- 6. Lock details
SELECT
    a.pid,
    a.application_name,
    a.state,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    l.transactionid,
    a.wait_event_type,
    a.wait_event,
    now() - a.xact_start AS xact_age,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
ORDER BY l.granted ASC, xact_age DESC NULLS LAST;
```

* * *

24\. Final recommendation for your agent design
===============================================

For your automated RCA agent, implement this order:

1.  Capture `pg_stat_activity`, `pg_locks`, blocker tree, long transactions, idle transactions, connection count.
2.  Pull Performance Insights DBLoad, waits, and Top SQL for the incident window.
3.  Pull CloudWatch metrics: connections, CPU, memory, IOPS, latency, storage.
4.  Pull PostgreSQL logs from CloudWatch Logs for deadlock and lock-wait messages.
5.  Classify root cause using the matrix above.
6.  Produce a human-readable RCA.
7.  In safe mode, recommend action only.
8.  In approved remediation mode, cancel first, terminate only if policy allows.
9.  Store incident fingerprint: blocker SQL hash, app name, client, relation, lock mode, wait event, and remediation outcome.

The most important production rule is: **do not just kill the blocked sessions**. Always identify and resolve the **root blocker**. Killing blocked sessions usually treats the symptom; resolving the blocker clears the queue.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)