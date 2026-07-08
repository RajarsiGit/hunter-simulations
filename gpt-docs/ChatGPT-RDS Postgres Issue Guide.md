# RDS Postgres Issue Guide

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:27  
**Link:** [https://chatgpt.com/share/e/6a4c9736-4b4c-83ee-844c-aedf629341f8](https://chatgpt.com/share/e/6a4c9736-4b4c-83ee-844c-aedf629341f8)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert. 

I need a complete investigation and simulation plan for the topic: "RDS Postgres - Storage Full, WAL Log, CPU High, IOPS High, Session High, Connection High - AWS RDS Postgres Environment" 

Create a complete guide for investigating, simulating, and resolving. Include manual troubleshooting steps, analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices. 

Please cover this in depth from both manual troubleshooting steps and agent-based/root-cause analysis automation perspectives. The goal is to identify, diagnose, reproduce, and resolve production issues.

Create Multiple scenarios for each Category

Show moreShow less

## Response:
I’ll structure this as a production-ready DBA runbook: symptoms, diagnostics, RCA categories, simulation scenarios, safe remediation, and agent automation workflows for each issue area.

Thought for 6s

Below is a production-oriented investigation, simulation, and remediation guide for **AWS RDS PostgreSQL issues related to Storage Full, WAL Log growth, CPU High, IOPS High, Session High, and Connection High**.

This is written from both a **manual DBA troubleshooting** and **agent-based RCA automation** perspective.

* * *

1\. Scope and Incident Categories
=================================

Covered production issue categories
-----------------------------------

| Category | Typical Alert / Symptom |
| --- | --- |
| Storage Full | `FreeStorageSpace` low, RDS `storage-full`, write failures |
| WAL Log Growth | Transaction log disk usage increasing, replication slot lag, storage drops rapidly |
| CPU High | `CPUUtilization` high, DB load above vCPU count, slow queries |
| IOPS High | `ReadIOPS`, `WriteIOPS`, latency, disk queue depth high |
| Session High | Many active / idle / waiting sessions |
| Connection High | `DatabaseConnections` close to `max_connections`, connection timeout, PgBouncer saturation |

AWS RDS exposes key CloudWatch metrics such as `CPUUtilization`, `FreeStorageSpace`, `DatabaseConnections`, `ReadIOPS`, `WriteIOPS`, latency, throughput, and queue depth for instance-level monitoring. PostgreSQL-side RCA should be done using views such as `pg_stat_activity`, `pg_stat_database`, `pg_stat_user_tables`, `pg_stat_replication`, `pg_replication_slots`, and query-level tools such as Performance Insights or `pg_stat_statements`. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+2![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL+2](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-metrics.html?utm_source=chatgpt.com)

* * *

2\. Common Investigation Flow for Any Incident
==============================================

2.1 First 5 Minutes: Stabilize and Classify
-------------------------------------------

When an alert fires, do not immediately restart the database. First classify the issue.

Check:

```
SELECT now();

SELECT
  datname,
  numbackends,
  xact_commit,
  xact_rollback,
  blks_read,
  blks_hit,
  temp_files,
  temp_bytes,
  deadlocks
FROM pg_stat_database
ORDER BY numbackends DESC;
```

Check active sessions:

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
  now() - query_start AS query_age,
  now() - xact_start AS xact_age,
  left(query, 500) AS query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
ORDER BY query_age DESC NULLS LAST;
```

Check blocking:

```
SELECT
  blocked.pid AS blocked_pid,
  blocked.usename AS blocked_user,
  now() - blocked.query_start AS blocked_duration,
  blocking.pid AS blocking_pid,
  blocking.usename AS blocking_user,
  now() - blocking.query_start AS blocking_duration,
  blocked.wait_event_type,
  blocked.wait_event,
  left(blocked.query, 300) AS blocked_query,
  left(blocking.query, 300) AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY blocked_duration DESC;
```

Check largest databases:

```
SELECT
  datname,
  pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

Check biggest tables:

```
SELECT
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_relation_size(relid)) AS table_size,
  pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS index_size,
  n_live_tup,
  n_dead_tup,
  last_vacuum,
  last_autovacuum
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 30;
```

2.2 RDS Console / AWS Side Checks
---------------------------------

Use:

1.  **CloudWatch Metrics**
    *   `CPUUtilization`
    *   `FreeStorageSpace`
    *   `DatabaseConnections`
    *   `ReadIOPS`
    *   `WriteIOPS`
    *   `ReadLatency`
    *   `WriteLatency`
    *   `DiskQueueDepth`
    *   `FreeableMemory`
    *   `SwapUsage`
    *   `TransactionLogsDiskUsage`, where available
2.  **Performance Insights**
    *   DB Load
    *   Top SQL
    *   Wait events
    *   Top users
    *   Top hosts
    *   Top databases
3.  **RDS Logs**
    *   PostgreSQL error log
    *   slow query log
    *   checkpoints
    *   autovacuum logs
    *   temporary file logs
4.  **RDS Events**
    *   storage autoscaling
    *   failover
    *   reboot
    *   backup activity
    *   storage-full warnings

Performance Insights wait events are especially useful because they help distinguish whether the pressure is CPU, I/O, lock, WAL, client, or extension related. AWS documents common RDS PostgreSQL wait events, their causes, and corrective actions. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.summary.html?utm_source=chatgpt.com)

* * *

3\. Category 1: Storage Full
============================

3.1 How Storage Full Happens
----------------------------

Storage full in RDS PostgreSQL usually comes from one or more of these:

| Root Cause | Description |
| --- | --- |
| Table growth | Legitimate business data growth |
| Index bloat | Large unused or duplicated indexes |
| Table bloat | Dead tuples not reclaimed |
| WAL retention | Replication slot, long transaction, replica lag |
| Temp file growth | Large sorts, hashes, joins spilling to disk |
| Excessive logs | High-volume PostgreSQL logs retained/exported |
| Failed vacuum | Autovacuum unable to keep up |
| Bulk load | Large import or migration |
| Partition retention failure | Old partitions not dropped |
| Long transaction | Prevents cleanup and increases bloat/WAL pressure |

PostgreSQL documentation notes that a full data disk can prevent useful database activity, and if WAL storage fills, the server may panic and shut down. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/diskusage.html?utm_source=chatgpt.com)

* * *

3.2 Storage Full Investigation Checklist
----------------------------------------

### Step 1: Confirm storage trend

AWS CloudWatch:

*   `FreeStorageSpace`
*   `FreeStorageSpace` slope
*   `TransactionLogsDiskUsage`
*   `ReadIOPS`
*   `WriteIOPS`
*   `DiskQueueDepth`

Questions:

*   Is storage dropping slowly over days?
*   Is storage dropping suddenly within minutes?
*   Did it start after deployment, migration, backup, replication, or bulk job?
*   Is storage consumed by data, indexes, WAL, or temp files?

* * *

### Step 2: Check database sizes

```
SELECT
  datname,
  pg_size_pretty(pg_database_size(datname)) AS database_size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

* * *

### Step 3: Check table and index sizes

```
SELECT
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  pg_size_pretty(pg_relation_size(relid)) AS table_size,
  pg_size_pretty(pg_indexes_size(relid)) AS index_size,
  n_live_tup,
  n_dead_tup
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 50;
```

* * *

### Step 4: Check dead tuples and vacuum health

```
SELECT
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
  last_vacuum,
  last_autovacuum,
  vacuum_count,
  autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 50;
```

* * *

### Step 5: Check temp file generation

```
SELECT
  datname,
  temp_files,
  pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

