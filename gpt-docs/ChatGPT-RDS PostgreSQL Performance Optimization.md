# RDS PostgreSQL Performance Optimization

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:18  
**Link:** [https://chatgpt.com/share/e/6a4c96e0-4920-83ee-8a02-96fa08f9a4ab](https://chatgpt.com/share/e/6a4c96e0-4920-83ee-8a02-96fa08f9a4ab)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert. 

I need a complete investigation and simulation plan for the topic: 
"RDS Postgres Environment - Slow Queries, Performance Optimization, Query Optimization, Performance tuning" 

Create a complete guide for investigating, simulating, and resolving. Include manual troubleshooting steps, analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices. 

Please cover this in depth from both manual troubleshooting steps and agent-based/root-cause analysis automation perspectives. The goal is to identify, diagnose, reproduce, and resolve production issues.

Show moreShow less

## Response:
I’ll structure this as a production-ready runbook: investigation flow, diagnostic SQL, AWS/RDS signals, simulation labs, RCA automation workflow, remediation, and prevention. I’ll also verify current RDS/PostgreSQL observability references so the guide aligns with AWS-managed PostgreSQL practices.

Thought for 13s

Below is a complete production-support guide for **RDS PostgreSQL slow queries, query optimization, performance tuning, and RCA automation**.

AWS now positions **CloudWatch Database Insights** as the primary fleet-level database performance tool for RDS/Aurora troubleshooting, while RDS metrics continue to flow into CloudWatch. AWS documentation also notes that after **July 31, 2026**, only **Advanced mode of Database Insights** supports execution plans and on-demand analysis, so new observability designs should prefer Database Insights over relying only on the older Performance Insights console. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.html?utm_source=chatgpt.com)

* * *

1\. Objective
=============

The goal of this runbook is to help a DBA or production support agent:

1.  Detect slow queries.
2.  Identify whether the issue is query, index, schema, statistics, lock, I/O, CPU, memory, connection, or application driven.
3.  Reproduce slow-query scenarios safely.
4.  Analyze execution plans.
5.  Apply safe remediation.
6.  Build preventive monitoring and RCA automation.

* * *

2\. High-Level Investigation Flow
=================================

Production Slow Query RCA Flow
------------------------------

```
User/API latency reported
        |
        v
Check RDS health: CPU, memory, IOPS, storage, connections
        |
        v
Check DB load by waits / SQL / user / host
        |
        v
Find top SQL by total time, mean time, calls, rows, reads, temp usage
        |
        v
Classify issue:
  - bad plan
  - missing index
  - stale statistics
  - table/index bloat
  - lock wait
  - I/O bottleneck
  - CPU-heavy query
  - temp file spill
  - connection saturation
  - inefficient application pattern
        |
        v
Capture EXPLAIN plan safely
        |
        v
Test fix in lower environment / read replica / production clone
        |
        v
Apply safe remediation
        |
        v
Monitor regression
```

* * *

3\. Observability Setup for RDS PostgreSQL
==========================================

3.1 Required PostgreSQL Extensions
----------------------------------

Enable these where supported:

```
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

`pg_stat_statements` tracks planning and execution statistics for SQL statements. PostgreSQL documentation states that it must be loaded through `shared_preload_libraries`, which requires a restart when adding or removing it. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/pgstatstatements.html?utm_source=chatgpt.com)

For RDS PostgreSQL, AWS says PostgreSQL 11+ compatible RDS instances load `pg_stat_statements` by default, while older versions need manual enablement in `shared_preload_libraries`. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PerfInsights.UsingDashboard.AnalyzeDBLoad.AdditionalMetrics.PostgreSQL.html?utm_source=chatgpt.com)

Recommended parameter group settings:

```
shared_preload_libraries = 'pg_stat_statements,auto_explain'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_io_timing = on
track_activity_query_size = 4096
log_min_duration_statement = 1000
log_lock_waits = on
deadlock_timeout = 1s
```

Use caution with `auto_explain` in production. It is powerful, but verbose logging can increase log volume.

* * *

3.2 RDS / AWS Monitoring Sources
--------------------------------

Use these layers together:

| Layer | Tool | Purpose |
| --- | --- | --- |
| RDS infrastructure | CloudWatch Metrics | CPU, memory, IOPS, connections, storage, replica lag |
| OS-level visibility | Enhanced Monitoring | Process list, CPU split, memory, disk I/O at OS level |
| DB load analysis | CloudWatch Database Insights / Performance Insights | Top SQL, waits, sessions, DB load |
| Query history | `pg_stat_statements` | Top queries by total time, mean time, calls, block reads, temp writes |
| Live sessions | `pg_stat_activity` | Current running queries, wait events, blockers |
| Locks | `pg_locks` | Blocking and lock contention |
| Logs | RDS PostgreSQL logs / CloudWatch Logs | Slow query logs, auto\_explain plans, temp file logs |

Enhanced Monitoring publishes OS metrics through CloudWatch Logs and can be consumed by external monitoring systems. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.html?utm_source=chatgpt.com)

AWS also documents `log_min_duration_statement` for RDS PostgreSQL query logging; queries exceeding the configured duration are written to PostgreSQL logs and can be viewed in the RDS console or CloudWatch Logs if exported. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.Query_Logging.html?utm_source=chatgpt.com)

* * *

4\. First 15-Minute Production Triage
=====================================

4.1 Confirm Whether This Is Database-Side or Application-Side
-------------------------------------------------------------

Ask:

| Question | Signal |
| --- | --- |
| Are all APIs slow or only specific APIs? | Application path vs DB-wide issue |
| Is CPU high? | CPU-bound queries, bad plans, too many sessions |
| Is IOPS high? | Missing indexes, sequential scans, bloat, checkpoint pressure |
| Are connections high? | Pool exhaustion, blocked sessions, slow queries accumulating |
| Are locks present? | Blocking workflow |
| Are temp files high? | Sort/hash spill, low `work_mem`, bad joins |
| Did latency start after deployment? | Query change, ORM change, index drop, parameter change |
| Did data volume increase? | Plan degradation, stale stats, index selectivity issue |

* * *

4.2 RDS CloudWatch Metrics to Check
-----------------------------------

Check these immediately:

| Metric | What It Indicates |
| --- | --- |
| `CPUUtilization` | CPU-bound query, bad plan, too many active sessions |
| `DatabaseConnections` | Connection pressure, pool leak, slow queries piling up |
| `FreeableMemory` | Memory pressure, large sorts/hashes, too many sessions |
| `ReadIOPS` / `WriteIOPS` | Storage pressure, missing index, heavy scan |
| `ReadLatency` / `WriteLatency` | EBS/storage bottleneck |
| `DiskQueueDepth` | I/O backlog |
| `FreeStorageSpace` | Storage exhaustion risk |
| `TransactionLogsDiskUsage` | WAL growth, long transaction, replication issue |
| `ReplicaLag` | Read replica slow, heavy write load, long query on replica |
| `OldestReplicationSlotLag` | Slot retention causing WAL growth |
| `DBLoad` | Active database load from Performance/Database Insights |

* * *

5\. Live SQL Diagnostics
========================

5.1 Current Running Slow Queries
--------------------------------

```
SELECT
    pid,
    usename,
    datname,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_runtime,
    now() - xact_start AS transaction_runtime,
    query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_runtime DESC;
