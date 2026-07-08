# ChatGPT - Senthil

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:41:52  
**Link:** [https://chatgpt.com/share/e/6a27c186-0c88-8013-bd2e-47ad4ee015bb](https://chatgpt.com/share/e/6a27c186-0c88-8013-bd2e-47ad4ee015bb)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert. 

I need a complete investigation and simulation plan for the topic: 
"Connection Exhaustion, PgBouncer, RDS Postgres Environment" 

Create a complete guide for investigating, simulating, and resolving.
Include manual troubleshooting steps, analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices.

Please cover this in depth from both manual troubleshooting steps and agent-based/root-cause analysis automation perspectives. The goal is to identify, diagnose, reproduce, and resolve production issues.

Show moreShow less

## Response:
I’ll ground the guide in current PostgreSQL, AWS RDS, and PgBouncer behavior, then structure it as an operational runbook plus simulation and automation design.

Thought for 15s

Below is a production-grade investigation, simulation, and remediation guide for **Connection Exhaustion, PgBouncer, and RDS PostgreSQL**.

* * *

1\. Mental model: what “connection exhaustion” really means
===========================================================

In PostgreSQL, every server-side connection is a backend process. Too many connections consume memory, CPU, file descriptors, lock-table capacity, and scheduler time, even if many sessions are idle. On RDS PostgreSQL, this is especially important because raising `max_connections` too high can cause memory pressure or even startup failure if combined with heavy memory settings such as `shared_buffers`; AWS explicitly warns to be careful when changing `max_connections` and `shared_buffers`. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)

Connection exhaustion usually appears as one or more of these symptoms:

```
FATAL: sorry, too many clients already
FATAL: remaining connection slots are reserved for non-replication superuser connections
FATAL: too many connections for role
FATAL: too many connections for database
PgBouncer: no more connections allowed
PgBouncer: pooler error: server login failed
PgBouncer: client_login_timeout
Application: connection timeout / acquire timeout / pool timeout
RDS Proxy: connection borrow timeout
```

For RDS PostgreSQL, AWS calls out high connection and authentication pressure as a common production issue. Typical symptoms include slow connection establishment, CPU spikes correlated with connection churn, elevated connection counts, and errors such as `remaining connection slots are reserved`. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.InitialTroubleshooting.html)

PgBouncer and RDS Proxy solve related but not identical problems. PgBouncer multiplexes client connections into fewer PostgreSQL server connections. PgBouncer’s `pool_mode` controls when a server connection is released: `session`, `transaction`, or `statement`; transaction mode releases the server connection after the transaction completes, while session mode holds it until the client disconnects. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)pgbouncer.org](https://www.pgbouncer.org/config.html) RDS Proxy also performs connection pooling and transaction-level multiplexing, reducing the chance of “too many connections” errors by allowing many client connections to share fewer database connections. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html)

* * *

2\. Production architecture patterns
====================================

Pattern A: Application connects directly to RDS PostgreSQL
----------------------------------------------------------

```
Application pods / EC2 / Lambda
        |
        v
RDS PostgreSQL
```

This is simple but fragile under bursty traffic, bad application pool configuration, container autoscaling, or Lambda concurrency. Every application connection becomes a PostgreSQL backend connection.

Use this only when:

```
total_app_instances * max_pool_size + admin_reserved_connections < safe_db_connection_budget
```

Pattern B: Application-side pool only
-------------------------------------

```
Application pool
        |
        v
RDS PostgreSQL
```

This helps only if every application instance is carefully configured. It can still exhaust RDS if the number of instances grows.

Example failure:

```
50 pods * HikariCP maximumPoolSize 20 = 1000 possible DB connections
RDS usable connection budget = 450
Result: connection exhaustion during scale-out
```

Pattern C: PgBouncer in front of RDS
------------------------------------

```
Application
   |
   v
PgBouncer
   |
   v
RDS PostgreSQL
```

This is common for Kubernetes, ECS, EC2, and multi-service environments. PgBouncer client connections are cheaper than PostgreSQL backends, but PgBouncer must be sized correctly. Its `max_client_conn` controls client connections, while `default_pool_size` controls server connections per user/database pair. PgBouncer warns that file descriptor usage can exceed `max_client_conn`, with theoretical usage depending on pool size, database count, and user count. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)pgbouncer.org](https://www.pgbouncer.org/config.html)

Pattern D: RDS Proxy in front of RDS
------------------------------------

```
Application / Lambda / ECS / EKS
        |
        v
RDS Proxy
        |
        v
RDS PostgreSQL
```

This is AWS-managed and especially useful for Lambda or highly bursty AWS-native workloads. RDS Proxy has important knobs: `IdleClientTimeout`, `MaxConnectionsPercent`, `MaxIdleConnectionsPercent`, and `ConnectionBorrowTimeout`. AWS notes that `MaxConnectionsPercent` is a percentage of the database `max_connections`, and recommends headroom above recent peak usage because proxy internal capacity changes can otherwise increase borrow latency. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-connections.html)

* * *

3\. Incident severity classification
====================================

SEV-1: hard outage
------------------

Symptoms:

```
New application requests fail.
Cannot acquire DB connection.
RDS DatabaseConnections near limit.
PgBouncer pools saturated.
Admin login difficult or impossible.
```

Immediate goal:

```
Preserve admin access.
Stop connection growth.
Recover service safely.
Collect enough evidence before killing sessions.
```

SEV-2: degraded service
-----------------------

Symptoms:

```
High connection count.
High PgBouncer wait count.
Slow connection acquisition.
Increased p95/p99 latency.
Some requests fail.
```

Immediate goal:

```
Identify leaking clients, blocked transactions, pool saturation, or connection storms.
Apply throttling/remediation before full exhaustion.
```

SEV-3: risk / early warning
---------------------------

Symptoms:

```
Connection count trending upward.
Idle sessions accumulating.
Frequent authentication attempts.
Application pool close to configured limit.
PgBouncer average wait rising.
```

Immediate goal:

```
Prevent recurrence through pool tuning, alerts, and application fixes.
```

* * *

4\. First 10-minute production triage
=====================================

