# PgBouncer Connection Exhaustion

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:41:23  
**Link:** [https://chatgpt.com/share/e/6a27c0a3-bc9c-8013-8781-cc1ffdd857f9](https://chatgpt.com/share/e/6a27c0a3-bc9c-8013-8781-cc1ffdd857f9)  

## Prompt:
We are working on Connection Exhaust for Postgres, pgbouncer in RDS Environment.
Can you create the differenet scenarious to reproduce the issue.

Once there is blocking,agent needs to find the root cause of the blocking simulate the solution by creating blocking by opening a transaction and making other connections wait indefinitely.

Show moreShow less

## Response:
I’ll structure this as a reproducible test plan: connection exhaustion scenarios, blocking/lock scenarios, expected symptoms, SQL to simulate them, and what the agent should inspect to identify root cause and suggest remediation.

Thought for 6s

Below is a practical **reproduction test plan** for **PostgreSQL connection exhaustion + PgBouncer pool exhaustion + blocking root-cause detection** in an **AWS RDS PostgreSQL environment**.

Use only in a **non-production RDS instance**.

* * *

1\. Goal
========

You want to simulate these classes of incidents:

1.  **Postgres connection exhaustion**
    *   Direct DB connections reach `max_connections`.
    *   New connections fail or wait.
2.  **PgBouncer pool exhaustion**
    *   App connects to PgBouncer successfully, but PgBouncer cannot get enough backend server connections to Postgres.
    *   Clients wait in PgBouncer.
3.  **Database blocking**
    *   One transaction holds a row/table lock.
    *   Other sessions wait indefinitely.
    *   Agent should identify:
        *   blocked query
        *   blocking query
        *   blocking PID
        *   lock type
        *   transaction age
        *   application/user/database involved
        *   safe remediation

PgBouncer supports `pool_mode` values such as `session`, `transaction`, and `statement`, and its server reuse behavior changes depending on the mode. `max_client_conn` limits client-side PgBouncer connections, while pool-size settings such as `default_pool_size` affect backend connections to Postgres. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)PgBouncer](https://www.pgbouncer.org/config.html?utm_source=chatgpt.com) PostgreSQL lock diagnosis typically uses `pg_stat_activity`, `pg_locks`, and `pg_blocking_pids()`. [![](https://www.google.com/s2/favicons?domain=https://wiki.postgresql.org&sz=128)PostgreSQL Wiki](https://wiki.postgresql.org/wiki/Lock_Monitoring?utm_source=chatgpt.com) AWS also recommends using PostgreSQL statistics such as `pg_stat_statements` for SQL-level visibility in RDS PostgreSQL. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.PostgreSQL.html?utm_source=chatgpt.com)

* * *

2\. Base Test Table
===================

Run this once:

```
CREATE TABLE IF NOT EXISTS blocking_test (
    id BIGINT PRIMARY KEY,
    name TEXT,
    updated_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO blocking_test (id, name)
VALUES (1, 'initial')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    updated_at = now();
```

Optional helper table for connection-load tests:

```
CREATE TABLE IF NOT EXISTS connection_test (
    id BIGSERIAL PRIMARY KEY,
    payload TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

* * *

3\. Scenario Matrix
===================

| Scenario | What it Reproduces | Expected Symptom |
| --- | --- | --- |
| S1 | Row-level blocking | Queries wait on lock |
| S2 | Table-level blocking | Many operations blocked |
| S3 | Idle transaction holding lock | `idle in transaction` blocker |
| S4 | PgBouncer transaction pool exhaustion | PgBouncer clients waiting |
| S5 | PgBouncer session pool exhaustion | Server connections pinned |
| S6 | Direct Postgres connection exhaustion | `remaining connection slots are reserved` or connection failure |
| S7 | Long-running query consuming pool | High active sessions, slow app |
| S8 | Prepared transaction / uncommitted transaction issue | Persistent lock until resolved |
| S9 | Autovacuum / DDL lock conflict | DDL or maintenance blocked |
| S10 | App-side leaked connections | Many idle sessions, pool starvation |

* * *

4\. Scenario S1: Row-Level Blocking
===================================

Purpose
-------

Simulate a user transaction updating a row and not committing. Other sessions trying to update the same row will wait.

Session 1: Blocker
------------------

```
BEGIN;

UPDATE blocking_test
SET name = 'locked by session 1',
    updated_at = now()
WHERE id = 1;

-- Do not COMMIT or ROLLBACK.
-- Keep this session open.
```

Session 2: Blocked session
--------------------------

```
UPDATE blocking_test
SET name = 'waiting from session 2',
    updated_at = now()
WHERE id = 1;
```

This query should wait until Session 1 commits or rolls back.

Agent root-cause query
----------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_app,
    blocked.client_addr AS blocked_client,
    blocked.state AS blocked_state,
    blocked.wait_event_type AS blocked_wait_type,
    blocked.wait_event AS blocked_wait_event,
    now() - blocked.query_start AS blocked_duration,
    blocked.query AS blocked_query,

    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.application_name AS blocker_app,
    blocker.client_addr AS blocker_client,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_transaction_age,
    now() - blocker.query_start AS blocker_query_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
  ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
ORDER BY blocked_duration DESC;
```

Expected finding
----------------

The agent should report something like:

> PID X is blocked by PID Y. The blocker has an open transaction that updated `blocking_test.id = 1` and has not committed. The blocked query is waiting on a lock.

Cleanup
-------

```
ROLLBACK;
```

or:

```
COMMIT;
```

from Session 1.

* * *

5\. Scenario S2: Table-Level Blocking
=====================================

Purpose
-------

Simulate a lock that blocks reads/writes or DDL.

Session 1: Blocker
------------------

```
BEGIN;

LOCK TABLE blocking_test IN ACCESS EXCLUSIVE MODE;

-- Keep transaction open.
```

Session 2: Blocked read
-----------------------

```
SELECT * FROM blocking_test WHERE id = 1;
```

Session 3: Blocked write
------------------------

```
UPDATE blocking_test
SET name = 'waiting on table lock'
WHERE id = 1;
```

Agent detection
---------------

```
SELECT
    a.pid,
    a.usename,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    now() - a.query_start AS query_age,
    pg_blocking_pids(a.pid) AS blocking_pids,
    a.query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY query_age DESC;
```

Cleanup
-------

```
ROLLBACK;
```

* * *

6\. Scenario S3: Idle Transaction Holding Lock
==============================================

This is one of the most realistic production issues.

Session 1
---------

```
BEGIN;

UPDATE blocking_test
SET name = 'idle transaction blocker',
    updated_at = now()
WHERE id = 1;

-- Now do nothing.
-- The session becomes idle in transaction.
```

Session 2
---------

```
UPDATE blocking_test
SET name = 'blocked by idle transaction',
    updated_at = now()
WHERE id = 1;
```

Agent query
-----------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start AS transaction_age,
    now() - state_change AS state_age,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;
```

Expected root cause
-------------------

The blocker will appear as:

```
state = idle in transaction
```

The agent should identify this as high-risk because the query itself may look harmless, but the open transaction is still holding locks.

Suggested remediation
---------------------

First option:

```
SELECT pg_cancel_backend(<blocked_pid>);
```

For the blocker, if confirmed safe:

```
SELECT pg_terminate_backend(<blocker_pid>);
```

In RDS PostgreSQL, this usually requires the connected user to have sufficient privileges, commonly the RDS master user or a role with appropriate permissions.

* * *

7\. Scenario S4: PgBouncer Transaction Pool Exhaustion
======================================================

Purpose
-------

Simulate too many concurrent transactions consuming PgBouncer backend pool connections.

This is especially relevant when PgBouncer is in:

```
pool_mode = transaction
default_pool_size = small value, for example 5
```

PgBouncer test config idea
--------------------------

For a test environment:

```
pool_mode = transaction
max_client_conn = 100
default_pool_size = 5
reserve_pool_size = 0
query_wait_timeout = 0
```

`query_wait_timeout = 0` means clients may wait indefinitely, which is useful for reproducing the issue but risky in real production.

Open 5 sessions through PgBouncer
---------------------------------

In each session:

```
BEGIN;
SELECT pg_sleep(600);
```

These sessions occupy the transaction pool.

Open 6th session through PgBouncer
----------------------------------

```
SELECT now();
```

Expected behavior:

*   PgBouncer accepts the client connection.
*   Query waits because no server connection is available.
*   PgBouncer pool shows waiting clients.

PgBouncer inspection
--------------------

Connect to PgBouncer admin database:

```
psql -h <pgbouncer-host> -p 6432 -U <pgbouncer-admin-user> pgbouncer
```

Run:

```
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
```

Expected signs:

```
cl_waiting > 0
sv_active = default_pool_size
```

Agent should conclude
---------------------

> PgBouncer pool is exhausted. Client connections are accepted, but backend server connections are fully occupied by long-running transactions.

* * *

8\. Scenario S5: PgBouncer Session Pool Exhaustion
==================================================

Purpose
-------

Simulate a case where app sessions pin server connections.

This happens more often with:

```
pool_mode = session
```

In session pooling, PgBouncer keeps the server connection assigned until the client disconnects. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)PgBouncer](https://www.pgbouncer.org/config.html?utm_source=chatgpt.com)

PgBouncer config
----------------

```
pool_mode = session
default_pool_size = 5
max_client_conn = 100
```

Open 5 client sessions through PgBouncer
----------------------------------------

In each:

```
SELECT pg_sleep(600);
```

or simply keep the session open.

Open 6th client session
-----------------------

```
SELECT 1;
```

Expected:

*   It may wait for a server connection.
*   PgBouncer admin console shows waiting clients.

Agent finding
-------------

The agent should distinguish this from database lock blocking:

*   In DB blocking, `pg_blocking_pids()` shows blockers.
*   In PgBouncer pool exhaustion, the query may not even reach Postgres.
*   PgBouncer `SHOW POOLS` shows waiters.

* * *

9\. Scenario S6: Direct PostgreSQL Connection Exhaustion
========================================================

Purpose
-------

Bypass PgBouncer and connect directly to RDS PostgreSQL until `max_connections` is reached.

Check current limit
-------------------

```
SHOW max_connections;
```

Check current usage
-------------------

```
SELECT
    count(*) AS total_connections,
    count(*) FILTER (WHERE state = 'active') AS active_connections,
    count(*) FILTER (WHERE state = 'idle') AS idle_connections,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction_connections
FROM pg_stat_activity;
```

Simple shell loop
-----------------

From a client machine:

```
for i in $(seq 1 200); do
  psql "host=<rds-endpoint> port=5432 dbname=<db> user=<user> password=<password> sslmode=require" \
    -c "SELECT pg_sleep(600);" &
done
```

Adjust `200` based on your RDS `max_connections`.

Expected error
--------------

Eventually you may see errors like:

```
FATAL: sorry, too many clients already
```

or:

```
FATAL: remaining connection slots are reserved for non-replication superuser connections
```

Agent query
-----------

```
SELECT
    datname,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    count(*) AS connection_count,
    max(now() - backend_start) AS oldest_connection_age,
    max(now() - xact_start) AS oldest_transaction_age
FROM pg_stat_activity
GROUP BY
    datname,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event
ORDER BY connection_count DESC;
```

Agent finding
-------------

The agent should identify:

*   which app/user/client is consuming connections
*   whether they are active, idle, or idle in transaction
*   whether the issue is direct DB exhaustion or PgBouncer-side exhaustion

* * *

10\. Scenario S7: Long-Running Query Consuming Pool
===================================================

Session through PgBouncer or direct DB
--------------------------------------

```
SELECT pg_sleep(600);
```

Run many concurrent sessions.

Agent query
-----------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_duration,
    query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_duration DESC;
```

Expected finding
----------------

The agent should classify this as:

```
Long-running active query consuming backend connection
```

not necessarily lock blocking.

* * *

11\. Scenario S8: Explicit Lock Using SELECT FOR UPDATE
=======================================================

Purpose
-------

Simulate application-level row locking.

Session 1
---------

```
BEGIN;

SELECT *
FROM blocking_test
WHERE id = 1
FOR UPDATE;

-- Keep transaction open.
```

Session 2
---------

```
SELECT *
FROM blocking_test
WHERE id = 1
FOR UPDATE;
```

or:

```
UPDATE blocking_test
SET name = 'blocked by select for update'
WHERE id = 1;
```

Expected finding
----------------

The agent should report:

```
Session 1 is holding a row lock using SELECT FOR UPDATE.
Session 2 is waiting for the same row.
```

* * *

12\. Scenario S9: DDL Blocking
==============================

Purpose
-------

Simulate schema changes blocked by active transactions.

Session 1
---------

```
BEGIN;

SELECT *
FROM blocking_test
WHERE id = 1;

-- Keep transaction open.
```

Session 2
---------

```
ALTER TABLE blocking_test ADD COLUMN IF NOT EXISTS test_col TEXT;
```

Depending on lock requirements and transaction behavior, DDL may wait.

Agent query
-----------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocked.wait_event_type,
    blocked.wait_event,
    blocker.pid AS blocker_pid,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_xact_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
  ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.query ILIKE 'alter table%'
ORDER BY blocker_xact_age DESC;
```

* * *

13\. Scenario S10: App-Side Connection Leak
===========================================

Purpose
-------

Simulate application opening many connections and not closing them.

Python example
--------------

```
import psycopg2
import time

connections = []

dsn = "host=<host> port=<port> dbname=<db> user=<user> password=<password> sslmode=require"

for i in range(100):
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    cur.execute("SELECT 1")
    connections.append(conn)
    print(f"Opened connection {i + 1}")

time.sleep(600)
```

Expected DB state
-----------------

```
SELECT
    application_name,
    client_addr,
    state,
    count(*)
FROM pg_stat_activity
GROUP BY application_name, client_addr, state
ORDER BY count(*) DESC;
```

Expected:

```
many idle connections from the same app/client
```

Agent finding
-------------

The agent should classify this as:

```
Connection leak / excessive idle connections
```

not lock blocking.

* * *

14\. Main Agent Diagnosis Query Pack
====================================

The agent should run these in order.

A. Connection summary
---------------------

```
SELECT
    count(*) AS total_connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    count(*) FILTER (WHERE state = 'idle') AS idle,
    count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction,
    count(*) FILTER (WHERE wait_event_type IS NOT NULL) AS waiting
FROM pg_stat_activity;
```

B. Top connection consumers
---------------------------

```
SELECT
    datname,
    usename,
    application_name,
    client_addr,
    state,
    count(*) AS connections
FROM pg_stat_activity
GROUP BY datname, usename, application_name, client_addr, state
ORDER BY connections DESC;
```

C. Blocked and blocking sessions
--------------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_application,
    blocked.client_addr AS blocked_client,
    blocked.state AS blocked_state,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_query_age,
    blocked.query AS blocked_query,

    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.application_name AS blocker_application,
    blocker.client_addr AS blocker_client,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_transaction_age,
    now() - blocker.query_start AS blocker_query_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
  ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
ORDER BY blocked_query_age DESC;
```

D. Idle transactions
--------------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS transaction_age,
    now() - state_change AS idle_age,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start ASC;
```

E. Lock details
---------------

```
SELECT
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    l.locktype,
    l.mode,
    l.granted,
    l.relation::regclass AS relation_name,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    now() - a.query_start AS query_age,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a
  ON a.pid = l.pid
ORDER BY l.granted, query_age DESC;
```

F. Waiting sessions only
------------------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_age,
    pg_blocking_pids(pid) AS blocking_pids,
    query
FROM pg_stat_activity
WHERE wait_event_type IS NOT NULL
ORDER BY query_age DESC;
```

* * *

15\. PgBouncer Diagnosis Query Pack
===================================

Connect to PgBouncer admin DB:

```
psql -h <pgbouncer-host> -p 6432 -U <admin-user> pgbouncer
```

Run:

```
SHOW POOLS;
```

Look for:

```
cl_active
cl_waiting
sv_active
sv_idle
sv_used
sv_tested
sv_login
maxwait
```

Then:

```
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
SHOW CONFIG;
```

Agent classification logic
--------------------------

| Symptom | Likely Root Cause |
| --- | --- |
| `cl_waiting > 0`, `sv_active = default_pool_size` | PgBouncer backend pool exhausted |
| Many clients in PgBouncer, few DB sessions | PgBouncer queueing before DB |
| DB `pg_stat_activity` has many active sessions | DB workload saturation |
| DB `pg_stat_activity` has many idle sessions | connection leak or session pooling pinning |
| `pg_blocking_pids()` returns blockers | database lock blocking |
| no DB blockers but PgBouncer waiters exist | pool exhaustion, not DB lock |
| many `idle in transaction` sessions | app transaction leak |
| one old transaction blocking many queries | lock chain caused by stale transaction |

* * *

16\. Agent Root-Cause Output Format
===================================

The agent should produce a structured result like this:

```
{
  "incident_type": "database_lock_blocking",
  "severity": "high",
  "summary": "One idle transaction is blocking 12 queries on table blocking_test.",
  "blocked_sessions": [
    {
      "pid": 12345,
      "user": "app_user",
      "application": "api-service",
      "client": "10.0.1.25",
      "wait_event_type": "Lock",
      "wait_event": "transactionid",
      "blocked_duration": "00:04:31",
      "query": "UPDATE blocking_test SET name = ..."
    }
  ],
  "blocking_sessions": [
    {
      "pid": 12340,
      "user": "app_user",
      "application": "worker-service",
      "client": "10.0.2.18",
      "state": "idle in transaction",
      "transaction_age": "00:17:22",
      "query": "UPDATE blocking_test SET name = ..."
    }
  ],
  "root_cause": "A transaction was opened, updated blocking_test.id = 1, and was left uncommitted.",
  "recommended_action": [
    "Ask application owner to commit or rollback the transaction.",
    "If business impact is high and blocker is safe to terminate, run SELECT pg_terminate_backend(12340).",
    "Add idle_in_transaction_session_timeout to prevent recurrence.",
    "Review application transaction handling."
  ]
}
```

* * *

17\. Simulated Solution Flow
============================

For your required test:

> “Once there is blocking, agent needs to find the root cause of the blocking and simulate the solution by creating blocking by opening a transaction and making other connections wait indefinitely.”

Use this exact flow.

Step 1: Create blocker
----------------------

Session 1:

```
BEGIN;

UPDATE blocking_test
SET name = 'root cause blocker',
    updated_at = now()
WHERE id = 1;

-- Keep session open indefinitely.
```

Step 2: Create multiple waiters
-------------------------------

Session 2:

```
UPDATE blocking_test
SET name = 'waiter 1'
WHERE id = 1;
```

Session 3:

```
UPDATE blocking_test
SET name = 'waiter 2'
WHERE id = 1;
```

Session 4:

```
SELECT *
FROM blocking_test
WHERE id = 1
FOR UPDATE;
```

Step 3: Agent detects blocking
------------------------------

Agent runs:

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.application_name AS blocked_app,
    blocked.client_addr AS blocked_client,
    blocked.wait_event_type,
    blocked.wait_event,
    now() - blocked.query_start AS blocked_for,
    blocked.query AS blocked_query,

    blocker.pid AS blocker_pid,
    blocker.application_name AS blocker_app,
    blocker.client_addr AS blocker_client,
    blocker.state AS blocker_state,
    now() - blocker.xact_start AS blocker_transaction_age,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocker
  ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
ORDER BY blocked_for DESC;
```

Step 4: Agent confirms root cause
---------------------------------

Expected root cause:

```
A transaction updated blocking_test.id = 1 and remained open.
Other sessions are waiting for the transaction to release the row lock.
The blocker is the session with the oldest xact_start and state either active or idle in transaction.
```

Step 5: Agent simulates safe remediation
----------------------------------------

Preferred safe remediation:

```
ROLLBACK;
```

from Session 1.

Then all waiting sessions continue or complete.

Emergency remediation:

```
SELECT pg_terminate_backend(<blocker_pid>);
```

This rolls back the blocker transaction and releases locks.

* * *

18\. Preventive Recommendations
===============================

For production, consider these controls:

```
ALTER DATABASE your_db
SET idle_in_transaction_session_timeout = '5min';
```

```
ALTER DATABASE your_db
SET lock_timeout = '30s';
```

```
ALTER DATABASE your_db
SET statement_timeout = '15min';
```

For PgBouncer:

```
pool_mode = transaction
default_pool_size = <safe backend connection count>
reserve_pool_size = <small burst capacity>
query_wait_timeout = 30
server_idle_timeout = 60
client_idle_timeout = 300
```

For the application:

*   Always `COMMIT` or `ROLLBACK` in `finally` blocks.
*   Close/release DB connections back to the pool.
*   Avoid long business logic inside DB transactions.
*   Add application name per service:

```
SET application_name = 'backup-worker';
```

or configure it in the connection string:

```
application_name=backup-worker
```

This makes root-cause analysis much easier in `pg_stat_activity`.

* * *

19\. Minimum Test Cases for Your Agent
======================================

I would start with these five test cases:

| Test Case | Setup | Agent Should Detect |
| --- | --- | --- |
| TC1 | One open transaction updates row, others update same row | row-level lock blocker |
| TC2 | Open transaction becomes `idle in transaction` | stale transaction root cause |
| TC3 | PgBouncer `default_pool_size = 2`, 2 long transactions, 3rd waits | PgBouncer pool exhaustion |
| TC4 | Direct DB connections exceed `max_connections` | Postgres connection exhaustion |
| TC5 | Many idle app connections | connection leak / poor pool release |

For your immediate simulation, TC1 + TC2 are the most important because they directly validate whether the agent can identify the blocker, root cause, and remediation.

## Prompt:
austion

Convert to writing block

## Response:
Edit

exhaustion



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)