```

Interpretation:

| Symptom | Likely Meaning |
| --- | --- |
| `wait_event_type = Lock` | Query is blocked |
| `wait_event_type = IO` | I/O bottleneck or scan-heavy workload |
| `wait_event_type = Client` | App not consuming results or idle transaction |
| Long `xact_start` | Long-running transaction |
| Many active queries same SQL | Application hot path issue |
| Many idle in transaction | Application transaction leak |

* * *

5.2 Top Queries by Total Time
-----------------------------

```
SELECT
    queryid,
    calls,
    round(total_exec_time::numeric, 2) AS total_exec_ms,
    round(mean_exec_time::numeric, 2) AS mean_exec_ms,
    round(max_exec_time::numeric, 2) AS max_exec_ms,
    rows,
    shared_blks_hit,
    shared_blks_read,
    temp_blks_read,
    temp_blks_written,
    left(query, 500) AS query_sample
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Use this to find queries that consume the most total DB time.

* * *

5.3 Top Queries by Average Latency
----------------------------------

```
SELECT
    queryid,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_exec_ms,
    round(max_exec_time::numeric, 2) AS max_exec_ms,
    round(total_exec_time::numeric, 2) AS total_exec_ms,
    rows,
    left(query, 500) AS query_sample
FROM pg_stat_statements
WHERE calls > 10
ORDER BY mean_exec_time DESC
LIMIT 20;
```

Use this to find individually slow queries.

* * *

5.4 Top Queries by Physical Reads
---------------------------------

```
SELECT
    queryid,
    calls,
    shared_blks_read,
    shared_blks_hit,
    round(
        shared_blks_hit * 100.0 / NULLIF(shared_blks_hit + shared_blks_read, 0),
        2
    ) AS cache_hit_pct,
    round(total_exec_time::numeric, 2) AS total_exec_ms,
    left(query, 500) AS query_sample
FROM pg_stat_statements
ORDER BY shared_blks_read DESC
LIMIT 20;
```

High `shared_blks_read` usually means the query is reading heavily from disk because of missing indexes, bad joins, large scans, or insufficient memory/cache.

* * *

5.5 Top Queries Creating Temp Files
-----------------------------------

```
SELECT
    queryid,
    calls,
    temp_blks_read,
    temp_blks_written,
    round(total_exec_time::numeric, 2) AS total_exec_ms,
    round(mean_exec_time::numeric, 2) AS mean_exec_ms,
    left(query, 500) AS query_sample
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 20;
```

This usually points to:

*   Large sort.
*   Large hash join.
*   Large aggregation.
*   Low `work_mem`.
*   Missing index for `ORDER BY`, `GROUP BY`, or join.
*   Bad planner estimate.

* * *

5.6 Blocking Query Detection
----------------------------

```
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    now() - blocked.query_start AS blocked_duration,
    blocked.query AS blocked_query,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    now() - blocker.query_start AS blocker_duration,
    blocker.state AS blocker_state,
    blocker.query AS blocker_query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks
    ON blocked.pid = blocked_locks.pid
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
  AND blocker_locks.granted;
```

* * *

6\. Query Plan Analysis
=======================

6.1 Use EXPLAIN Safely
----------------------

For read-only SELECT queries:

```
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT ...
;
```

PostgreSQL documentation states that `EXPLAIN ANALYZE` actually executes the statement and reports actual run-time statistics, so be careful with writes or expensive queries. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/sql-explain.html?utm_source=chatgpt.com)

For risky queries:

```
EXPLAIN (BUFFERS, VERBOSE, SETTINGS)
SELECT ...
;
```