Step 1: Confirm whether exhaustion is at PostgreSQL, PgBouncer, RDS Proxy, or application pool
----------------------------------------------------------------------------------------------

Ask these questions:

```
Can clients connect to PgBouncer but not PostgreSQL?
Can PgBouncer connect to PostgreSQL?
Are PgBouncer clients waiting?
Are RDS DatabaseConnections near max_connections?
Are application pools timing out before PgBouncer?
Are RDS Proxy borrow latencies increasing?
```

Use this routing:

| Symptom | Likely layer |
| --- | --- |
| `FATAL: too many clients already` from PostgreSQL | RDS PostgreSQL limit hit |
| `remaining connection slots are reserved` | RDS PostgreSQL near effective usable limit |
| PgBouncer `cl_waiting > 0` | PgBouncer pool saturated |
| PgBouncer `max_client_conn` reached | PgBouncer client-side cap hit |
| Application pool acquire timeout but PgBouncer/RDS fine | App pool starvation or leak |
| RDS Proxy `DatabaseConnectionsBorrowLatency` rising | RDS Proxy pool saturation or pinning |

AWS recommends starting RDS PostgreSQL performance triage with `pg_stat_activity`, then checking CloudWatch and Performance Insights metrics such as CPU, connection count, IOPS, and freeable memory. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.InitialTroubleshooting.html) PostgreSQL’s own documentation also points DBAs to activity monitoring, cumulative statistics, OS metrics, and `EXPLAIN` for deeper query investigation. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/monitoring.html)

* * *

5\. Core manual investigation queries
=====================================

Run these from a privileged DBA session.

5.1 Current connection budget
-----------------------------

```
SELECT
    name,
    setting,
    unit,
    context
FROM pg_settings
WHERE name IN (
    'max_connections',
    'superuser_reserved_connections',
    'reserved_connections',
    'idle_in_transaction_session_timeout',
    'statement_timeout',
    'lock_timeout',
    'tcp_keepalives_idle',
    'tcp_keepalives_interval',
    'tcp_keepalives_count'
)
ORDER BY name;
```

On RDS, also check RDS-specific reserved connection behavior if available:

```
SHOW max_connections;
SHOW superuser_reserved_connections;
SHOW rds.rds_superuser_reserved_connections;
```

Not every version exposes every setting in the same way, so treat missing parameters as version/platform dependent.

5.2 Connection count by state
-----------------------------

```
SELECT
    state,
    COUNT(*) AS sessions
FROM pg_stat_activity
GROUP BY state
ORDER BY sessions DESC;
```

Common interpretation:

| State | Meaning | Risk |
| --- | --- | --- |
| `active` | Currently executing | Normal if query volume is high |
| `idle` | Connected but doing nothing | Pool too large or leak |
| `idle in transaction` | Transaction open but inactive | High risk: locks, vacuum blockage |
| `idle in transaction (aborted)` | Failed transaction left open | Application bug |
| null for background processes | System processes | Usually normal |

5.3 Connection count by user, database, app, and client
-------------------------------------------------------

```
SELECT
    usename,
    datname,
    application_name,
    client_addr,
    state,
    COUNT(*) AS sessions,
    MIN(backend_start) AS oldest_backend,
    MIN(xact_start) AS oldest_transaction,
    MIN(query_start) AS oldest_query
FROM pg_stat_activity
GROUP BY usename, datname, application_name, client_addr, state
ORDER BY sessions DESC, oldest_backend NULLS LAST;
```

This is the most important query for root cause classification. It answers:

```
Which service is consuming the connections?
Which app name?
Which client host?
Are sessions active, idle, or idle in transaction?
Did they start together?
```

5.4 Find long idle sessions
---------------------------

```
SELECT
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    state,
    now() - backend_start AS connection_age,
    now() - state_change AS idle_age,
    query
FROM pg_stat_activity
WHERE state = 'idle'
ORDER BY state_change ASC
LIMIT 50;
```

5.5 Find idle-in-transaction sessions
-------------------------------------

```
SELECT
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    now() - xact_start AS transaction_age,
    now() - state_change AS idle_in_txn_age,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%'
ORDER BY xact_start ASC;
```

These are dangerous because they can hold locks and prevent vacuum progress.

5.6 Find blocking chains
------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    blocked.application_name AS blocked_app,
    blocked.client_addr AS blocked_client,
    now() - blocked.query_start AS blocked_duration,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.application_name AS blocker_app,
    blocker.client_addr AS blocker_client,
    now() - blocker.xact_start AS blocker_xact_age,
    blocker.state AS blocker_state,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks
    ON blocked_locks.pid = blocked.pid
JOIN pg_locks blocker_locks
    ON blocker_locks.locktype = blocked_locks.locktype
   AND blocker_locks.database IS NOT DISTINCT FROM blocked_locks.database
   AND blocker_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
   AND blocker_locks.page IS NOT DISTINCT FROM blocked_locks.page
   AND blocker_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
   AND blocker_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
   AND blocker_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
   AND blocker_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
   AND blocker_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
   AND blocker_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
   AND blocker_locks.pid <> blocked_locks.pid
JOIN pg_stat_activity blocker
    ON blocker.pid = blocker_locks.pid
WHERE NOT blocked_locks.granted
  AND blocker_locks.granted
ORDER BY blocked_duration DESC;
```

5.7 Simpler blocker check using `pg_blocking_pids`
--------------------------------------------------

```
SELECT
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    now() - a.query_start AS query_age,
    pg_blocking_pids(a.pid) AS blocking_pids,
    a.query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY query_age DESC;
```

5.8 Check wait events
---------------------

```
SELECT
    wait_event_type,
    wait_event,
    state,
    COUNT(*) AS sessions
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event, state
ORDER BY sessions DESC;
```

AWS recommends using Performance Insights wait events to distinguish CPU, I/O, locking, client waits, and IPC/parallel query pressure. For example, lock waits indicate contention, and `Client:ClientRead` can indicate the database is waiting for the application. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.InitialTroubleshooting.html)

5.9 Check query age distribution
--------------------------------

```
SELECT
    CASE
        WHEN now() - query_start < interval '1 minute' THEN '<1m'
        WHEN now() - query_start < interval '5 minutes' THEN '1m-5m'
        WHEN now() - query_start < interval '30 minutes' THEN '5m-30m'
        WHEN now() - query_start < interval '2 hours' THEN '30m-2h'
        ELSE '>2h'
    END AS query_age_bucket,
    state,
    COUNT(*) AS sessions
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY 1, 2
ORDER BY 1, 2;
```

5.10 Check per-role and per-database connection limits
------------------------------------------------------

```
SELECT
    rolname,
    rolconnlimit