Enable temp file logging in parameter group:

```
log_temp_files = 0
```

For production, use a safer threshold:

```
log_temp_files = 1048576
```

That logs temp files larger than 1 MB.

* * *

### Step 6: Check replication slots

For PostgreSQL 10+:

```
SELECT
  slot_name,
  slot_type,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;
```

AWS specifically highlights inactive or unconsumed replication slots as a common reason transaction logs grow and free storage drops continuously. [![](https://www.google.com/s2/favicons?domain=https://repost.aws&sz=128)repost.aws](https://repost.aws/knowledge-center/diskfull-error-rds-postgresql?utm_source=chatgpt.com)

* * *

### Step 7: Check long transactions

```
SELECT
  pid,
  usename,
  datname,
  application_name,
  client_addr,
  state,
  now() - xact_start AS transaction_age,
  now() - query_start AS query_age,
  wait_event_type,
  wait_event,
  left(query, 500) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC;
```

* * *

### Step 8: Check old replication / backup / logical decoding activity

```
SELECT
  pid,
  usename,
  application_name,
  client_addr,
  state,
  backend_type,
  wait_event_type,
  wait_event,
  now() - backend_start AS backend_age,
  left(query, 500) AS query
FROM pg_stat_activity
WHERE backend_type ILIKE '%replication%'
   OR application_name ILIKE '%replication%'
   OR application_name ILIKE '%dms%'
ORDER BY backend_start;
```

* * *

3.3 Storage Full Simulation Scenarios
-------------------------------------

Use a non-production test RDS instance.

### Scenario 1: Legitimate table growth

**How it happens**

A bulk insert, migration, or job creates millions of rows.

**Simulation**

```
CREATE TABLE storage_growth_test (
  id bigserial PRIMARY KEY,
  payload text,
  created_at timestamptz DEFAULT now()
);

INSERT INTO storage_growth_test(payload)
SELECT repeat(md5(random()::text), 100)
FROM generate_series(1, 5000000);
```

**Detect**

```
SELECT
  pg_size_pretty(pg_total_relation_size('storage_growth_test')) AS size;
```

**Resolve**

```
DROP TABLE storage_growth_test;
```

In real production:

*   Archive old records.
*   Partition large time-series tables.
*   Increase RDS allocated storage.
*   Enable storage autoscaling.
*   Validate retention jobs.

* * *

### Scenario 2: Index bloat / excessive index growth

**Simulation**

```
CREATE TABLE index_growth_test (
  id bigserial PRIMARY KEY,
  tenant_id int,
  status text,
  created_at timestamptz,
  payload text
);

INSERT INTO index_growth_test(tenant_id, status, created_at, payload)
SELECT
  (random() * 1000)::int,
  md5(random()::text),
  now() - (random() * interval '365 days'),
  repeat(md5(random()::text), 50)
FROM generate_series(1, 2000000);

CREATE INDEX idx_index_growth_tenant ON index_growth_test(tenant_id);
CREATE INDEX idx_index_growth_status ON index_growth_test(status);
CREATE INDEX idx_index_growth_created ON index_growth_test(created_at);
CREATE INDEX idx_index_growth_payload ON index_growth_test(payload);
```

**Detect**

```
SELECT
  indexrelname,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
  idx_scan
FROM pg_stat_user_indexes
WHERE relname = 'index_growth_test'
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Resolve**

Drop unused indexes only after verifying query plans and application needs:

```
DROP INDEX CONCURRENTLY idx_index_growth_payload;
```

* * *

### Scenario 3: Table bloat due to repeated update/delete

**Simulation**

```
CREATE TABLE bloat_test (
  id bigserial PRIMARY KEY,
  status text,
  payload text
);

INSERT INTO bloat_test(status, payload)
SELECT 'active', repeat(md5(random()::text), 50)
FROM generate_series(1, 1000000);

UPDATE bloat_test
SET payload = repeat(md5(random()::text), 50)
WHERE id % 2 = 0;

DELETE FROM bloat_test
WHERE id % 3 = 0;
```

**Detect**

```
SELECT
  relname,
  n_live_tup,
  n_dead_tup,
  last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'bloat_test';
```

**Resolve**

```
VACUUM (VERBOSE, ANALYZE) bloat_test;
```

For severe bloat:

```
REINDEX TABLE CONCURRENTLY bloat_test;
```

For table shrink, `VACUUM FULL` requires an exclusive lock and should be avoided during production peak.

* * *

### Scenario 4: Temp files filling storage

**How it happens**

Large sorts, hash joins, CTEs, aggregations, or poorly indexed reports spill to disk.

**Simulation**

```
CREATE TABLE temp_spill_test AS
SELECT
  generate_series AS id,
  md5(random()::text) AS val,
  repeat(md5(random()::text), 20) AS payload
FROM generate_series(1, 5000000);

SET work_mem = '1MB';

SELECT *
FROM temp_spill_test
ORDER BY payload;
```

**Detect**

```
SELECT
  datname,
  temp_files,
  pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

**Resolve**

*   Add indexes for sort/filter columns.
*   Rewrite report query.
*   Increase `work_mem` carefully for specific sessions, not globally.
*   Add query timeout.
*   Move heavy analytics to read replica.

* * *

### Scenario 5: Partition retention failure

**Simulation**

```
CREATE TABLE events_partitioned (
  id bigserial,
  event_date date NOT NULL,
  payload text
) PARTITION BY RANGE (event_date);

CREATE TABLE events_2025_01 PARTITION OF events_partitioned
FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

INSERT INTO events_partitioned(event_date, payload)
SELECT '2025-01-15', repeat(md5(random()::text), 50)
FROM generate_series(1, 1000000);
```

**Detect**

```
SELECT
  inhrelid::regclass AS partition_name,
  pg_size_pretty(pg_total_relation_size(inhrelid)) AS size
FROM pg_inherits
ORDER BY pg_total_relation_size(inhrelid) DESC;
```

**Resolve**

```
DROP TABLE events_2025_01;
```

Production prevention:

*   Automated partition creation.
*   Automated partition drop/archive.
*   Alert if old partitions exceed retention period.

* * *

3.4 Storage Full Safe Remediation
---------------------------------

### Emergency actions

1.  Stop non-critical batch jobs.
2.  Kill runaway temp-heavy queries.
3.  Drop unnecessary test/staging tables in production, if confirmed.
4.  Drop inactive logical replication slots only after confirmation.
5.  Increase RDS allocated storage.
6.  Enable or adjust storage autoscaling.
7.  Remove or reduce excessive logging.
8.  Archive/drop old partitions.

### Query to terminate storage-consuming query

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid = <pid>;
```

Use `pg_cancel_backend` first for SELECT queries:

```
SELECT pg_cancel_backend(<pid>);
```

* * *

4\. Category 2: WAL Log Growth
==============================

4.1 How WAL Log Issues Happen
-----------------------------

WAL growth can be caused by:

| Root Cause | Description |
| --- | --- |
| Inactive logical replication slot | WAL retained forever until consumer catches up or slot is dropped |
| Replica lag | WAL retained for read replica |
| DMS / CDC lag | AWS DMS or logical decoding consumer not consuming |
| Long transaction | Cleanup delayed |
| Massive write transaction | Bulk insert/update/delete generates high WAL |
| Checkpoint pressure | Frequent checkpoints increase I/O |
| Autovacuum and bloat | Heavy cleanup creates WAL |
| `wal_keep_size` too high | Excess WAL retained |
| Archiving / backup issues | WAL not cleared normally |

RDS PostgreSQL transaction log disk usage can increase when WAL files are retained because there is no active consumer, especially with inactive replication slots. AWS recommends checking replication slot state and lag when storage keeps decreasing. [![](https://www.google.com/s2/favicons?domain=https://repost.aws&sz=128)repost.aws](https://repost.aws/knowledge-center/diskfull-error-rds-postgresql?utm_source=chatgpt.com)

* * *

4.2 WAL Investigation Queries
-----------------------------

### Check WAL location

```
SELECT
  pg_current_wal_lsn() AS current_wal_lsn;
```

### Check replication slots

```
SELECT
  slot_name,
  plugin,
  slot_type,
  database,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;
```

### Check physical replication

```
SELECT
  pid,
  usename,
  application_name,
  client_addr,
  state,
  sync_state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes
FROM pg_stat_replication;
```

### Check long transactions preventing cleanup

```
SELECT
  pid,
  usename,
  datname,
  application_name,
  state,
  now() - xact_start AS xact_age,
  left(query, 500) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC;
```

### Check high write tables

```
SELECT
  schemaname,
  relname,
  n_tup_ins,
  n_tup_upd,
  n_tup_del,
  n_tup_hot_upd,
  n_dead_tup
FROM pg_stat_user_tables
ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC
LIMIT 30;
```

* * *

4.3 WAL Simulation Scenarios
----------------------------

### Scenario 1: Inactive logical replication slot retaining WAL

**Simulation**

```
SELECT pg_create_logical_replication_slot('test_inactive_slot', 'test_decoding');
```

Generate WAL:

```
CREATE TABLE wal_growth_test (
  id bigserial PRIMARY KEY,
  payload text
);

INSERT INTO wal_growth_test(payload)
SELECT repeat(md5(random()::text), 100)
FROM generate_series(1, 2000000);
```

**Detect**

```
SELECT
  slot_name,
  active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

**Resolve**

Only if confirmed unused:

```
SELECT pg_drop_replication_slot('test_inactive_slot');
```

* * *

### Scenario 2: DMS / CDC consumer lag

**How it happens**

AWS DMS replication task is stopped, broken, or slow. Logical slot remains, WAL grows.

**Detect**

```
SELECT
  slot_name,
  slot_type,
  active,
  database,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE slot_type = 'logical';
```

Also check AWS DMS task status.

**Resolve**

*   Resume DMS task.
*   Fix DMS target errors.
*   Scale DMS instance.
*   Drop slot only if replication is no longer required.

* * *

### Scenario 3: Bulk update generates high WAL

**Simulation**

```
CREATE TABLE wal_bulk_update (
  id bigserial PRIMARY KEY,
  status text,
  payload text
);

INSERT INTO wal_bulk_update(status, payload)
SELECT 'old', repeat(md5(random()::text), 20)
FROM generate_series(1, 3000000);

UPDATE wal_bulk_update
SET status = 'new',
    payload = repeat(md5(random()::text), 20);
```

**Detect**

```
SELECT
  relname,
  n_tup_upd,
  n_dead_tup
FROM pg_stat_user_tables
WHERE relname = 'wal_bulk_update';
```

**Resolve**

*   Batch updates.
*   Commit in chunks.
*   Avoid updating unchanged rows.
*   Use partition swap for large rewrites.
*   Schedule heavy writes off-peak.

* * *

### Scenario 4: Long transaction delaying WAL cleanup

**Session 1**

```
BEGIN;
SELECT count(*) FROM wal_bulk_update;
-- keep session open
```

**Session 2**

```
UPDATE wal_bulk_update
SET status = 'changed'
WHERE id <= 1000000;
```

**Detect**

```
SELECT
  pid,
  state,
  now() - xact_start AS xact_age,
  left(query, 300) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

**Resolve**

*   Ask application owner to commit/rollback.
*   Terminate only after impact review:

```
SELECT pg_terminate_backend(<pid>);
```

* * *

### Scenario 5: Excessive WAL from autovacuum cleanup

**How it happens**

Large table with many dead tuples finally gets vacuumed. WAL and I/O spike.

**Detect**

```
SELECT
  pid,
  datname,
  relid::regclass,
  phase,
  heap_blks_total,
  heap_blks_scanned,
  heap_blks_vacuumed,
  index_vacuum_count
FROM pg_stat_progress_vacuum;
```

**Resolve**

Usually do not kill autovacuum unless it is blocking critical production DDL/DML. Tune:

```
autovacuum_vacuum_scale_factor
autovacuum_analyze_scale_factor
autovacuum_vacuum_cost_limit
autovacuum_vacuum_cost_delay
```

* * *

4.4 WAL Preventive Best Practices
---------------------------------

*   Monitor replication slot retained WAL.
*   Alert on inactive replication slots.
*   Alert on WAL usage growth rate.
*   Use logical replication slot ownership documentation.
*   Use DMS task health alerts.
*   Avoid long transactions.
*   Batch bulk writes.
*   Enable query timeout and idle transaction timeout.
*   Use partitioning for heavy retention tables.
*   Consider RDS Dedicated Log Volume for supported production workloads where WAL I/O isolation is valuable. AWS notes that DLV separates transaction logs onto a dedicated storage volume for RDS PostgreSQL and can help with transaction log performance isolation. [![](https://www.google.com/s2/favicons?domain=https://repost.aws&sz=128)repost.aws](https://repost.aws/questions/QUBOrsgylZS2GdChkiOtsEiQ/amazon-rds-postgresql-wal-logs-not-clearing-high-storage-consumption?utm_source=chatgpt.com)

* * *

5\. Category 3: CPU High
========================

5.1 How CPU High Happens
------------------------

| Root Cause | Description |
| --- | --- |
| Missing index | Sequential scan on large table |
| Bad execution plan | Planner chooses expensive plan |
| High concurrency | Too many active CPU-bound queries |
| Parallel query overload | Too many parallel workers |
| Autovacuum / analyze | Maintenance consumes CPU |
| JSON / regex / function-heavy query | CPU-heavy expression processing |
| Sort/hash aggregation | CPU-heavy analytics |
| Connection storm | Many sessions competing |
| Lock waits misread as CPU | DB load high, but CPU not root cause |
| Application retry storm | Repeated failed/slow requests |

AWS RDS CPU wait events and Performance Insights can help distinguish whether sessions are consuming CPU or waiting for CPU. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/wait-event.cpu.html?utm_source=chatgpt.com)

* * *

5.2 CPU Investigation Checklist
-------------------------------

### AWS Metrics

Check:

*   `CPUUtilization`
*   `DBLoad`
*   `DBLoadCPU`
*   `DBLoadNonCPU`
*   `DatabaseConnections`
*   `ReadIOPS`
*   `WriteIOPS`
*   `FreeableMemory`
*   `SwapUsage`

If CPU is high and DB load is higher than vCPU count, the instance is saturated.

* * *

### PostgreSQL active query check

```
SELECT
  pid,
  usename,
  datname,
  application_name,
  state,
  wait_event_type,
  wait_event,
  now() - query_start AS duration,
  left(query, 1000) AS query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY duration DESC;
```

* * *

### Top queries from `pg_stat_statements`

Requires extension:

```
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Top CPU-like expensive queries:

```
SELECT
  queryid,
  calls,
  total_exec_time,
  mean_exec_time,
  rows,
  shared_blks_hit,
  shared_blks_read,
  temp_blks_written,
  left(query, 1000) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

High average runtime:

```
SELECT
  calls,
  mean_exec_time,
  max_exec_time,
  rows,
  left(query, 1000) AS query
FROM pg_stat_statements
WHERE calls > 10
ORDER BY mean_exec_time DESC
LIMIT 20;
```

* * *

### Find missing-index candidates

```
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
```

* * *

### Check CPU-heavy wait events

```
SELECT
  wait_event_type,
  wait_event,
  count(*)
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

If many active sessions have `wait_event_type IS NULL`, they may be actively running on CPU.

* * *

5.3 CPU Simulation Scenarios
----------------------------

### Scenario 1: Missing index causing full table scan

**Simulation**

```
CREATE TABLE cpu_seq_scan_test (
  id bigserial PRIMARY KEY,
  tenant_id int,
  email text,
  payload text
);

INSERT INTO cpu_seq_scan_test(tenant_id, email, payload)
SELECT
  (random() * 10000)::int,
  md5(random()::text) || '@example.com',
  repeat(md5(random()::text), 20)
FROM generate_series(1, 5000000);

ANALYZE cpu_seq_scan_test;

SELECT *
FROM cpu_seq_scan_test
WHERE email = 'notfound@example.com';
```

**Detect**

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM cpu_seq_scan_test
WHERE email = 'notfound@example.com';
```

**Resolve**

```
CREATE INDEX CONCURRENTLY idx_cpu_seq_scan_email
ON cpu_seq_scan_test(email);
```

* * *

### Scenario 2: Bad query with function on indexed column

**Simulation**

```
CREATE INDEX idx_cpu_seq_scan_email2
ON cpu_seq_scan_test(email);

SELECT *
FROM cpu_seq_scan_test
WHERE lower(email) = lower('abc@example.com');
```

**Detect**

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM cpu_seq_scan_test
WHERE lower(email) = lower('abc@example.com');
```

**Resolve**

Use functional index:

```
CREATE INDEX CONCURRENTLY idx_cpu_seq_scan_lower_email
ON cpu_seq_scan_test(lower(email));
```

Or normalize data at write time.

* * *

### Scenario 3: High concurrent CPU-heavy queries

**Simulation**

Run from multiple sessions:

```
SELECT count(*)
FROM cpu_seq_scan_test a
JOIN cpu_seq_scan_test b
  ON a.tenant_id = b.tenant_id
WHERE a.tenant_id BETWEEN 1 AND 100;
```

**Detect**

```
SELECT
  count(*) AS active_count,
  wait_event_type,
  wait_event
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type, wait_event;
```

**Resolve**

*   Cancel duplicate/reporting queries.
*   Add indexes.
*   Limit concurrency at app/PgBouncer.
*   Move analytics to read replica.
*   Add statement timeout.

* * *

### Scenario 4: JSON processing CPU spike

**Simulation**

```
CREATE TABLE cpu_json_test (
  id bigserial PRIMARY KEY,
  data jsonb
);

INSERT INTO cpu_json_test(data)
SELECT jsonb_build_object(
  'tenant_id', (random() * 1000)::int,
  'status', md5(random()::text),
  'payload', repeat(md5(random()::text), 20)
)
FROM generate_series(1, 2000000);

SELECT count(*)
FROM cpu_json_test
WHERE data->>'status' LIKE 'a%';
```

**Resolve**

```
CREATE INDEX CONCURRENTLY idx_cpu_json_status
ON cpu_json_test ((data->>'status'));
```

* * *

### Scenario 5: Application retry storm

**How it happens**

Slow DB response causes application retries. Retries multiply workload.

**Detect**

```
SELECT
  application_name,
  client_addr,
  count(*) AS sessions
FROM pg_stat_activity
GROUP BY application_name, client_addr
ORDER BY sessions DESC;
```

Check logs for repeated identical queries.

**Resolve**

*   Disable aggressive retry.
*   Add circuit breaker.
*   Add backoff and jitter.
*   Rate-limit failing endpoint.
*   Fix root query.

* * *

5.4 CPU Safe Remediation
------------------------

Immediate:

```
SELECT pg_cancel_backend(<pid>);
```

If query does not stop:

```
SELECT pg_terminate_backend(<pid>);
```

Medium-term:

*   Add missing indexes.
*   Rewrite queries.
*   Use `EXPLAIN (ANALYZE, BUFFERS)`.
*   Tune autovacuum.
*   Use read replicas.
*   Use PgBouncer transaction pooling where suitable.
*   Increase instance class only after query RCA.

Preventive:

*   Enable Performance Insights.
*   Enable `pg_stat_statements`.
*   Review top SQL weekly.
*   Alert on DB load > vCPU count.
*   Add query regression testing before release.

* * *

6\. Category 4: IOPS High
=========================

6.1 How IOPS High Happens
-------------------------

| Root Cause | Description |
| --- | --- |
| Sequential scans | Large table reads |
| Missing indexes | Excessive reads |
| Checkpoint spikes | Bursty writes |
| Heavy WAL writes | Bulk DML |
| Temp spills | Sort/hash writes |
| Autovacuum | Reads/writes table and indexes |
| Index creation | Heavy read/write I/O |
| Reindex / vacuum full | Heavy storage operations |
| Low cache hit ratio | Data not served from memory |
| Insufficient storage type / IOPS | Instance workload exceeds provisioned I/O |

* * *

6.2 IOPS Investigation Checklist
--------------------------------

AWS metrics:

*   `ReadIOPS`
*   `WriteIOPS`
*   `ReadLatency`
*   `WriteLatency`
*   `DiskQueueDepth`
*   `ReadThroughput`
*   `WriteThroughput`
*   `BurstBalance`, for burstable storage
*   `FreeableMemory`

PostgreSQL:

```
SELECT
  datname,
  blks_read,
  blks_hit,
  round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
  temp_files,
  pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY blks_read DESC;
```

Table I/O:

```
SELECT
  schemaname,
  relname,
  heap_blks_read,
  heap_blks_hit,
  idx_blks_read,
  idx_blks_hit,
  toast_blks_read,
  toast_blks_hit
FROM pg_statio_user_tables
ORDER BY heap_blks_read + idx_blks_read DESC
LIMIT 30;
```

Index usage:

```
SELECT
  schemaname,
  relname,
  indexrelname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY idx_tup_read DESC
LIMIT 30;
```

Checkpoint activity:

```
SELECT
  checkpoints_timed,
  checkpoints_req,
  checkpoint_write_time,
  checkpoint_sync_time,
  buffers_checkpoint,
  buffers_clean,
  maxwritten_clean,
  buffers_backend
FROM pg_stat_bgwriter;
```

For PostgreSQL versions with `pg_stat_wal`:

```
SELECT *
FROM pg_stat_wal;
```

PostgreSQL’s cumulative statistics system includes database, table, index, I/O, vacuum, analyze, and WAL-related statistics that are essential for identifying read/write pressure sources. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/monitoring-stats.html?utm_source=chatgpt.com)

* * *

6.3 IOPS Simulation Scenarios
-----------------------------

### Scenario 1: Read IOPS high due to missing index

**Simulation**

```
CREATE TABLE iops_read_test (
  id bigserial PRIMARY KEY,
  customer_id int,
  created_at timestamptz,
  payload text
);

INSERT INTO iops_read_test(customer_id, created_at, payload)
SELECT
  (random() * 100000)::int,
  now() - (random() * interval '365 days'),
  repeat(md5(random()::text), 30)
FROM generate_series(1, 5000000);

ANALYZE iops_read_test;

SELECT *
FROM iops_read_test
WHERE customer_id = 12345;
```

**Detect**

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM iops_read_test
WHERE customer_id = 12345;
```

**Resolve**

```
CREATE INDEX CONCURRENTLY idx_iops_read_customer_id
ON iops_read_test(customer_id);
```

* * *

### Scenario 2: Write IOPS high due to bulk insert

**Simulation**

```
CREATE TABLE iops_write_test (
  id bigserial PRIMARY KEY,
  payload text
);

INSERT INTO iops_write_test(payload)
SELECT repeat(md5(random()::text), 50)
FROM generate_series(1, 5000000);
```

**Detect**

CloudWatch:

*   `WriteIOPS`
*   `WriteThroughput`
*   `WriteLatency`
*   `DiskQueueDepth`

PostgreSQL:

```
SELECT
  relname,
  n_tup_ins
FROM pg_stat_user_tables
ORDER BY n_tup_ins DESC
LIMIT 20;
```

**Resolve**

*   Batch inserts.
*   Use `COPY` instead of row-by-row insert.
*   Drop/recreate non-critical indexes around bulk load only in maintenance window.
*   Scale storage IOPS if workload is legitimate.

* * *

### Scenario 3: Temp spill causing read/write IOPS

**Simulation**

```
SET work_mem = '1MB';

SELECT customer_id, count(*)
FROM iops_read_test
GROUP BY customer_id
ORDER BY count(*) DESC;
```

**Detect**

```
SELECT
  datname,
  temp_files,
  pg_size_pretty(temp_bytes)
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

**Resolve**

*   Add index supporting grouping/filtering.
*   Increase `work_mem` for the reporting role only.
*   Optimize query.
*   Use materialized summary tables.
*   Run analytics on replica.

* * *

### Scenario 4: Autovacuum I/O spike

**Simulation**

```
UPDATE iops_read_test
SET payload = repeat(md5(random()::text), 30)
WHERE id % 2 = 0;

VACUUM iops_read_test;
```

**Detect**

```
SELECT
  pid,
  relid::regclass,
  phase,
  heap_blks_total,
  heap_blks_scanned,
  heap_blks_vacuumed
FROM pg_stat_progress_vacuum;
```

**Resolve**

*   Do not disable autovacuum globally.
*   Tune per table:

```
ALTER TABLE iops_read_test SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01
);
```

* * *

### Scenario 5: Checkpoint write spike

**How it happens**

Large writes accumulate dirty buffers. Checkpoint flushes them heavily.

**Detect**

```
SELECT
  checkpoints_timed,
  checkpoints_req,
  checkpoint_write_time,
  checkpoint_sync_time,
  buffers_checkpoint
FROM pg_stat_bgwriter;
```

**Resolve**

Tune carefully:

```
max_wal_size
checkpoint_timeout
checkpoint_completion_target
```

For RDS, change parameter group and reboot if required.

* * *

6.4 IOPS Safe Remediation
-------------------------

Immediate:

*   Stop batch jobs.
*   Cancel runaway reports.
*   Pause index creation if causing production impact.
*   Move reads to replica.
*   Temporarily reduce application concurrency.
*   Scale storage IOPS if workload is legitimate and sustained.

Long-term:

*   Fix missing indexes.
*   Partition very large tables.
*   Tune autovacuum.
*   Reduce temp spills.
*   Use appropriate RDS storage type.
*   Add read replicas.
*   Review slow queries and top SQL.

* * *

7\. Category 5: Session High
============================

7.1 Difference Between Session High and Connection High
-------------------------------------------------------

| Term | Meaning |
| --- | --- |
| Session High | Many PostgreSQL sessions exist; may be active, idle, idle in transaction, waiting |
| Connection High | Number of DB connections approaches `max_connections` |
| Active Session High | Many sessions actively running queries |
| Idle Session High | Connections open but not doing work |
| Idle in Transaction High | Sessions started transaction and forgot to commit/rollback |
| Blocked Session High | Sessions waiting behind locks |
| PgBouncer Pool High | App cannot get pooled DB connection |

* * *

7.2 Session Investigation Queries
---------------------------------

### Session count by state

```
SELECT
  state,
  count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count(*) DESC;
```

### Session count by application

```
SELECT
  application_name,
  state,
  count(*)
FROM pg_stat_activity
GROUP BY application_name, state
ORDER BY count(*) DESC;
```

### Session count by client

```
SELECT
  client_addr,
  application_name,
  count(*) AS connections
FROM pg_stat_activity
GROUP BY client_addr, application_name
ORDER BY connections DESC;
```

### Long idle in transaction

```
SELECT
  pid,
  usename,
  datname,
  application_name,
  client_addr,
  state,
  now() - xact_start AS xact_age,
  now() - state_change AS idle_age,
  left(query, 500) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start ASC;
```

### Active session pressure

```
SELECT
  wait_event_type,
  wait_event,
  count(*)
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

* * *

7.3 Session High Simulation Scenarios
-------------------------------------

### Scenario 1: Many idle sessions

**Simulation**

Open many psql sessions and leave them idle.

Or use Python:

```
import psycopg2
import time

conns = []
for i in range(100):
    conns.append(psycopg2.connect(
        host="your-rds-endpoint",
        dbname="postgres",
        user="user",
        password="password"
    ))

time.sleep(3600)
```

**Detect**

```
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state;
```

**Resolve**

*   Fix application connection leak.
*   Use PgBouncer.
*   Set application pool limits.
*   Set TCP keepalive.
*   Terminate old idle sessions only if safe.

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle'
  AND now() - state_change > interval '1 hour'
  AND pid <> pg_backend_pid();
```

* * *

### Scenario 2: Idle in transaction sessions

**Session 1**

```
BEGIN;
SELECT * FROM some_table LIMIT 1;
-- leave open
```

**Detect**

```
SELECT
  pid,
  state,
  now() - xact_start AS xact_age,
  left(query, 300)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;
```

**Resolve**

```
SELECT pg_terminate_backend(<pid>);
```

Prevent:

```
idle_in_transaction_session_timeout = '5min'
```

* * *

### Scenario 3: Blocked sessions increasing session count

**Session 1**

```
BEGIN;
UPDATE iops_read_test
SET payload = 'blocker'
WHERE id = 1;
```

**Session 2 to N**

```
UPDATE iops_read_test
SET payload = 'blocked'
WHERE id = 1;
```

**Detect**

```
SELECT
  blocked.pid AS blocked_pid,
  blocking.pid AS blocking_pid,
  now() - blocked.query_start AS blocked_for,
  left(blocked.query, 200) AS blocked_query,
  left(blocking.query, 200) AS blocking_query
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));
```

**Resolve**

*   Commit/rollback blocker.
*   Cancel blocked queries if lower priority.
*   Terminate blocker only after approval.

* * *

### Scenario 4: Long-running report sessions

**Simulation**

```
SELECT pg_sleep(600);
```

Or heavy query:

```
SELECT count(*)
FROM iops_read_test a
JOIN iops_read_test b
ON a.customer_id = b.customer_id;
```

**Detect**

```
SELECT
  pid,
  state,
  now() - query_start AS duration,
  wait_event_type,
  wait_event,
  left(query, 500)
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_start;
```

**Resolve**

```
SELECT pg_cancel_backend(<pid>);
```

Prevent:

```
statement_timeout = '15min'
```

Or per role:

```
ALTER ROLE reporting_user SET statement_timeout = '10min';
```

* * *

### Scenario 5: Application deploy creates session storm

**How it happens**

New version increases pool size per pod/container. Example: 50 pods × pool size 30 = 1500 connections.

**Detect**

```
SELECT
  application_name,
  client_addr,
  count(*)
FROM pg_stat_activity
GROUP BY application_name, client_addr
ORDER BY count(*) DESC;
```

**Resolve**

*   Roll back deployment.
*   Reduce pool size.
*   Use PgBouncer.
*   Add deployment guardrail: total app pool size must be less than DB safe connection budget.

* * *

8\. Category 6: Connection High
===============================

8.1 How Connection Exhaustion Happens
-------------------------------------

| Root Cause | Description |
| --- | --- |
| App connection leak | Connections not closed |
| Pool too large | App pool exceeds DB capacity |
| Too many services | Aggregate pool size too high |
| Idle sessions | Connections held unnecessarily |
| Blocked queries | Sessions pile up waiting |
| Slow queries | Connections held longer |
| Retry storm | More requests create more connections |
| PgBouncer saturation | Pool waiting at PgBouncer |
| RDS `max_connections` too low | Instance class has limited memory |
| No pooling | Direct DB connection per request |

* * *

8.2 Connection Investigation
----------------------------

### Check max connections

```
SHOW max_connections;
```

### Current connections

```
SELECT count(*) AS current_connections
FROM pg_stat_activity;
```

### Connection usage percent

```
SELECT
  count(*) AS current_connections,
  setting::int AS max_connections,
  round(100.0 * count(*) / setting::int, 2) AS pct_used
FROM pg_stat_activity,
     pg_settings
WHERE name = 'max_connections'
GROUP BY setting;
```

### Connections by database/user/app

```
SELECT
  datname,
  usename,
  application_name,
  state,
  count(*) AS connections
FROM pg_stat_activity
GROUP BY datname, usename, application_name, state
ORDER BY connections DESC;
```

### Waiting sessions

```
SELECT
  wait_event_type,
  wait_event,
  count(*)
FROM pg_stat_activity
GROUP BY wait_event_type, wait_event
ORDER BY count(*) DESC;
```

* * *

8.3 Connection High Simulation Scenarios
----------------------------------------

### Scenario 1: Direct connection storm

**Simulation**

```
import psycopg2
import time

connections = []

for i in range(300):
    conn = psycopg2.connect(
        host="your-rds-endpoint",
        dbname="postgres",
        user="user",
        password="password"
    )
    connections.append(conn)

time.sleep(3600)
```

**Detect**

```
SELECT
  usename,
  application_name,
  client_addr,
  state,
  count(*)
FROM pg_stat_activity
GROUP BY usename, application_name, client_addr, state
ORDER BY count(*) DESC;
```

**Resolve**

*   Reduce app pool size.
*   Add PgBouncer.
*   Terminate old idle connections.
*   Add connection budget by service.

* * *

### Scenario 2: Connection leak

**How it happens**

Application opens connections but does not close them after errors.

**Simulation**

Use code that opens connections repeatedly without closing.

**Detect**

Look for increasing idle sessions from the same app/client:

```
SELECT
  client_addr,
  application_name,
  state,
  min(backend_start) AS oldest_connection,
  count(*)
FROM pg_stat_activity
GROUP BY client_addr, application_name, state
ORDER BY count(*) DESC;
```

**Resolve**

*   Fix connection close logic.
*   Use pool acquire/release instrumentation.
*   Add max lifetime.
*   Add idle timeout.
*   Use PgBouncer.

* * *

### Scenario 3: Blocked transaction causes connection pile-up

**Simulation**

Same as lock blocker scenario.

**Detect**

```
SELECT
  count(*) AS blocked_sessions
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

**Resolve**

*   Identify blocker.
*   Commit/rollback blocker.
*   Cancel blocked low-priority sessions.

* * *

### Scenario 4: PgBouncer pool exhaustion

**Detect in PgBouncer**

```
SHOW POOLS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW STATS;
```

Key fields:

*   `cl_active`
*   `cl_waiting`
*   `sv_active`
*   `sv_idle`
*   `maxwait`
*   `pool_mode`

**Resolve**

*   Reduce query duration.
*   Increase PgBouncer pool size only if DB can handle it.
*   Use transaction pooling where compatible.
*   Fix app-side pool.
*   Set `query_wait_timeout`.

* * *

### Scenario 5: RDS instance class too small for connection count

**Detect**

```
SHOW max_connections;
```

Check CloudWatch:

*   `DatabaseConnections`
*   `FreeableMemory`
*   `SwapUsage`
*   `CPUUtilization`

**Resolve**

*   Do not blindly increase `max_connections`.
*   Use pooling first.
*   Scale instance class if workload genuinely needs more memory/concurrency.
*   Split workloads by read replica or service.

* * *

8.4 Connection Preventive Best Practices
----------------------------------------

*   Define connection budget:

```
max_safe_db_connections =
  max_connections
  - reserved_admin_connections
  - replication_connections
  - maintenance_connections
```

Example:

```
RDS max_connections = 500
Reserve admin/maintenance = 50
Safe app budget = 450

If 10 services connect:
Average safe pool per service = 45
But production should allocate by workload priority.
```

*   Use PgBouncer.
*   Keep app pool sizes small.
*   Add `idle_in_transaction_session_timeout`.
*   Add `statement_timeout`.
*   Add retry backoff.
*   Monitor idle, active, blocked, and waiting sessions separately.
*   Alert before `DatabaseConnections` exceeds 80%.

* * *

9\. Unified Root-Cause Classification Matrix
============================================

| Symptom | Likely RCA | Confirmation |
| --- | --- | --- |
| Storage drops slowly | Data growth, bloat, indexes | table size, dead tuples |
| Storage drops rapidly | WAL, temp files, bulk load | replication slots, temp\_bytes, write activity |
| WAL grows continuously | Inactive slot / replica lag | `pg_replication_slots` |
| CPU high + active queries | Bad SQL / missing index | Performance Insights Top SQL, EXPLAIN |
| CPU high + many connections | concurrency storm | `pg_stat_activity` by app/client |
| IOPS high read | seq scan / cache miss | `pg_statio_user_tables`, EXPLAIN BUFFERS |
| IOPS high write | bulk DML / WAL / checkpoint | `pg_stat_bgwriter`, write metrics |
| Sessions high idle | app pool too large | sessions by app/state |
| Sessions high active | workload spike / slow query | active query list |
| Sessions high blocked | lock contention | `pg_blocking_pids` |
| Connections high | pool leak / no pooling | connection count by app |
| PgBouncer waiting clients | DB saturation or pool too small | `SHOW POOLS` |

* * *

10\. Agent-Based RCA Workflow
=============================

10.1 Agent Inputs
-----------------

The RCA agent should collect:

### AWS CloudWatch metrics

*   `CPUUtilization`
*   `FreeStorageSpace`
*   `DatabaseConnections`
*   `ReadIOPS`
*   `WriteIOPS`
*   `ReadLatency`
*   `WriteLatency`
*   `DiskQueueDepth`
*   `FreeableMemory`
*   `SwapUsage`
*   `TransactionLogsDiskUsage`, if available

### RDS metadata

*   Instance class
*   vCPU
*   memory
*   storage type
*   allocated storage
*   max allocated storage
*   Multi-AZ status
*   read replicas
*   parameter group
*   recent events
*   recent modifications

### PostgreSQL SQL snapshots

*   `pg_stat_activity`
*   `pg_stat_database`
*   `pg_stat_user_tables`
*   `pg_statio_user_tables`
*   `pg_stat_user_indexes`
*   `pg_replication_slots`
*   `pg_stat_replication`
*   `pg_stat_bgwriter`
*   `pg_stat_progress_vacuum`
*   `pg_stat_statements`

### Logs

*   PostgreSQL error logs
*   slow query logs
*   autovacuum logs
*   temp file logs
*   application logs
*   PgBouncer logs

* * *

10.2 Agent RCA Decision Tree
----------------------------

### Step 1: Identify primary alert

```
IF FreeStorageSpace below threshold:
    Run Storage/WAL/Temp RCA

ELSE IF CPUUtilization high:
    Run CPU RCA

ELSE IF ReadIOPS or WriteIOPS high:
    Run IOPS RCA

ELSE IF DatabaseConnections high:
    Run Session/Connection RCA

ELSE:
    Run generic DB Load RCA
```

* * *

### Step 2: Storage RCA

```
IF TransactionLogsDiskUsage increasing OR replication slot retained WAL high:
    RCA = WAL retention

ELSE IF temp_bytes increasing quickly:
    RCA = temp file spill

ELSE IF largest table/index grew recently:
    RCA = data/index growth

ELSE IF dead tuples high:
    RCA = table bloat/autovacuum lag

ELSE:
    RCA = unknown storage growth, require table-size diff
```

* * *

### Step 3: CPU RCA

```
IF DBLoadCPU high and active sessions high:
    Get Top SQL from Performance Insights / pg_stat_statements

IF Top SQL has seq scan over large table:
    RCA = missing index / bad plan

IF many sessions from same app:
    RCA = app concurrency spike

IF same query repeated:
    RCA = retry storm or endpoint issue

IF autovacuum active and CPU high:
    RCA = maintenance pressure
```

* * *

### Step 4: IOPS RCA

```
IF ReadIOPS high and cache hit ratio low:
    RCA = large reads / missing index

IF WriteIOPS high and WAL generated high:
    RCA = bulk DML / WAL pressure

IF temp_bytes high:
    RCA = temp spill

IF checkpoint_req increasing:
    RCA = checkpoint pressure

IF autovacuum running:
    RCA = vacuum I/O pressure
```

* * *

### Step 5: Session / Connection RCA

```
IF connections near max_connections:
    Group by app/client/user

IF idle sessions dominate:
    RCA = pool too large or leak

IF idle in transaction exists:
    RCA = app transaction leak

IF blocked sessions exist:
    RCA = lock blocker

IF active sessions dominate:
    RCA = slow queries or workload spike

IF PgBouncer cl_waiting high:
    RCA = pool exhaustion
```

* * *

10.3 Agent Output Format
------------------------

The agent should produce:

```
{
  "incident_type": "Storage Full / WAL Growth / CPU High / IOPS High / Connection High",
  "severity": "SEV1/SEV2/SEV3",
  "current_status": {
    "cpu_pct": 92,
    "free_storage_gb": 18,
    "connections": 430,
    "max_connections": 500,
    "read_iops": 8000,
    "write_iops": 6000
  },
  "probable_root_cause": "Inactive logical replication slot retaining WAL",
  "evidence": [
    "FreeStorageSpace dropped from 300GB to 20GB in 2 hours",
    "Replication slot dms_slot inactive",
    "Retained WAL = 260GB"
  ],
  "impacted_objects": [
    "replication slot: dms_slot",
    "database: prod"
  ],
  "recommended_immediate_actions": [
    "Confirm DMS task ownership",
    "Resume DMS task or drop unused slot",
    "Increase storage if free space below emergency threshold"
  ],
  "safe_sql": [
    "SELECT ... FROM pg_replication_slots"
  ],
  "dangerous_actions_requiring_approval": [
    "pg_drop_replication_slot",
    "pg_terminate_backend",
    "DROP TABLE",
    "VACUUM FULL"
  ],
  "prevention": [
    "Alert on inactive replication slots",
    "Alert on retained WAL > 20GB",
    "Add DMS task health monitor"
  ]
}
```

* * *

11\. Alerting and Notification Design
=====================================

11.1 Recommended CloudWatch Alarms
----------------------------------

| Metric | Warning | Critical |
| --- | --- | --- |
| FreeStorageSpace | < 20% | < 10% or < 50 GB |
| CPUUtilization | \> 75% for 15 min | \> 90% for 10 min |
| DatabaseConnections | \> 70% max | \> 85% max |
| ReadLatency | \> 20 ms sustained | \> 50 ms sustained |
| WriteLatency | \> 20 ms sustained | \> 50 ms sustained |
| DiskQueueDepth | \> 1 sustained | \> vCPU count sustained |
| ReadIOPS | \> 80% capacity | \> 95% capacity |
| WriteIOPS | \> 80% capacity | \> 95% capacity |
| FreeableMemory | < 10% | swap increasing |
| SwapUsage | \> 0 increasing | sustained growth |

AWS RDS monitoring commonly combines CloudWatch metrics, Enhanced Monitoring, database logs, Performance Insights, and RDS events for reliability and troubleshooting. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/gettingstartedguide/managing-monitoring-perf.html?utm_source=chatgpt.com)

* * *

11.2 PostgreSQL Custom Alarms
-----------------------------

Create scheduled monitoring queries for:

### Inactive replication slots

```
SELECT
  slot_name,
  active,
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes
FROM pg_replication_slots
WHERE active = false
  AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 10737418240;
```

Alert if retained WAL > 10 GB.

* * *

### Idle in transaction

```
SELECT
  pid,
  usename,
  application_name,
  now() - xact_start AS age
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '10 minutes';
```

* * *

### Blocked sessions

```
SELECT
  pid,
  pg_blocking_pids(pid) AS blockers,
  now() - query_start AS blocked_for
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0
  AND now() - query_start > interval '2 minutes';
```

* * *

### Temp file growth

```
SELECT
  datname,
  temp_files,
  temp_bytes
FROM pg_stat_database
WHERE temp_bytes > 10737418240;
```

* * *

### Long-running queries

```
SELECT
  pid,
  usename,
  application_name,
  now() - query_start AS duration,
  left(query, 500)
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '15 minutes';
```

* * *

12\. Safe Remediation Playbook
==============================

12.1 Actions Safe to Perform Quickly
------------------------------------

| Action | Risk |
| --- | --- |
| Check CloudWatch / Performance Insights | Safe |
| Run read-only diagnostic SQL | Safe |
| Cancel SELECT query with `pg_cancel_backend` | Low |
| Increase allocated storage | Usually safe, may be irreversible downward |
| Stop non-critical batch job | Low |
| Enable emergency application throttling | Low |
| Move read traffic to replica | Medium, app-dependent |

* * *

12.2 Actions Requiring Approval
-------------------------------

| Action | Why Risky |
| --- | --- |
| `pg_terminate_backend` | Rolls back transaction, may affect app |
| Drop replication slot | Can break CDC/DMS/replication |
| Drop table/index | Data or performance impact |
| `VACUUM FULL` | Exclusive lock |
| `REINDEX` without `CONCURRENTLY` | Can block writes |
| Increase `max_connections` | Can worsen memory pressure |
| Restart RDS | Causes downtime/failover |
| Change parameter group | May require reboot |

* * *

13\. Preventive Best Practices
==============================

Storage
-------

*   Enable RDS storage autoscaling.
*   Monitor storage growth rate, not only absolute free space.
*   Partition large retention-based tables.
*   Drop/archive old partitions.
*   Track largest table/index growth daily.
*   Alert on temp file growth.
*   Review logging volume.
*   Avoid unbounded audit/event tables.

WAL
---

*   Monitor replication slot lag.
*   Document every logical replication slot owner.
*   Alert if slot inactive.
*   Monitor DMS task health.
*   Avoid long transactions.
*   Batch large DML.
*   Tune checkpoint parameters carefully.
*   Use appropriate RDS storage type.

CPU
---

*   Enable Performance Insights.
*   Enable `pg_stat_statements`.
*   Review Top SQL weekly.
*   Add missing indexes.
*   Avoid function-wrapped predicates without expression indexes.
*   Use query timeouts.
*   Move reports to replicas.
*   Add load testing before major releases.

IOPS
----

*   Monitor read/write IOPS and latency together.
*   Use `EXPLAIN (ANALYZE, BUFFERS)`.
*   Tune queries causing large reads.
*   Avoid temp spills.
*   Use materialized aggregates for reports.
*   Tune autovacuum per table.
*   Choose correct RDS storage class and provisioned IOPS.

Sessions / Connections
----------------------

*   Use PgBouncer.
*   Keep app pool sizes controlled.
*   Track connection budget by service.
*   Set `idle_in_transaction_session_timeout`.
*   Set `statement_timeout`.
*   Use retry backoff and circuit breakers.
*   Alert on blocked session count.
*   Alert on idle-in-transaction sessions.

* * *

14\. Complete Scenario Matrix
=============================

Storage Full Scenarios
----------------------

| # | Scenario | Root Cause | Main Detection | Main Fix |
| --- | --- | --- | --- | --- |
| 1 | Bulk table growth | Migration/import | table size | archive/drop/increase storage |
| 2 | Index growth | Too many/large indexes | index size | drop unused indexes |
| 3 | Table bloat | update/delete churn | dead tuples | vacuum/reindex |
| 4 | Temp spill | bad sort/hash query | temp\_bytes | tune query/work\_mem |
| 5 | Partition retention failure | old data not dropped | partition size | drop/archive partition |
| 6 | WAL retained | replication slot | pg\_replication\_slots | resume/drop slot |
| 7 | Excess logs | verbose logging | RDS logs | reduce logging |

WAL Scenarios
-------------

| # | Scenario | Root Cause | Detection | Fix |
| --- | --- | --- | --- | --- |
| 1 | Inactive slot | CDC stopped | retained WAL | resume/drop slot |
| 2 | DMS lag | target slow/error | slot lag + DMS status | fix DMS |
| 3 | Bulk update | high WAL generation | write spike | batch DML |
| 4 | Long transaction | old xmin | xact age | commit/terminate |
| 5 | Replica lag | replica slow | pg\_stat\_replication | fix replica |
| 6 | Checkpoint pressure | write burst | bgwriter stats | tune checkpoint |

CPU Scenarios
-------------

| # | Scenario | Root Cause | Detection | Fix |
| --- | --- | --- | --- | --- |
| 1 | Full scan | missing index | EXPLAIN | create index |
| 2 | Function predicate | index unusable | EXPLAIN | expression index |
| 3 | Query storm | concurrency | active sessions | throttle/pool |
| 4 | JSON query | CPU expression | top SQL | expression/GIN index |
| 5 | Retry storm | app retries | same query repeated | backoff/circuit breaker |
| 6 | Bad plan | stale stats | EXPLAIN mismatch | ANALYZE/tune |

IOPS Scenarios
--------------

| # | Scenario | Root Cause | Detection | Fix |
| --- | --- | --- | --- | --- |
| 1 | Read storm | seq scan | ReadIOPS + EXPLAIN | index |
| 2 | Write storm | bulk insert/update | WriteIOPS | batch/load tuning |
| 3 | Temp spill | low work\_mem/bad query | temp\_bytes | tune query |
| 4 | Autovacuum | cleanup pressure | progress vacuum | tune autovacuum |
| 5 | Checkpoint spike | dirty buffer flush | bgwriter | checkpoint tuning |
| 6 | Index build | maintenance | active query/progress | schedule off-peak |

Session High Scenarios
----------------------

| # | Scenario | Root Cause | Detection | Fix |
| --- | --- | --- | --- | --- |
| 1 | Idle sessions | pool too large | state count | pool tuning |
| 2 | Idle transaction | app bug | idle in transaction | timeout/terminate |
| 3 | Blocked sessions | lock blocker | pg\_blocking\_pids | resolve blocker |
| 4 | Long reports | slow SQL | active duration | cancel/tune |
| 5 | Deploy storm | new pool config | app/client count | rollback/reduce pool |

Connection High Scenarios
-------------------------

| # | Scenario | Root Cause | Detection | Fix |
| --- | --- | --- | --- | --- |
| 1 | Direct storm | no pooling | connection count | PgBouncer |
| 2 | Leak | not closing conn | growing idle | app fix |
| 3 | Block pile-up | lock/slow query | blocked count | resolve blocker |
| 4 | PgBouncer wait | pool full | SHOW POOLS | tune pool/query |
| 5 | Instance limit | small class | max\_connections | pooling/scale |

* * *

15\. Recommended Production DBA Runbook Summary
===============================================

When an alert fires:

1.  **Classify the alert**
    *   Storage, WAL, CPU, IOPS, sessions, or connections.
2.  **Check AWS metrics**
    *   CloudWatch + Performance Insights.
3.  **Run PostgreSQL snapshot queries**
    *   `pg_stat_activity`
    *   `pg_stat_database`
    *   `pg_stat_user_tables`
    *   `pg_statio_user_tables`
    *   `pg_replication_slots`
    *   `pg_stat_replication`
    *   `pg_stat_bgwriter`
    *   `pg_stat_statements`
4.  **Identify primary RCA**
    *   Do not treat symptoms as root cause.
    *   Example: connection high may be caused by blocked sessions.
    *   Example: storage full may be caused by WAL retention.
    *   Example: CPU high may be caused by retry storm.
5.  **Apply safe stabilization**
    *   Cancel runaway queries.
    *   Stop batch jobs.
    *   Increase storage if emergency.
    *   Throttle application.
    *   Resume replication consumer.
    *   Fix lock blocker.
6.  **Apply permanent fix**
    *   Query tuning.
    *   Indexing.
    *   Pool correction.
    *   Autovacuum tuning.
    *   Storage scaling.
    *   Partition retention.
    *   Replication slot monitoring.
    *   Application retry/pool fixes.
7.  **Create prevention**
    *   Alarm.
    *   Runbook.
    *   RCA tag.
    *   Simulation test.
    *   Agent rule.
    *   Deployment guardrail.

* * *

16\. Final Production Recommendation
====================================

For an AWS RDS PostgreSQL production environment, implement a combined monitoring and RCA framework:

1.  **CloudWatch for infrastructure symptoms**
    *   CPU, storage, IOPS, connections, memory.
2.  **Performance Insights for workload RCA**
    *   DB load, wait events, top SQL, users, hosts.
3.  **PostgreSQL internal views for exact cause**
    *   sessions, locks, bloat, temp files, WAL, replication slots.
4.  **PgBouncer monitoring for connection pressure**
    *   waiting clients, active server connections, pool saturation.
5.  **Automated RCA agent**
    *   collect metrics
    *   classify incident
    *   identify likely root cause
    *   recommend safe action
    *   block dangerous actions unless approved

The most important production mindset is this:

**Do not resolve only the visible metric. Resolve the chain.**

Examples:

```
Storage full -> WAL retained -> inactive DMS slot -> DMS target failure
CPU high -> same query repeated -> missing index -> app retry storm
Connection high -> blocked sessions -> idle transaction blocker -> missing app commit
IOPS high -> temp spill -> bad report query -> missing index / wrong work_mem
```

That chain-based RCA approach is what prevents repeat incidents.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)