For write statements, use a transaction rollback pattern in non-production or controlled sessions:

```
BEGIN;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
UPDATE orders
SET status = 'processed'
WHERE id = 1001;

ROLLBACK;
```

* * *

6.2 What to Look for in EXPLAIN
-------------------------------

| Plan Symptom | Meaning | Common Fix |
| --- | --- | --- |
| Sequential scan on large table | Missing/unused index | Add better index or rewrite predicate |
| Rows estimate far from actual | Stale stats or data skew | `ANALYZE`, extended statistics |
| Nested loop with huge rows | Bad join strategy | Index join key, rewrite query, update stats |
| Hash join spill | Not enough memory or large join | Improve filtering/indexes, tune `work_mem` carefully |
| Sort spill | Large sort on disk | Index for ordering, increase `work_mem` for session |
| Bitmap heap scan with many rechecks | Weak index selectivity | Better composite/partial index |
| High shared read blocks | Disk-heavy query | Index, partitioning, reduce scan |
| High shared hit blocks | CPU/memory heavy scan | Reduce rows, index, query rewrite |
| Function on indexed column | Index not usable | Expression index or rewrite predicate |
| Implicit cast | Index not usable | Fix data type mismatch |

* * *

7\. Root-Cause Classification
=============================

7.1 Query-Level Causes
----------------------

| RCA Category | Symptoms | Example |
| --- | --- | --- |
| Missing index | Seq scan, high reads | `WHERE customer_id = ?` without index |
| Wrong index | Index exists but not used | Predicate order mismatch, low selectivity |
| Stale statistics | Bad row estimates | Planner chooses nested loop wrongly |
| Bad join order | Large intermediate result | Query joins big tables before filtering |
| Non-SARGable predicate | Index ignored | `LOWER(email) = ?`, `DATE(created_at) = ?` |
| Over-fetching | Many rows returned | `SELECT *`, missing pagination |
| N+1 pattern | Many repeated small queries | ORM loop issue |
| Large sort/group | Temp files | `ORDER BY` on large result |
| Correlated subquery | Repeated execution | Subquery executed per row |
| Bad pagination | Offset gets slower | `OFFSET 1000000` |
| Generic prepared plan | Bad for skewed values | Same plan used for different bind values |

* * *

7.2 Database-Level Causes
-------------------------

| RCA Category | Symptoms | Fix |
| --- | --- | --- |
| CPU saturation | High CPU, DB load CPU waits | Tune query, add index, scale instance |
| I/O bottleneck | High read latency, disk queue | Tune query, provision IOPS, reduce scans |
| Memory pressure | Low free memory, temp spill | Reduce active sessions, tune work\_mem carefully |
| Bloat | Slow scans/index scans | Vacuum, reindex, pg\_repack equivalent if available |
| Autovacuum lag | Dead tuples high | Tune autovacuum per table |
| Lock contention | Queries waiting on locks | Fix blocker, reduce transaction duration |
| Connection saturation | Many active/idle sessions | PgBouncer, pool tuning, query optimization |
| Replica lag | Read queries stale/slow | Tune replica workload, scale, reduce long reads |

* * *

8\. Reproducible Simulation Environment
=======================================

Use a non-production RDS PostgreSQL instance or local PostgreSQL lab.

8.1 Base Schema
---------------

```
CREATE TABLE customers (
    id BIGSERIAL PRIMARY KEY,
    email TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(id),
    status TEXT NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO customers (email, status, created_at)
SELECT
    'user' || g || '@example.com',
    CASE WHEN g % 10 = 0 THEN 'inactive' ELSE 'active' END,
    now() - (g || ' minutes')::interval
FROM generate_series(1, 1000000) g;

INSERT INTO orders (customer_id, status, amount, created_at)
SELECT
    (random() * 999999 + 1)::bigint,
    CASE
        WHEN random() < 0.7 THEN 'paid'
        WHEN random() < 0.9 THEN 'pending'
        ELSE 'failed'
    END,
    round((random() * 1000)::numeric, 2),
    now() - ((random() * 365)::int || ' days')::interval
FROM generate_series(1, 5000000) g;

ANALYZE customers;
ANALYZE orders;
```

* * *

9\. Simulation Scenarios
========================

Scenario 1: Missing Index Causing Sequential Scan
-------------------------------------------------

### How It Happens

Application queries a large table using a filter column without an index.

### Simulate

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM orders
WHERE status = 'failed';
```

### Detect

```
SELECT
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

### Expected Plan Problem

```
Seq Scan on orders
Filter: status = 'failed'
Rows Removed by Filter: many
```

### Resolve

If selectivity is high enough:

```
CREATE INDEX CONCURRENTLY idx_orders_status
ON orders(status);
```

If query commonly filters status and date:

```
CREATE INDEX CONCURRENTLY idx_orders_status_created_at
ON orders(status, created_at DESC);
```

### Prevent

*   Review query patterns before release.
*   Add indexing checklist to schema migration.
*   Monitor high `seq_tup_read`.

* * *

Scenario 2: Composite Index Missing
-----------------------------------

### Problem Query

```
SELECT *
FROM orders
WHERE customer_id = 12345
  AND status = 'paid'
ORDER BY created_at DESC
LIMIT 20;
```

### Simulate

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM orders
WHERE customer_id = 12345
  AND status = 'paid'