FROM pg_roles
WHERE rolconnlimit <> -1
ORDER BY rolname;
```

```
SELECT
    datname,
    datconnlimit
FROM pg_database
WHERE datconnlimit <> -1
ORDER BY datname;
```

A role-level or database-level limit can cause connection errors even when global `max_connections` still has headroom.

* * *

6\. PgBouncer investigation
===========================

Connect to the PgBouncer admin database:

```
psql -h <pgbouncer-host> -p 6432 -U <admin-user> pgbouncer
```

6.1 Show pools
--------------

```
SHOW POOLS;
```

Key fields to inspect:

| Field | Meaning |
| --- | --- |
| `cl_active` | Clients linked to server connections |
| `cl_waiting` | Clients waiting for server connection |
| `sv_active` | Server connections in use |
| `sv_idle` | Server connections idle and reusable |
| `sv_used` | Recently used server connections |
| `sv_tested` | Connections being tested |
| `sv_login` | Connections logging into PostgreSQL |
| `maxwait` | Longest client wait time |

Interpretation:

```
cl_waiting > 0 and sv_active near pool size
=> PgBouncer pool saturation.

sv_login high
=> PostgreSQL login slow, auth pressure, DNS/TLS/auth issue, or RDS under pressure.

cl_active high but RDS connections low
=> PgBouncer is multiplexing successfully.

cl_active high and RDS connections also high
=> pool sizes may be too large, or session mode is holding server connections.
```

6.2 Show clients
----------------

```
SHOW CLIENTS;
```

Look for:

```
Many clients from same host
Many clients stuck waiting
Old client connections
Unexpected application_name
```

6.3 Show servers
----------------

```
SHOW SERVERS;
```

Look for:

```
Server connections stuck active
Server connections in login state
Server connections tied to one database/user
Very old server connections
```

6.4 Show stats
--------------

```
SHOW STATS;
SHOW STATS_TOTALS;
SHOW STATS_AVERAGES;
```

Watch:

```
avg_query_count
avg_query_time
avg_wait_time
total_wait_time
total_xact_count
```

If `avg_wait_time` rises, PgBouncer is not just pooling; it has become a queue.

6.5 Show config
---------------

```
SHOW CONFIG;
```

Critical settings:

```
pool_mode
max_client_conn
default_pool_size
min_pool_size
reserve_pool_size
reserve_pool_timeout
max_db_connections
max_user_connections
server_idle_timeout
server_lifetime
server_login_retry
client_login_timeout
query_timeout
idle_transaction_timeout
```

6.6 PgBouncer pool sizing formula
---------------------------------

For PgBouncer, estimate maximum PostgreSQL server connections:

```
total_server_connections =
    sum over each active (database, user) pool:
        default_pool_size or configured pool_size
    + reserve_pool_size when activated
```

Do not confuse this with `max_client_conn`.

Example:

```
default_pool_size = 25
reserve_pool_size = 5
databases = 4
users = 3

Possible server connections = (25 + 5) * 4 * 3 = 360
```

If RDS safe budget is 300, this configuration can exhaust RDS even though PgBouncer exists.

PgBouncer’s default `default_pool_size` is 20, and it applies per user/database pair unless overridden. [![](https://www.google.com/s2/favicons?domain=https://www.pgbouncer.org&sz=128)pgbouncer.org](https://www.pgbouncer.org/config.html)

* * *

7\. RDS / CloudWatch / Performance Insights investigation
=========================================================

7.1 CloudWatch metrics
----------------------

Check these around incident time:

```
DatabaseConnections
CPUUtilization
FreeableMemory
ReadIOPS / WriteIOPS
ReadLatency / WriteLatency
DiskQueueDepth
NetworkReceiveThroughput / NetworkTransmitThroughput
FreeStorageSpace
SwapUsage
```

Interpretation:

| Metric pattern | Meaning |
| --- | --- |
| DatabaseConnections rising, CPU stable | idle leak or oversized pools |
| DatabaseConnections rising, CPU rising | connection storm or active query surge |
| DatabaseConnections flat, PgBouncer wait rising | PgBouncer pool too small or long transactions |
| CPU high, active connections high | query workload pressure |
| FreeableMemory falling as connections rise | per-backend memory pressure |
| Read latency high, sessions active | I/O-bound query pileup |
| Lock waits high | blocking chain caused connection pileup |

7.2 Performance Insights
------------------------

Inspect:

```
DB load by wait event
DB load by SQL
DB load by user
DB load by host
DB load by database
```

Useful interpretations:

| PI signal | Possible RCA |
| --- | --- |
| High `Client:ClientRead` | App opened connection but is not sending work |
| High lock waits | Blockers causing active sessions to pile up |
| High CPU | Query storm, bad plan, parallelism, missing index |
| High I/O waits | Slow queries consuming connections |
| High auth attempts | Connection churn without pooling |

AWS specifically mentions elevated auth attempts, slow connection establishment, connection errors, and CPU spikes as symptoms of high connection/authentication pressure. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.InitialTroubleshooting.html)

7.3 RDS logs
------------

Look for:

```
FATAL: too many connections
FATAL: remaining connection slots are reserved
FATAL: too many connections for role
FATAL: password authentication failed
could not receive data from client
unexpected EOF on client connection
terminating connection due to idle-in-transaction timeout
terminating connection due to administrator command
```

Enable useful logging carefully:

```
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u db=%d app=%a client=%h ';
```

On RDS, parameter changes may require parameter group updates and, for static parameters, a reboot. AWS distinguishes static parameters that require reboot from dynamic parameters that do not. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)

Use connection logging temporarily in high-volume production; it can create log noise and cost.

* * *

8\. Root-cause classification
=============================

RCA class 1: application connection leak
----------------------------------------

### Signature

```
Many idle sessions.
Same application_name/client_addr.
Connection age increases for hours.
No corresponding workload increase.
Application pool active count does not decrease.
```

### Queries

```
SELECT
    application_name,
    client_addr,
    usename,
    state,
    COUNT(*) AS sessions,
    MIN(backend_start) AS oldest_connection,
    MAX(state_change) AS latest_state_change
FROM pg_stat_activity
GROUP BY application_name, client_addr, usename, state
ORDER BY sessions DESC;
```

### Common causes

```
Connection not closed in finally block.
Async code path loses connection reference.
Exception path skips release.
ORM session leak.
Long-lived background worker opens one connection per task.
Health check opens DB connection every time.
```

### Fix

```
Patch application connection lifecycle.
Set application pool max lifetime.
Add leak detection.
Lower application pool max size.
Set app-level acquire timeout.
Use PgBouncer or RDS Proxy.
```

* * *

RCA class 2: oversized application pools
----------------------------------------

### Signature

```
Connection count equals pod_count * pool_size.
Mostly idle.
Incident occurs after autoscaling or deployment.
No single slow SQL dominates.
```

### Formula

```
max_possible_connections =
    number_of_instances * max_pool_size_per_instance
```

Example:

```
80 pods * pool size 10 = 800 DB connections
RDS usable budget = 400
Result: guaranteed exhaustion during scale-up
```

### Fix

```
Reduce per-instance pool size.
Use PgBouncer/RDS Proxy.
Add connection budget guardrail in deployment.
Autoscaling should account for DB capacity.
```

* * *

RCA class 3: connection storm / authentication pressure
-------------------------------------------------------

### Signature

```
High connection attempts.
CPU spikes.
Many short-lived sessions.
RDS logs show frequent connect/disconnect.
PgBouncer sv_login high.
Application startup, retry storm, Lambda burst, or deployment event.
```

### Fix

```
Use pooling.
Add exponential backoff with jitter.
Prevent all pods from starting simultaneously.
Warm pools gradually.
Limit Lambda concurrency.
Use RDS Proxy for Lambda-heavy workloads.
```

RDS Proxy is designed to reduce the overhead of opening and closing connections, including TLS/SSL handshaking and authentication, and to allow many client connections to use fewer database connections. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html)

* * *

RCA class 4: idle-in-transaction leak
-------------------------------------

### Signature

```
Sessions in idle in transaction.
Old xact_start.
Locks held.
Vacuum blocked.
Other sessions pile up behind locks.
```

### Query

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - xact_start AS xact_age,
    wait_event_type,
    wait_event,
    query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%'
ORDER BY xact_start;
```

### Fix

```
Terminate specific offenders.
Set idle_in_transaction_session_timeout.
Fix application transaction handling.
Ensure COMMIT/ROLLBACK in finally/defer block.
Avoid interactive transactions in application code.
```

Safe timeout:

```
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '60s';
```

For OLTP systems, a value between 30 seconds and 5 minutes is usually reasonable depending on workload.

* * *

RCA class 5: long-running queries consuming pool slots
------------------------------------------------------

### Signature

```
Active sessions high.
Same query pattern repeated.
PgBouncer cl_waiting rises.
RDS CPU/IO high.
Query durations high.
```

### Query

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY query_start ASC
LIMIT 30;
```

### Fix

```
Cancel or terminate worst offenders.
Add/repair indexes.
Optimize query plan.
Add statement_timeout.
Separate OLTP and reporting workloads.
Route reporting to replica.
```

Prefer:

```
SELECT pg_cancel_backend(<pid>);
```

Before:

```
SELECT pg_terminate_backend(<pid>);
```

* * *

RCA class 6: lock contention causing connection pileup
------------------------------------------------------

### Signature

```
Many active sessions waiting on Lock.
One old transaction blocks many sessions.
Connection count rises because requests wait instead of completing.
```

### Fix

```
Identify blocker.
Cancel/terminate blocker if safe.
Fix transaction order.
Reduce transaction duration.
Add lock_timeout.
Move DDL out of peak hours.
```

Recommended role-level guardrail:

```
ALTER ROLE app_user SET lock_timeout = '5s';
ALTER ROLE app_user SET statement_timeout = '60s';
```

Tune these carefully per workload.

* * *

RCA class 7: PgBouncer misconfiguration
---------------------------------------

### Signature

```
PgBouncer exists but RDS still exhausts.
default_pool_size * users * databases exceeds RDS budget.
pool_mode=session for web workload.
Prepared statement/session features incompatible with transaction pooling.
cl_waiting high.
max_client_conn too low.
```

### Fix

```
Use transaction pooling for stateless OLTP.
Lower default_pool_size.
Set per-database/user pool_size.
Set max_db_connections.
Set max_user_connections.
Configure reserve_pool_size carefully.
Fix application session-state assumptions.
```

Example safer PgBouncer config:

```
[pgbouncer]
pool_mode = transaction
max_client_conn = 5000
default_pool_size = 50
reserve_pool_size = 10
reserve_pool_timeout = 3
max_db_connections = 250
server_idle_timeout = 300
server_lifetime = 3600
client_login_timeout = 10
idle_transaction_timeout = 60
query_timeout = 120
```

But do not copy these values blindly. Size from your RDS connection budget.

* * *

RCA class 8: PgBouncer transaction pooling incompatibility
----------------------------------------------------------

### Signature

```
Errors after moving from session to transaction mode.
Prepared statements fail.
Temporary tables disappear unexpectedly.
SET LOCAL works but session SET does not persist as expected.
LISTEN/NOTIFY behavior unexpected.
Advisory locks behave incorrectly.
```

### Common incompatible patterns

```
Server-side prepared statements
Session-level SET
Temporary tables across transactions
Session advisory locks
Cursors across transaction boundaries
LISTEN/NOTIFY long sessions
ORM session assumptions
```

### Fix options

```
Use session pooling for incompatible services.
Disable server-side prepared statements in driver.
Move session settings into transaction scope.
Split workloads: OLTP via transaction pool, special jobs via session pool.
```

* * *

RCA class 9: RDS Proxy pinning / borrow latency
-----------------------------------------------

### Signature

```
Application connects to RDS Proxy.
Client connections high.
Database connections also high.
Borrow latency increases.
Proxy multiplexing less effective.
```

RDS Proxy calls this fallback behavior **pinning**, where a session stays on the same database connection until the session ends because the proxy cannot safely reuse it outside that session. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html)

### Fix

```
Check proxy logs for pinning.
Avoid session state.
Avoid long transactions.
Tune app pool max lifetime below RDS Proxy 24-hour max client connection life.
Tune IdleClientTimeout and ConnectionBorrowTimeout.
Increase MaxConnectionsPercent only with headroom.
```

AWS notes that client connections pinned but idle in the application-side pool can continue holding database connections and reduce multiplexing efficiency. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-connections.html)

* * *

9\. Safe remediation playbook
=============================

9.1 First priority: preserve DBA access
---------------------------------------

Before a full outage happens, create a dedicated DBA role and reserve operational access.

```
CREATE ROLE dba_breakglass LOGIN PASSWORD '<stored-in-secrets-manager>';
GRANT rds_superuser TO dba_breakglass;
ALTER ROLE dba_breakglass CONNECTION LIMIT 3;
```

Keep this role out of application pools.

9.2 Stop the bleeding
---------------------

Depending on source:

```
Scale down offending application deployment.
Disable noisy worker/cron.
Reduce Kubernetes HPA max replicas.
Pause queue consumers.
Throttle API ingress.
Reduce Lambda reserved concurrency.
Temporarily block offending client IP/security group if necessary.
```

This is often safer than killing sessions repeatedly.

9.3 Kill only clearly safe sessions
-----------------------------------

### Kill old idle sessions from a known app

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'app_user'
  AND application_name = 'bad-service'
  AND state = 'idle'
  AND now() - state_change > interval '30 minutes';
```