ORDER BY created_at DESC
LIMIT 20;
```

### Fix

```
CREATE INDEX CONCURRENTLY idx_orders_customer_status_created
ON orders(customer_id, status, created_at DESC);
```

### Why This Helps

The index supports:

*   Equality filter on `customer_id`.
*   Equality filter on `status`.
*   Ordered retrieval by `created_at DESC`.
*   Fast `LIMIT`.

* * *

Scenario 3: Function on Indexed Column
--------------------------------------

### How It Happens

```
SELECT *
FROM customers
WHERE lower(email) = 'user100@example.com';
```

A normal index on `email` may not help because the query applies a function.

### Simulate

```
CREATE INDEX CONCURRENTLY idx_customers_email
ON customers(email);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM customers
WHERE lower(email) = 'user100@example.com';
```

### Fix Option 1: Expression Index

```
CREATE INDEX CONCURRENTLY idx_customers_lower_email
ON customers (lower(email));
```

### Fix Option 2: Store Normalized Email

```
ALTER TABLE customers ADD COLUMN email_normalized TEXT;

UPDATE customers
SET email_normalized = lower(email);

CREATE INDEX CONCURRENTLY idx_customers_email_normalized
ON customers(email_normalized);
```

* * *

Scenario 4: Date Function Preventing Index Usage
------------------------------------------------

### Bad Query

```
SELECT *
FROM orders
WHERE date(created_at) = date '2026-06-24';
```

### Better Query

```
SELECT *
FROM orders
WHERE created_at >= timestamp '2026-06-24 00:00:00'
  AND created_at <  timestamp '2026-06-25 00:00:00';
```

### Index

```
CREATE INDEX CONCURRENTLY idx_orders_created_at
ON orders(created_at);
```

* * *

Scenario 5: Offset Pagination Slowness
--------------------------------------

### How It Happens

```
SELECT *
FROM orders
ORDER BY created_at DESC
OFFSET 1000000
LIMIT 50;
```

PostgreSQL still has to walk through many rows before returning the requested page.

### Better Approach: Keyset Pagination

```
SELECT *
FROM orders
WHERE created_at < timestamp '2026-06-24 10:00:00'
ORDER BY created_at DESC
LIMIT 50;
```

### Index

```
CREATE INDEX CONCURRENTLY idx_orders_created_at_desc
ON orders(created_at DESC);
```

* * *

Scenario 6: Stale Statistics Causing Bad Plan
---------------------------------------------

### How It Happens

Large data changes happen, but statistics are stale. Planner estimates become wrong.

### Simulate

```
INSERT INTO orders (customer_id, status, amount, created_at)
SELECT
    1,
    'failed',
    100,
    now()
FROM generate_series(1, 500000);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM orders
WHERE customer_id = 1
  AND status = 'failed';
```

### Detect

```
SELECT
    schemaname,
    relname,
    last_analyze,
    last_autoanalyze,
    n_live_tup,
    n_dead_tup,
    n_mod_since_analyze
FROM pg_stat_user_tables
WHERE relname = 'orders';
```

### Resolve

```
ANALYZE orders;
```

For skewed correlated columns:

```
CREATE STATISTICS st_orders_customer_status
ON customer_id, status
FROM orders;

ANALYZE orders;
```

* * *

Scenario 7: Large Sort Causing Temp File Spill
----------------------------------------------

### Simulate

```
SET work_mem = '4MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM orders
ORDER BY amount DESC;
```

### Detect

```
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

Also check `pg_stat_statements.temp_blks_written`.

### Fix Options

1.  Add index if sort is common and selective:

```
CREATE INDEX CONCURRENTLY idx_orders_amount_desc
ON orders(amount DESC);
```

2.  Add pagination:

```
SELECT *
FROM orders
ORDER BY amount DESC
LIMIT 100;
```

3.  Increase `work_mem` only for controlled session/job:

```
SET LOCAL work_mem = '128MB';
```

Avoid globally increasing `work_mem` without calculating concurrency impact.

* * *

Scenario 8: Bad Join Plan
-------------------------

### Simulate

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.email, o.amount, o.created_at
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.status = 'active'
  AND o.status = 'failed';
```

### Detect

Look for:

*   Huge nested loop.
*   Large hash join spill.
*   Bad row estimates.
*   Missing index on join/filter columns.

### Fix

```
CREATE INDEX CONCURRENTLY idx_orders_status_customer
ON orders(status, customer_id);

CREATE INDEX CONCURRENTLY idx_customers_status_id
ON customers(status, id);
```

* * *

Scenario 9: N+1 Query Pattern
-----------------------------

### How It Happens

Application fetches customers, then separately fetches orders per customer.

Example:

```
SELECT * FROM customers WHERE status = 'active' LIMIT 1000;

Then 1000 times:
SELECT * FROM orders WHERE customer_id = ?;
```

### Detect

In `pg_stat_statements`:

```
SELECT
    calls,
    mean_exec_time,
    total_exec_time,
    left(query, 300)
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 20;
```

High calls with low individual latency but high total time suggests N+1.

### Fix

Use one batched query:

```
SELECT *
FROM orders
WHERE customer_id = ANY($1);
```

Or join:

```
SELECT c.id, c.email, o.id, o.amount
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
WHERE c.status = 'active'
LIMIT 1000;
```

* * *

Scenario 10: Lock Wait Appearing as Slow Query
----------------------------------------------

### Session 1

```
BEGIN;

UPDATE orders
SET status = 'processing'
WHERE id = 100;
```

Do not commit.

### Session 2

```
UPDATE orders
SET status = 'paid'
WHERE id = 100;
```

Session 2 waits.

### Detect

```
SELECT
    pid,
    wait_event_type,
    wait_event,
    now() - query_start AS runtime,
    query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';