### Kill idle-in-transaction sessions older than 10 minutes

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'app_user'
  AND state LIKE 'idle in transaction%'
  AND now() - xact_start > interval '10 minutes';
```

### Cancel long-running active queries first

```
SELECT pg_cancel_backend(pid)
FROM pg_stat_activity
WHERE usename = 'app_user'
  AND state = 'active'
  AND now() - query_start > interval '5 minutes';
```

Escalate to terminate only if cancellation fails and business impact justifies it.

9.4 PgBouncer emergency commands
--------------------------------

From PgBouncer admin console:

```
SHOW POOLS;
PAUSE <database>;
RESUME <database>;
RELOAD;
KILL <database>;
```

Use carefully:

| Command | Effect |
| --- | --- |
| `PAUSE` | Stop assigning new server connections; waits for in-flight work |
| `RESUME` | Resume processing |
| `RELOAD` | Reload config |
| `KILL` | Disconnect clients/servers for database; disruptive |

9.5 Temporary parameter changes
-------------------------------

Safe dynamic mitigations:

```
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_user SET statement_timeout = '120s';
ALTER ROLE app_user SET lock_timeout = '5s';
```

Avoid emergency `max_connections` increases unless you have memory headroom and understand reboot implications. AWS explicitly warns that overly high `max_connections`/`shared_buffers` settings can prevent the RDS PostgreSQL instance from starting. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.Parameters.html)

9.6 When to reboot RDS
----------------------

Reboot is last resort.

Consider reboot only when:

```
Cannot connect even with breakglass role.
Connection storm source has been stopped.
Session state is unrecoverable.
AWS console/API shows DB available but inaccessible.
You understand failover impact.
```

Do not reboot while offending apps are still retrying aggressively; they may reconnect immediately and recreate the incident.

* * *

10\. Reproducible simulation scenarios
======================================

Run simulations in isolated staging, not production.

10.1 Local Docker lab
---------------------

### `docker-compose.yml`

```
version: "3.8"

services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: appdb
    command:
      - "postgres"
      - "-c"
      - "max_connections=50"
      - "-c"
      - "log_connections=on"
      - "-c"
      - "log_disconnections=on"
    ports:
      - "5432:5432"

  pgbouncer:
    image: edoburu/pgbouncer
    environment:
      DB_HOST: postgres
      DB_USER: app
      DB_PASSWORD: app
      DB_NAME: appdb
      POOL_MODE: transaction
      MAX_CLIENT_CONN: 500
      DEFAULT_POOL_SIZE: 10
      ADMIN_USERS: app
    ports:
      - "6432:5432"
    depends_on:
      - postgres
```

Start:

```
docker compose up -d
```

* * *

10.2 Scenario A: direct PostgreSQL connection exhaustion
--------------------------------------------------------

### Goal

Prove that direct connections hit `max_connections`.

### Python script

```
import psycopg2
import time

connections = []

for i in range(100):
    try:
        conn = psycopg2.connect(
            host="localhost",
            port=5432,
            dbname="appdb",
            user="app",
            password="app",
            application_name=f"direct-exhaustion-{i}"
        )
        connections.append(conn)
        print(f"opened {i+1}")
    except Exception as e:
        print(f"failed at {i+1}: {e}")
        break

time.sleep(600)
```

### Expected

```
PostgreSQL rejects new connections near max_connections.
pg_stat_activity shows many idle sessions.
```

### Validate

```
SELECT state, COUNT(*)
FROM pg_stat_activity
GROUP BY state;
```

* * *

10.3 Scenario B: PgBouncer absorbs many idle clients
----------------------------------------------------

### Goal

Show many client connections can map to fewer server connections.

Change script port to `6432`.

```
conn = psycopg2.connect(
    host="localhost",
    port=6432,
    dbname="appdb",
    user="app",
    password="app",
    application_name=f"pgbouncer-client-{i}"
)
```

### Validate in PgBouncer

```
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
```

### Expected

```
PgBouncer accepts many clients.
PostgreSQL server connections stay near default_pool_size.
```

* * *

10.4 Scenario C: PgBouncer pool saturation
------------------------------------------

### Goal

Create more active concurrent queries than PgBouncer server pool allows.

```
import psycopg2
import threading
import time

def worker(i):
    conn = psycopg2.connect(
        host="localhost",
        port=6432,
        dbname="appdb",
        user="app",
        password="app",
        application_name=f"pool-saturation-{i}"
    )
    cur = conn.cursor()
    cur.execute("SELECT pg_sleep(30);")
    cur.close()
    conn.close()

threads = []
for i in range(100):
    t = threading.Thread(target=worker, args=(i,))
    t.start()
    threads.append(t)

for t in threads:
    t.join()
```

### Expected

```
PgBouncer cl_waiting > 0.
RDS/Postgres connections limited by default_pool_size.
Application latency increases instead of DB exhaustion.
```

* * *

10.5 Scenario D: idle-in-transaction leak
-----------------------------------------

### Script

```
import psycopg2
import time

conn = psycopg2.connect(
    host="localhost",
    port=5432,
    dbname="appdb",
    user="app",
    password="app",
    application_name="idle-in-txn-simulation"
)
cur = conn.cursor()
cur.execute("BEGIN;")
cur.execute("SELECT 1;")
print("transaction left open")
time.sleep(600)
```

### Validate

```
SELECT pid, state, now() - xact_start AS xact_age, query
FROM pg_stat_activity
WHERE application_name = 'idle-in-txn-simulation';
```

### Expected

```
state = idle in transaction
```

* * *

10.6 Scenario E: lock contention pileup
---------------------------------------

### Session 1

```
CREATE TABLE IF NOT EXISTS lock_test(id int primary key, value text);
INSERT INTO lock_test VALUES (1, 'a')
ON CONFLICT (id) DO UPDATE SET value = excluded.value;

BEGIN;
UPDATE lock_test SET value = 'blocker' WHERE id = 1;
-- Do not commit.
```

### Session 2+

```
UPDATE lock_test SET value = 'blocked' WHERE id = 1;
```

### Validate

```
SELECT
    pid,
    wait_event_type,
    wait_event,
    pg_blocking_pids(pid),
    query
FROM pg_stat_activity
WHERE datname = current_database();
```

### Expected

```
Blocked sessions accumulate.
Connection pool slots remain occupied.
```

* * *

10.7 Scenario F: application pool multiplication
------------------------------------------------

### Goal

Simulate Kubernetes/ECS scale-out risk.

Run 20 processes, each with pool size 10, against direct PostgreSQL.

Expected:

```
20 * 10 = 200 possible connections.
If max_connections = 50, failure is guaranteed.
```

This scenario is useful for validating deployment guardrails.

* * *

10.8 Scenario G: PgBouncer session mode failure
-----------------------------------------------

Set:

```
pool_mode = session
default_pool_size = 10
```

Open 100 long-lived idle client connections.

Expected:

```
PgBouncer server connections are held for client session lifetime.
Multiplexing benefit is much lower.
cl_waiting may rise.
RDS connections can still exhaust.
```

This shows why transaction pooling is preferred for stateless web workloads, while session pooling is reserved for workloads that require session state.

* * *

11\. Agent-based RCA automation workflow
========================================

You can build an RCA agent that collects evidence, classifies the incident, recommends safe actions, and optionally executes approved remediation.

11.1 Agent architecture
-----------------------

```
Trigger
  |
  v
Metric Collector Agent
  |
  v
DB Snapshot Agent
  |
  v
PgBouncer Snapshot Agent
  |
  v
Log / PI / CloudWatch Agent
  |
  v
RCA Classifier Agent
  |
  v
Remediation Planner Agent
  |
  v
Human Approval Gate
  |
  v
Safe Executor Agent
  |
  v
Post-Remediation Verifier
```

11.2 Trigger conditions
-----------------------

Trigger an investigation when any condition is true:

```
RDS DatabaseConnections > 80% of usable budget for 5 minutes
PgBouncer cl_waiting > 0 for 2 minutes
PgBouncer maxwait > 5 seconds
Application DB acquire timeout rate > threshold
RDS Proxy DatabaseConnectionsBorrowLatency above baseline
FATAL too many connections found in RDS logs
Idle-in-transaction sessions older than threshold
```

11.3 Evidence collection contract
---------------------------------

The agent should collect a single timestamped evidence bundle:

```
{
  "incident_id": "conn-exhaust-2026-06-09-001",
  "db_instance": "prod-db-1",
  "timestamp_utc": "...",
  "rds_metrics": {},
  "performance_insights": {},
  "pg_stat_activity_summary": {},
  "pg_stat_activity_top_groups": [],
  "idle_in_transaction_sessions": [],
  "long_running_queries": [],
  "blocking_chains": [],
  "pgbouncer_pools": [],
  "pgbouncer_clients_summary": [],
  "pgbouncer_servers_summary": [],
  "application_deployments": [],
  "recent_changes": [],
  "logs": []
}
```

11.4 DB Snapshot Agent SQL set
------------------------------

Use read-only queries first.

```
-- connection budget
SELECT name, setting, unit, context
FROM pg_settings
WHERE name IN (
  'max_connections',
  'superuser_reserved_connections',
  'idle_in_transaction_session_timeout',
  'statement_timeout',
  'lock_timeout'
);

-- state summary
SELECT state, COUNT(*) AS sessions
FROM pg_stat_activity
GROUP BY state;

-- top connection owners
SELECT
  usename,
  datname,
  application_name,
  client_addr,
  state,
  COUNT(*) AS sessions,
  MIN(backend_start) AS oldest_backend,
  MIN(xact_start) AS oldest_xact
FROM pg_stat_activity
GROUP BY usename, datname, application_name, client_addr, state
ORDER BY sessions DESC
LIMIT 30;

-- idle-in-transaction
SELECT
  pid,
  usename,
  datname,
  application_name,
  client_addr,
  now() - xact_start AS xact_age,
  query
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%'
ORDER BY xact_start
LIMIT 50;

-- long active queries
SELECT
  pid,
  usename,
  datname,
  application_name,
  client_addr,
  now() - query_start AS query_age,
  wait_event_type,
  wait_event,
  left(query, 2000) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY query_start
LIMIT 50;