```

### Resolve

Identify blocker. If safe:

```
SELECT pg_terminate_backend(<blocker_pid>);
```

Use `pg_cancel_backend()` first for active queries where possible:

```
SELECT pg_cancel_backend(<pid>);
```

Use `pg_terminate_backend()` only when cancellation is not enough and business approval is available.

* * *

Scenario 11: Generic Prepared Plan Problem
------------------------------------------

### How It Happens

Prepared statements with bind variables may use a generic plan that is poor for skewed data.

Example:

```
PREPARE q(text) AS
SELECT *
FROM orders
WHERE status = $1;
```

If `status = 'paid'` returns millions of rows but `status = 'failed'` returns fewer rows, one generic plan may not be good for all values.

### Detect

Symptoms:

*   Same query sometimes fast, sometimes slow.
*   Different bind values have very different selectivity.
*   Plan does not change despite different parameters.

### Test

```
SET plan_cache_mode = force_custom_plan;

EXPLAIN (ANALYZE, BUFFERS)
EXECUTE q('failed');
```

### Fix Options

*   Use custom plans for specific sessions.
*   Avoid overusing prepared statements for highly skewed predicates.
*   Add partial indexes.

```
CREATE INDEX CONCURRENTLY idx_orders_failed_created
ON orders(created_at DESC)
WHERE status = 'failed';
```

* * *

Scenario 12: Table / Index Bloat Slowing Queries
------------------------------------------------

### Detect Dead Tuples

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_pct,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

### Detect Large Indexes

```
SELECT
    schemaname,
    relname,
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
```

### Resolve

```
VACUUM (ANALYZE) orders;
```

For index bloat:

```
REINDEX INDEX CONCURRENTLY idx_orders_status_created_at;
```

For table bloat, plan a controlled maintenance window. On RDS, avoid heavy blocking operations during peak traffic.

* * *

10\. Safe Remediation Patterns
==============================

10.1 Create Index Safely
------------------------

Use:

```
CREATE INDEX CONCURRENTLY idx_name
ON table_name(column_name);
```

Avoid regular `CREATE INDEX` on large production tables because it can block writes.

After creation:

```
ANALYZE table_name;
```

Validate:

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...
```

* * *

10.2 Drop Index Safely
----------------------

Before dropping:

```
SELECT
    schemaname,
    relname,
    indexrelname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE indexrelname = 'index_name';
```

Then:

```
DROP INDEX CONCURRENTLY index_name;
```

Do not drop indexes based only on `idx_scan = 0` unless stats have been collected over a representative workload period.

* * *

10.3 Cancel vs Terminate
------------------------

| Action | SQL | Risk |
| --- | --- | --- |
| Cancel query | `pg_cancel_backend(pid)` | Safer, cancels current query |
| Terminate session | `pg_terminate_backend(pid)` | Higher risk, rolls back transaction and disconnects session |

Use terminate only after confirming:

*   Business impact.
*   Query owner.
*   Transaction age.
*   Whether it is a migration, backup, maintenance, or customer workflow.

* * *

10.4 Session-Level Tuning
-------------------------

For reporting jobs:

```
BEGIN;
SET LOCAL work_mem = '256MB';
SET LOCAL statement_timeout = '15min';

SELECT ...

COMMIT;
```

Avoid global changes until you understand concurrency impact.

Example risk:

```
work_mem = 128MB
max active sort/hash sessions = 100
Potential memory demand = 12.8GB+
```

One query can use multiple `work_mem` allocations.

* * *

11\. Performance Tuning Checklist
=================================

11.1 Query Design
-----------------

| Check | Good Practice |
| --- | --- |
| Avoid `SELECT *` | Select only needed columns |
| Use pagination | Always limit large result sets |
| Avoid large `OFFSET` | Use keyset pagination |
| Avoid functions on indexed columns | Use expression index or rewrite |
| Avoid implicit casts | Match parameter and column types |
| Avoid correlated subqueries | Rewrite as join or lateral where appropriate |
| Avoid N+1 | Batch fetch |
| Filter early | Reduce rows before join/group/sort |
| Use proper join keys | Ensure indexes exist |
| Use `EXISTS` for existence checks | Avoid unnecessary row materialization |

* * *

11.2 Index Design
-----------------

| Query Pattern | Index Pattern |
| --- | --- |
| `WHERE customer_id = ?` | `(customer_id)` |
| `WHERE customer_id = ? AND status = ?` | `(customer_id, status)` |
| Filter + sort | `(filter_col, sort_col DESC)` |
| `ORDER BY created_at DESC LIMIT 20` | `(created_at DESC)` |
| Rare status filter | Partial index |
| `lower(email)` search | Expression index |
| Covering query | `INCLUDE` columns |
| Time-series data | BRIN index for large append-only tables |

Example covering index:

```
CREATE INDEX CONCURRENTLY idx_orders_customer_created_include
ON orders(customer_id, created_at DESC)
INCLUDE (status, amount);
```

Example partial index:

```
CREATE INDEX CONCURRENTLY idx_orders_pending_created
ON orders(created_at DESC)
WHERE status = 'pending';
```

* * *

11.3 Statistics Tuning
----------------------

For frequently changing large tables:

```
ALTER TABLE orders SET (
    autovacuum_analyze_scale_factor = 0.02,
    autovacuum_analyze_threshold = 10000
);
```

For skewed columns:

```
ALTER TABLE orders
ALTER COLUMN status SET STATISTICS 1000;

ANALYZE orders;
```

For correlated columns:

```
CREATE STATISTICS st_orders_customer_status_created
ON customer_id, status, created_at
FROM orders;

ANALYZE orders;
```

* * *

12\. RDS Parameter Tuning Areas
===============================

12.1 Query Logging
------------------

Useful production settings:

```
log_min_duration_statement = 1000
log_lock_waits = on
deadlock_timeout = 1s
log_temp_files = 102400
```

`log_temp_files = 102400` logs temp files above 100 MB.

* * *

12.2 Memory
-----------

Important parameters:

| Parameter | Purpose | Caution |
| --- | --- | --- |
| `work_mem` | Sort/hash memory per operation | Multiplies by sessions and nodes |
| `maintenance_work_mem` | Vacuum/index maintenance | Useful for maintenance, not query execution |
| `shared_buffers` | PostgreSQL buffer cache | RDS defaults are usually reasonable |
| `effective_cache_size` | Planner estimate of cache | Does not allocate memory |
| `temp_file_limit` | Per-session temp file cap | Prevents runaway temp usage |

* * *

12.3 Timeouts
-------------

Recommended application/database safety:

```
statement_timeout = based on workload
idle_in_transaction_session_timeout = 5min or lower for OLTP
lock_timeout = 5s to 30s for migrations
```

For deployment scripts:

```
SET lock_timeout = '5s';
SET statement_timeout = '10min';
```

* * *

13\. AWS RDS Specific Investigation Steps
=========================================

Step 1: Check CloudWatch
------------------------

Look for:

*   CPU spike.
*   Read/write latency spike.
*   IOPS saturation.
*   Connections spike.
*   Free memory drop.
*   Disk queue depth increase.
*   Replica lag.
*   Free storage drop.

CloudWatch collects and processes RDS metrics into readable near-real-time metrics, and AWS recommends CloudWatch Database Insights for performance analysis at scale. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/monitoring-cloudwatch.html?utm_source=chatgpt.com)

* * *

Step 2: Check Database Insights / Performance Insights
------------------------------------------------------

Filter by:

*   Top SQL.
*   Wait event.
*   Host.
*   User.
*   Database.
*   Application name.
*   Time window before and during issue.

Important wait categories:

| Wait | Meaning |
| --- | --- |
| CPU | CPU-bound SQL |
| IO/DataFileRead | Disk reads |
| Lock | Blocking |
| LWLock | Internal contention |
| Client | App/network/client slow consuming results |
| IPC | Parallel query or background process waits |
| Timeout | Sleep/wait conditions |

* * *

Step 3: Check PostgreSQL Logs
-----------------------------

Look for:

*   Slow query logs.
*   Temp file logs.
*   Deadlock errors.
*   Lock wait logs.
*   Autovacuum messages.
*   Checkpoint warnings.
*   Out-of-memory messages.
*   Connection errors.

* * *

Step 4: Check Deployment Timeline
---------------------------------

Correlate with:

*   Application release.
*   ORM change.
*   New API.
*   Migration.
*   Index drop/create.
*   Parameter group change.
*   Instance class/storage change.
*   Data backfill.
*   Reporting job.
*   Backup/export job.

* * *

14\. Agent-Based RCA Workflow
=============================

This section describes how to build an automated RCA agent for slow queries.

14.1 Agent Inputs
-----------------

The agent should collect:

```
{
  "time_window": "2026-06-24T10:00:00+05:30 to 2026-06-24T11:00:00+05:30",
  "db_instance": "prod-rds-postgres-01",
  "database": "appdb",
  "symptom": "API latency increased",
  "threshold_ms": 1000,
  "release_marker": "optional deployment id"
}
```

* * *

14.2 Agent Data Collection Modules
----------------------------------

| Module | Data |
| --- | --- |
| RDS Metrics Collector | CPU, IOPS, memory, connections, latency |
| DB Load Collector | Top SQL, waits, DB load |
| SQL Stats Collector | `pg_stat_statements` |
| Activity Collector | `pg_stat_activity` |
| Lock Collector | `pg_locks` blocker chain |
| Table Stats Collector | `pg_stat_user_tables` |
| Index Stats Collector | `pg_stat_user_indexes` |
| Log Collector | Slow logs, temp logs, deadlocks |
| Deployment Collector | Recent releases/migrations |
| Schema Collector | Table/index definitions |

* * *

14.3 Agent RCA Decision Tree
----------------------------

```
IF DB CPU high AND top SQL total_exec_time high:
    classify as CPU-bound query
    analyze plan, rows, joins, sort, functions

IF ReadIOPS/ReadLatency high AND top SQL shared_blks_read high:
    classify as I/O-heavy query
    check missing indexes, seq scans, bloat

IF temp_blks_written high OR temp file logs exist:
    classify as temp spill
    check sort/hash/group by, work_mem, indexes

IF wait_event_type = Lock:
    classify as lock wait
    find blocker and blocked workflow

IF query estimates differ heavily from actual rows:
    classify as stale stats/data skew
    recommend ANALYZE or extended statistics

IF calls extremely high but mean latency low:
    classify as N+1 or chatty application pattern

IF connection count high and many active same SQL:
    classify as slow query amplification / pool exhaustion

IF slow started after release:
    classify as regression candidate
    compare queryid and plan before/after
```

* * *

14.4 Agent RCA Output Format
----------------------------