-- blockers
SELECT
  pid,
  usename,
  application_name,
  client_addr,
  now() - query_start AS query_age,
  pg_blocking_pids(pid) AS blocking_pids,
  left(query, 2000) AS query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
ORDER BY query_age DESC;
```

11.5 PgBouncer Snapshot Agent commands
--------------------------------------

```
SHOW VERSION;
SHOW CONFIG;
SHOW DATABASES;
SHOW USERS;
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
SHOW STATS_TOTALS;
```

The agent should summarize, not dump everything into the RCA.

11.6 RCA classifier rules
-------------------------

### Rule 1: application leak

```
IF idle sessions from one application/client exceed 40% of total connections
AND oldest connection age > 1 hour
AND workload metrics do not show matching request volume
THEN classify as APPLICATION_CONNECTION_LEAK.
```

### Rule 2: oversized pool

```
IF total connections approximate app_instance_count * configured_pool_size
AND most sessions are idle
AND incident correlates with deployment/autoscaling
THEN classify as OVERSIZED_APPLICATION_POOLS.
```

### Rule 3: idle-in-transaction leak

```
IF idle-in-transaction sessions > threshold
OR oldest idle-in-transaction age > threshold
THEN classify as IDLE_IN_TRANSACTION_LEAK.
```

### Rule 4: lock pileup

```
IF many active sessions have blocking_pids
AND one/few blockers are old
THEN classify as LOCK_CONTENTION_CONNECTION_PILEUP.
```

### Rule 5: slow query saturation

```
IF active sessions high
AND top SQL/wait events indicate CPU/IO pressure
AND PgBouncer cl_waiting > 0
THEN classify as LONG_QUERY_POOL_SATURATION.
```

### Rule 6: PgBouncer pool too small

```
IF PgBouncer cl_waiting > 0
AND RDS DatabaseConnections has headroom
AND sv_active equals configured pool limit
THEN classify as PGBOUNCER_POOL_UNDERSIZED.
```

### Rule 7: PgBouncer pool too large

```
IF RDS DatabaseConnections near max
AND PgBouncer server connections across pools approach RDS budget
AND cl_waiting is low
THEN classify as PGBOUNCER_POOL_OVERSIZED.
```

### Rule 8: session mode issue

```
IF pool_mode=session
AND many idle clients hold server connections
THEN classify as PGBOUNCER_SESSION_POOL_HOLDING_CONNECTIONS.
```

### Rule 9: connection storm

```
IF connection attempts/log_connections spike
AND session duration is short
AND CPU/auth metrics rise
THEN classify as CONNECTION_STORM.
```

### Rule 10: RDS Proxy pinning

```
IF using RDS Proxy
AND database connections are high despite client pooling
AND borrow latency increases
AND proxy logs show pinning
THEN classify as RDS_PROXY_PINNING.
```

11.7 RCA output format
----------------------

The agent should produce:

```
Incident summary
Current impact
Primary RCA classification
Confidence score
Evidence
Immediate safe actions
Risky actions to avoid
Long-term fixes
Validation queries
Prevention tasks
```

Example:

```
Primary RCA: OVERSIZED_APPLICATION_POOLS
Confidence: High

Evidence:
- 620 sessions from app_user / checkout-service.
- 91% are idle.
- Deployment scaled from 20 to 80 pods at 10:04 UTC.
- Hikari maximumPoolSize = 10.
- Expected possible DB sessions = 800.
- RDS usable budget ≈ 500.

Immediate action:
- Reduce checkout-service replicas to 30.
- Reduce maximumPoolSize from 10 to 3.
- Route service through PgBouncer transaction pool.

Do not:
- Increase max_connections before memory review.
- Reboot DB while pods are retrying.
```

* * *

12\. Automated safe remediation design
======================================

12.1 Action safety levels
-------------------------

### Level 0: read-only

```
Collect metrics.
Run SELECT queries.
Read PgBouncer stats.
Read logs.
Classify RCA.
```

No approval needed.

### Level 1: low-risk config or throttling

```
Scale down non-critical workers.
Pause queue consumers.
Reduce Lambda concurrency.
Reload PgBouncer after reviewed config change.
```

Require approval.

### Level 2: targeted DB session action

```
Cancel long query.
Terminate idle session.
Terminate idle-in-transaction session.
```

Require approval and strict filters.

### Level 3: high-risk

```
Mass terminate sessions.
Change max_connections.
Reboot RDS.
Failover.
Kill PgBouncer database.
```

Require senior DBA approval.

12.2 Guardrails for automated termination
-----------------------------------------

Only allow termination when all are true:

```
Session belongs to application role, not DBA/admin.
Session is not the current agent session.
Session is not replication/autovacuum/system.
Session matches approved app/user/client filter.
Session age exceeds threshold.
SQL pattern is not allowlisted critical operation.
Current incident severity justifies action.
```

Example safe generated SQL:

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND usename = 'app_user'
  AND application_name = 'checkout-service'
  AND state = 'idle'
  AND now() - state_change > interval '30 minutes';
```

Avoid agent-generated SQL like:

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity;
```

* * *

13\. Capacity planning
======================

13.1 Define safe PostgreSQL connection budget
---------------------------------------------

Do not allocate all `max_connections` to applications.

```
safe_app_connection_budget =
    max_connections
  - reserved_superuser_connections
  - rds_reserved_connections
  - monitoring_connections
  - migration/admin_connections
  - replication/logical slots/users
  - emergency_headroom
```

Example:

```
max_connections = 500
reserved/admin/monitoring/headroom = 80
safe_app_connection_budget = 420
```

13.2 App pool budget
--------------------

```
sum(service_instance_count * pool_size) <= safe_app_connection_budget
```

Example:

| Service | Max instances | Pool size | Possible connections |
| --- | --- | --- | --- |
| API | 40 | 5 | 200 |
| Worker | 20 | 4 | 80 |
| Admin | 5 | 2 | 10 |
| Reporting | 5 | 5 | 25 |
| Total |  |  | 315 |

If safe budget is 420, this has 105 headroom.

13.3 PgBouncer budget
---------------------

```
sum((pool_size + reserve_pool_size) per active user/db pair)
    <= safe_app_connection_budget