```
{
  "severity": "High",
  "primary_root_cause": "Missing composite index",
  "confidence": 0.87,
  "evidence": [
    "Query ranked #1 by total_exec_time",
    "Sequential scan on orders table",
    "shared_blks_read increased during incident",
    "CloudWatch ReadLatency spiked"
  ],
  "affected_sql": "...",
  "recommended_fix": "CREATE INDEX CONCURRENTLY idx_orders_customer_status_created ...",
  "safe_actions_now": [
    "Confirm query plan",
    "Create index concurrently during low traffic",
    "Analyze table after index creation"
  ],
  "avoid": [
    "Do not terminate sessions unless blocking confirmed",
    "Do not globally increase work_mem"
  ]
}
```

* * *

15\. Agent-Based Remediation Guardrails
=======================================

The agent should not automatically execute risky actions without approval.

Safe Auto-Actions
-----------------

| Action | Auto Allowed? |
| --- | --- |
| Read metrics | Yes |
| Read `pg_stat_activity` | Yes |
| Read `pg_stat_statements` | Yes |
| Generate EXPLAIN without ANALYZE | Yes |
| Recommend index | Yes |
| Run `ANALYZE` on small/medium table | Conditional |
| Cancel query | Approval required |
| Terminate backend | Approval required |
| Create index concurrently | Approval required |
| Drop index | Approval required |
| Change parameter group | Approval required |
| Scale RDS instance | Approval required |

* * *

16\. Production Incident Runbook
================================

16.1 Severity Classification
----------------------------

| Severity | Condition |
| --- | --- |
| SEV1 | Application unavailable, DB saturated, widespread timeout |
| SEV2 | Major workflow slow, high DB load, user impact |
| SEV3 | Specific API/report slow, workaround available |
| SEV4 | Optimization request, no active impact |

* * *

16.2 Immediate Actions
----------------------

### If CPU is Saturated

1.  Identify top SQL by DB load and `pg_stat_statements`.
2.  Check active sessions.
3.  Cancel runaway reporting queries if approved.
4.  Reduce traffic if possible.
5.  Add missing index only after validation.
6.  Consider scaling if immediate query fix is not possible.

### If I/O is Saturated

1.  Identify SQL with high `shared_blks_read`.
2.  Check missing indexes and sequential scans.
3.  Check bloat.
4.  Check storage latency and IOPS limits.
5.  Consider storage scaling/provisioned IOPS if query is already optimized.

### If Locks Are Causing Slow Queries

1.  Identify blocker.
2.  Check blocker query and transaction age.
3.  Confirm business context.
4.  Cancel/terminate blocker if approved.
5.  Add prevention: shorter transactions, lock timeout, deployment safeguards.

### If Temp Files Are Exploding

1.  Find queries with `temp_blks_written`.
2.  Check sort/hash/group plans.
3.  Add index or reduce result size.
4.  Use session-level `work_mem` for batch/reporting jobs.
5.  Add `temp_file_limit`.

* * *

17\. Practical SQL Toolkit
==========================

17.1 Database-Level Health
--------------------------

```
SELECT
    datname,
    numbackends,
    xact_commit,
    xact_rollback,
    blks_read,
    blks_hit,
    round(blks_hit * 100.0 / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    deadlocks
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY numbackends DESC;
```

* * *

17.2 Table Scan Hotspots
------------------------

```
SELECT
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    n_live_tup,
    n_dead_tup
FROM pg_stat_user_tables
ORDER BY seq_tup_read DESC
LIMIT 20;
```

* * *

17.3 Unused or Low-Use Indexes
------------------------------

```
SELECT
    schemaname,
    relname,
    indexrelname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
```

Do not immediately drop these. Validate over a representative period.

* * *

17.4 Duplicate Index Candidates
-------------------------------

```
SELECT
    indrelid::regclass AS table_name,
    indexrelid::regclass AS index_name,
    pg_get_indexdef(indexrelid) AS index_def
FROM pg_index
WHERE indrelid IN (
    SELECT oid
    FROM pg_class
    WHERE relkind = 'r'
)
ORDER BY table_name, index_def;
```

Manual review required.

* * *

17.5 Long Transactions
----------------------

```
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
    query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_age DESC
LIMIT 20;
```

* * *

17.6 Idle in Transaction
------------------------

```
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
ORDER BY xact_start;
```

* * *

18\. Preventive Best Practices
==============================

18.1 Deployment-Time Query Review
---------------------------------

Every database-impacting release should answer:

| Question | Required Evidence |
| --- | --- |
| New SQL introduced? | Query list |
| Large table touched? | Table size, row count |
| Index needed? | EXPLAIN plan |
| Migration lock risk? | Lock timeout tested |
| Query tested on production-size data? | Benchmark result |
| Rollback available? | Rollback script |
| Monitoring added? | Dashboard/alert link |

* * *

18.2 Index Governance
---------------------

Maintain an index review process:

*   New index must map to a real query.
*   Composite index column order must match filter/sort pattern.
*   Avoid redundant indexes.
*   Use partial indexes for low-cardinality rare values.
*   Use expression indexes only when needed.
*   Review index bloat.
*   Review unused indexes monthly.

* * *

18.3 Slow Query Monitoring
--------------------------

Recommended alerts:

| Alert | Suggested Trigger |
| --- | --- |
| DBLoad above vCPU count | Sustained 5–10 minutes |
| CPU > 80% | Sustained 10 minutes |
| Read latency high | Sustained 5 minutes |
| Connections > 80% max | Immediate warning |
| Temp bytes spike | Above baseline |
| Deadlocks > 0 | Immediate |
| Long transaction > 15 min | Warning |
| Idle in transaction > 5 min | Warning |
| Lock wait > 30 sec | Warning |
| Query runtime > SLA | Warning |