```

Prefer explicit per-database configuration:

```
[databases]
appdb = host=my-rds.xxxxxx.us-east-1.rds.amazonaws.com port=5432 dbname=appdb pool_size=80 reserve_pool=10
reporting = host=my-rds.xxxxxx.us-east-1.rds.amazonaws.com port=5432 dbname=reporting pool_size=20 reserve_pool=5
```

Then cap:

```
max_db_connections = 250
max_user_connections = 200
```

13.4 RDS Proxy budget
---------------------

For RDS Proxy, `MaxConnectionsPercent` is based on the DB instance `max_connections`; AWS recommends setting it with sufficient headroom above recent monitored usage and notes that internal reserved connections are not included in `MaxDatabaseConnectionsAllowed`. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy-connections.html)

Example:

```
RDS max_connections = 1000
MaxConnectionsPercent = 70
Proxy theoretical cap = 700
But monitor MaxDatabaseConnectionsAllowed for actual usable proxy limit.
```

* * *

14\. Preventive best practices
==============================

14.1 Application best practices
-------------------------------

Use:

```
Small bounded pools.
Connection acquire timeout.
Connection max lifetime.
Idle timeout.
Leak detection.
Exponential backoff with jitter.
Clear application_name per service.
Readiness checks that do not open excessive DB sessions.
```

Avoid:

```
One connection per request.
Unbounded pools.
Infinite retry loops.
Long interactive transactions.
Holding DB connection while calling external APIs.
Opening DB connections in health checks at high frequency.
```

14.2 PostgreSQL/RDS best practices
----------------------------------

Set per-role guardrails:

```
ALTER ROLE app_user SET statement_timeout = '60s';
ALTER ROLE app_user SET lock_timeout = '5s';
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '60s';
```

Set connection limits where appropriate:

```
ALTER ROLE app_user CONNECTION LIMIT 300;
ALTER DATABASE appdb CONNECTION LIMIT 350;
```

Use `application_name`:

```
checkout-api
billing-worker
restore-service
migration-job
support-tool
```

This makes incident RCA much faster.

14.3 PgBouncer best practices
-----------------------------

For stateless OLTP services:

```
pool_mode = transaction
default_pool_size = <derived from budget>
reserve_pool_size = <small burst allowance>
reserve_pool_timeout = 2-5
max_db_connections = <hard RDS safety cap>
server_idle_timeout = 300
server_lifetime = 3600
idle_transaction_timeout = 60
```

Use session pooling only for workloads that need session state.

Separate pools:

```
oltp transaction pool
reporting pool
migration/admin session pool
```

Do not allow one reporting workload to starve OLTP.

14.4 Monitoring and alerts
--------------------------

Minimum alerts:

| Alert | Suggested threshold |
| --- | --- |
| RDS DatabaseConnections | \>75% warning, >85% critical |
| PgBouncer `cl_waiting` | \>0 for 2–5 min |
| PgBouncer `maxwait` | \>5s warning |
| Idle-in-transaction count | \>0 older than 5–10 min |
| Long active queries | \>N older than threshold |
| App pool acquire timeout | any sustained rate |
| RDS Proxy borrow latency | above baseline |
| Connection attempts | sudden spike |
| FreeableMemory | falling with connection rise |

14.5 Deployment guardrails
--------------------------

Before deploying or autoscaling:

```
new_max_connections =
    desired_replicas * app_pool_size

Reject deployment if:
    total_possible_connections > safe_budget
```

For Kubernetes, make this a CI/CD or admission-controller check.

14.6 Runbook readiness
----------------------

Keep these ready:

```
Breakglass DBA user.
Known-safe session termination SQL.
PgBouncer admin credentials.
RDS Proxy metrics dashboard.
CloudWatch dashboard.
Performance Insights access.
Application pool configuration inventory.
Service-to-DB-user mapping.
Emergency scale-down commands.
```

* * *

15\. Production checklist
=========================

During incident
---------------

```
1. Confirm failing layer: app pool, PgBouncer, RDS Proxy, or PostgreSQL.
2. Capture pg_stat_activity summary.
3. Capture PgBouncer SHOW POOLS / CLIENTS / SERVERS.
4. Check RDS DatabaseConnections, CPU, FreeableMemory, PI waits.
5. Identify top connection owner.
6. Classify RCA.
7. Stop new connection growth.
8. Kill/cancel only safe targeted sessions.
9. Verify connection count drops.
10. Keep evidence for postmortem.
```

After recovery
--------------

```
1. Document timeline.
2. Record peak connections and usable budget.
3. Identify exact service/user/client/query.
4. Fix application pool/leak/query/transaction issue.
5. Add timeout guardrails.
6. Tune PgBouncer/RDS Proxy.
7. Add alerts.
8. Add simulation case to staging.
9. Add deployment capacity check.
```

* * *

16\. Final recommended operating model
======================================

For a production RDS PostgreSQL environment:

```
1. Do not rely on max_connections as capacity.
2. Treat connections as a scarce resource.
3. Put PgBouncer or RDS Proxy in front of bursty applications.
4. Keep application pools small.
5. Use transaction pooling for stateless OLTP.
6. Keep session pooling only for session-state workloads.
7. Set statement, lock, and idle-in-transaction timeouts.
8. Monitor PgBouncer waiting clients, not just RDS connections.
9. Classify incidents using evidence, not assumptions.
10. Automate read-only RCA first; automate remediation only behind guardrails.
```

The most common real-world root cause is not “RDS needs more connections.” It is usually one of these:

```
Application pool too large.
Application connection leak.
Idle-in-transaction leak.
Connection storm after deployment/autoscaling.
Long queries or locks causing pool slots to pile up.
PgBouncer pool sizing mistake.
PgBouncer transaction/session mode mismatch.
RDS Proxy pinning or borrow saturation.
```

The safest fix is usually:

```
Reduce connection demand.
Pool correctly.
Terminate only known-bad sessions.
Add timeouts.
Fix the application lifecycle.
Add capacity guardrails.
```

Raising `max_connections` should be the exception, not the default response.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)