* * *

18.4 Application Best Practices
-------------------------------

*   Set `application_name` per service/job.
*   Use connection pooling.
*   Avoid unbounded queries.
*   Add pagination.
*   Avoid N+1 query patterns.
*   Use read replicas for reporting, but monitor replica lag.
*   Keep transactions short.
*   Avoid user-facing APIs depending on heavy reports.
*   Add query timeout at app and DB level.
*   Tag SQL comments with service/workflow where possible.

Example:

```
/* service=billing api=get_customer_invoice trace_id=abc123 */
SELECT ...
```

* * *

19\. Production Optimization Examples
=====================================

Example 1: Slow Customer Order API
----------------------------------

### Symptom

API `/customers/{id}/orders` takes 8 seconds.

### Query

```
SELECT *
FROM orders
WHERE customer_id = $1
ORDER BY created_at DESC
LIMIT 50;
```

### Plan Problem

Sequential scan or sort.

### Fix

```
CREATE INDEX CONCURRENTLY idx_orders_customer_created
ON orders(customer_id, created_at DESC);
```

### Validate

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM orders
WHERE customer_id = 12345
ORDER BY created_at DESC
LIMIT 50;
```

Expected:

```
Index Scan using idx_orders_customer_created
```

* * *

Example 2: Slow Dashboard Count
-------------------------------

### Bad Query

```
SELECT count(*)
FROM orders
WHERE status = 'pending';
```

On a very large table, repeated counts can be expensive.

### Fix Options

1.  Partial index:

```
CREATE INDEX CONCURRENTLY idx_orders_pending
ON orders(id)
WHERE status = 'pending';
```

2.  Pre-aggregated summary table.
3.  Approximate count if exact count is not required.
4.  Cache dashboard counts.

* * *

Example 3: Slow Search by Email
-------------------------------

### Bad Query

```
SELECT *
FROM customers
WHERE lower(email) = lower($1);
```

### Fix

```
CREATE INDEX CONCURRENTLY idx_customers_lower_email
ON customers(lower(email));
```

* * *

Example 4: Reporting Query Slowing OLTP
---------------------------------------

### Symptom

CPU and read IOPS spike every day at 10 AM.

### RCA

Reporting query scans `orders` and joins `customers`.

### Fix

*   Move report to read replica.
*   Add covering indexes.
*   Add materialized summary table.
*   Schedule outside peak hours.
*   Set statement timeout.
*   Limit report concurrency.

* * *

20\. Final DBA Checklist
========================

Use this checklist during every slow-query incident.

Detection
---------

*    Confirm time window.
*    Check CloudWatch metrics.
*    Check DB load by waits.
*    Identify top SQL.
*    Check active sessions.
*    Check locks.
*    Check temp files.
*    Check recent deployment.

Analysis
--------

*    Capture query text.
*    Capture queryid.
*    Run safe EXPLAIN.
*    Compare estimated vs actual rows.
*    Check indexes.
*    Check table stats.
*    Check bloat/dead tuples.
*    Check bind-value skew.
*    Check application query pattern.

Remediation
-----------

*    Cancel only unsafe runaway query if approved.
*    Add index concurrently if validated.
*    Run `ANALYZE` if stats stale.
*    Rewrite query if non-SARGable.
*    Reduce result set.
*    Fix pagination.
*    Move reporting workload if needed.
*    Tune session-level memory only if justified.

Prevention
----------

*    Add alert.
*    Add dashboard.
*    Add query review in deployment checklist.
*    Add test with production-like data.
*    Add index governance.
*    Add RCA entry to knowledge base.

* * *

21\. Recommended RCA Template
=============================

```
Incident Title:
RDS PostgreSQL slow query / performance degradation

Time Window:
Start:
End:

Impact:
Affected APIs / jobs:
Customer impact:
Severity:

RDS Metrics:
CPU:
Connections:
Read IOPS:
Write IOPS:
Read latency:
Write latency:
Free memory:
Storage:
Replica lag:

Top Waits:
1.
2.
3.

Top SQL:
Query ID:
Mean time:
Total time:
Calls:
Rows:
Temp blocks:
Shared reads:
Shared hits:

Execution Plan Summary:
Plan type:
Estimated rows:
Actual rows:
Seq scan:
Index scan:
Sort:
Hash:
Temp spill:
Parallelism:

Root Cause:
Primary:
Contributing factors:

Resolution:
Immediate action:
Permanent fix:

Validation:
Before latency:
After latency:
Before DB load:
After DB load:

Prevention:
Monitoring:
Alert:
Code change:
Index change:
Runbook update:
```

* * *

22\. Key Takeaway
=================

For RDS PostgreSQL slow-query RCA, do not start by tuning parameters. Start with evidence:

```
CloudWatch / Database Insights
        +
pg_stat_statements
        +
pg_stat_activity
        +
EXPLAIN plan
        +
table/index/statistics health
```

Most production slow-query issues fall into a small number of repeatable patterns: missing or wrong indexes, stale statistics, bad joins, temp spills, lock waits, over-fetching, N+1 queries, bloat, I/O saturation, or post-deployment query regressions. The safest DBA approach is to identify the exact query and plan first, validate the fix with production-like data, then apply minimal, reversible remediation.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)