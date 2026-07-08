# RDS PostgreSQL Infra Monitoring

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:32  
**Link:** [https://chatgpt.com/share/e/6a2f8abe-3684-8322-a8fb-4166b51ed096](https://chatgpt.com/share/e/6a2f8abe-3684-8322-a8fb-4166b51ed096)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert. 

I need a complete investigation and simulation plan for the topic: 
"RDS Postgres Infra Monitoring - Memory, Instance Type, CPU, Storage, IOPS, Temp Storage, All AWS Regions,  etc. AWS RDS Postgres Environment - Notifications, Alarms, etc" 

Create a complete guide for investigating, simulating, and resolving. Include manual troubleshooting steps, analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices. 

Please cover this in depth from both manual troubleshooting steps and agent-based/root-cause analysis automation perspectives. The goal is to identify, diagnose, reproduce, and resolve production issues.

Show moreShow less

## Response:
I’ll structure this as a production-ready runbook: monitoring scope, symptoms, diagnostics, simulations, RCA automation, remediation, and prevention. I’ll verify AWS/RDS metric names and current alarm-related details from official sources before finalizing.

Thought for 17s

Below is a complete production-support guide for **RDS PostgreSQL infrastructure monitoring** covering **memory, CPU, instance type, storage, IOPS, temp storage, multi-region monitoring, alarms, notifications, investigation, simulation, remediation, and agent-based RCA automation**.

* * *

RDS PostgreSQL Infrastructure Monitoring Guide
==============================================

Memory, CPU, Instance Type, Storage, IOPS, Temp Storage, Regions, Alarms, Notifications
---------------------------------------------------------------------------------------

1\. Objective
-------------

The goal of RDS PostgreSQL infrastructure monitoring is to detect, investigate, reproduce, and resolve production issues caused by:

*   High CPU
*   Low free memory
*   Swap pressure
*   Wrong instance class
*   Storage exhaustion
*   IOPS saturation
*   High disk latency
*   Temp file growth
*   WAL / transaction log growth
*   Network throughput bottlenecks
*   Connection spikes
*   Multi-region visibility gaps
*   Missing alarms or delayed notifications
*   RDS event failures, failovers, storage modifications, and maintenance events

Amazon RDS publishes standard metrics to CloudWatch in the `AWS/RDS` namespace, and Enhanced Monitoring provides OS-level metrics in near real time through CloudWatch Logs. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-metrics.html?utm_source=chatgpt.com)

* * *

2\. Monitoring Architecture
===========================

2.1 Recommended Monitoring Layers
---------------------------------

Use **five layers** for production RDS PostgreSQL monitoring.

| Layer | Purpose | Tool |
| --- | --- | --- |
| Infrastructure metrics | CPU, memory, storage, IOPS, latency, connections | CloudWatch RDS metrics |
| OS-level metrics | Process-level CPU, memory, swap, disk, file system | RDS Enhanced Monitoring |
| Database workload | Wait events, top SQL, DB load, query bottlenecks | Performance Insights / CloudWatch Database Insights |
| PostgreSQL logs | Slow queries, temp files, checkpoints, errors | PostgreSQL logs exported to CloudWatch Logs |
| Event notifications | Failover, maintenance, storage, backup, config changes | RDS Event Subscriptions, SNS, EventBridge |

RDS PostgreSQL logs can be published to CloudWatch Logs for centralized analysis, retention, and alerting. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Procedural.UploadtoCloudWatch.html?utm_source=chatgpt.com)

* * *

3\. Key RDS PostgreSQL Infra Metrics
====================================

3.1 CPU Metrics
---------------

| Metric | Meaning | Alert Direction |
| --- | --- | --- |
| `CPUUtilization` | Percentage CPU used by the DB instance | High is bad |
| Enhanced Monitoring `cpuUtilization.user` | User-space CPU | High means workload/query CPU |
| Enhanced Monitoring `cpuUtilization.system` | Kernel/system CPU | High can mean I/O, kernel, network, context switching |
| Enhanced Monitoring `loadAverageMinute.one/five/fifteen` | OS load average | High compared to vCPU means CPU saturation |

### CPU Alert Thresholds

| Severity | Condition |
| --- | --- |
| Warning | CPU > 70% for 10–15 minutes |
| Critical | CPU > 85% for 5–10 minutes |
| Emergency | CPU > 95% for 3–5 minutes with DB load > vCPU |

### Common Root Causes

| Root Cause | Evidence |
| --- | --- |
| Inefficient queries | High CPU, top SQL visible in DB load / wait events |
| Missing index | Sequential scans, high buffer reads |
| Autovacuum or vacuum | CPU + I/O spike, autovacuum process visible |
| Connection storm | CPU + high connections |
| Under-sized instance | Sustained CPU without one clear bad SQL |
| Parallel query overload | Multiple workers, high CPU |
| Analytics/reporting workload on primary | Long-running SELECTs, high read I/O |

* * *

3.2 Memory Metrics
------------------

| Metric | Meaning |
| --- | --- |
| `FreeableMemory` | Available memory that can be reclaimed |
| Enhanced Monitoring `memory.free` | Free OS memory |
| Enhanced Monitoring `memory.cached` | File system cache |
| Enhanced Monitoring `memory.swap` | Swap usage |
| Enhanced Monitoring `processList` | Per-process memory usage |

`FreeableMemory` is a CloudWatch RDS metric, while Enhanced Monitoring provides deeper OS-level memory details. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-metrics.html?utm_source=chatgpt.com)

### Memory Alert Thresholds

| Severity | Condition |
| --- | --- |
| Warning | FreeableMemory < 15% of total RAM |
| Critical | FreeableMemory < 10% of total RAM |
| Emergency | FreeableMemory low + swap increasing + query latency rising |

### Common Root Causes

| Root Cause | Evidence |
| --- | --- |
| Too many connections | High `DatabaseConnections`, each backend consumes memory |
| High `work_mem` usage | Sort/hash queries, temp files, memory pressure |
| Large reporting queries | Long-running SELECTs, temp files |
| Autovacuum memory use | Autovacuum workers active |
| Wrong instance class | Sustained low memory even under normal workload |
| Application connection leak | Connections increasing without corresponding throughput |

* * *

3.3 Storage Metrics
-------------------

| Metric | Meaning |
| --- | --- |
| `FreeStorageSpace` | Available database storage |
| `TransactionLogsDiskUsage` | WAL / transaction log disk usage |
| `OldestReplicationSlotLag` | Replication slot retaining WAL |
| `ReadThroughput` / `WriteThroughput` | Storage throughput |
| `ReadIOPS` / `WriteIOPS` | Disk I/O operations |
| `ReadLatency` / `WriteLatency` | Disk operation latency |
| `DiskQueueDepth` | I/O operations waiting for disk |

RDS storage autoscaling can automatically increase allocated storage when free space remains low, but it has conditions and limits; AWS states that autoscaling starts when free space is less than or equal to 10% of allocated storage and the condition lasts at least five minutes. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.Autoscaling.html?utm_source=chatgpt.com)

### Storage Alert Thresholds

| Severity | Condition |
| --- | --- |
| Warning | FreeStorageSpace < 20% |
| Critical | FreeStorageSpace < 10% |
| Emergency | FreeStorageSpace < 5% or storage-full risk |
| WAL Warning | TransactionLogsDiskUsage increasing continuously |
| WAL Critical | WAL growth + replica/slot lag |

### Common Root Causes

| Root Cause | Evidence |
| --- | --- |
| Data growth | Table/index size increasing |
| Index bloat | Index size growing faster than table size |
| Table bloat | Dead tuples high, vacuum lag |
| WAL retention | Replication slot inactive or replica lag |
| Temp files | `temp_bytes`, `temp_files`, `log_temp_files` evidence |
| Long transaction | `age(backend_xmin)` high, vacuum cannot clean |
| Failed batch job | Inserts/updates created unexpected data growth |
| Storage autoscaling max reached | Allocated storage near max allocated storage |

* * *

3.4 IOPS and Latency Metrics
----------------------------

| Metric | Meaning |
| --- | --- |
| `ReadIOPS` | Read operations per second |
| `WriteIOPS` | Write operations per second |
| `ReadLatency` | Average read latency |
| `WriteLatency` | Average write latency |
| `DiskQueueDepth` | Pending disk I/O |
| `ReadThroughput` | Read MB/s |
| `WriteThroughput` | Write MB/s |

### IOPS Alert Thresholds

| Severity | Condition |
| --- | --- |
| Warning | IOPS > 70% of provisioned/baseline for 15 minutes |
| Critical | IOPS > 85% with latency increasing |
| Emergency | DiskQueueDepth rising + latency high + DB load high |

### Common Root Causes

| Root Cause | Evidence |
| --- | --- |
| Missing indexes | High read IOPS, sequential scans |
| Checkpoint pressure | Write IOPS spikes |
| Bulk writes | High WriteIOPS and WAL generation |
| Vacuum/autovacuum | Read/write I/O with autovacuum process |
| Temp file spill | Write IOPS + temp file logs |
| Storage type mismatch | gp2/gp3/io1/io2 not sized for workload |
| Read replica lag | Primary generating more WAL than replica can consume |

* * *

3.5 Temp Storage / Temporary File Monitoring
--------------------------------------------

PostgreSQL creates temporary files when sorts, hashes, materialized intermediate results, or large query operations cannot fit in memory. RDS PostgreSQL supports `log_temp_files`, which logs temp file usage after the query completes. AWS notes that this helps after completion but may not help while an active long-running query is still running. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.ManagingTempFiles.html?utm_source=chatgpt.com)

### Important Parameters

| Parameter | Purpose |
| --- | --- |
| `log_temp_files` | Logs temp files above threshold |
| `temp_file_limit` | Limits temp file usage per session |
| `work_mem` | Memory for sort/hash per operation |
| `maintenance_work_mem` | Memory for maintenance operations |
| `log_min_duration_statement` | Logs slow SQL |
| `shared_buffers` | PostgreSQL shared memory |
| `effective_cache_size` | Planner estimate of cache availability |

### Temp File Alert Conditions

| Severity | Condition |
| --- | --- |
| Warning | Sudden increase in `temp_files` or `temp_bytes` |
| Critical | Temp file growth + low FreeStorageSpace |
| Emergency | Temp files consuming storage and queries still running |

* * *

4\. Multi-Region Monitoring Strategy
====================================

For all AWS regions, monitoring must not depend on manual console checks.

4.1 Required Inventory
----------------------

Maintain a central RDS inventory table:

```
CREATE TABLE rds_instance_inventory (
    account_id text,
    region text,
    db_instance_identifier text,
    engine text,
    engine_version text,
    instance_class text,
    storage_type text,
    allocated_storage_gb numeric,
    max_allocated_storage_gb numeric,
    multi_az boolean,
    performance_insights_enabled boolean,
    enhanced_monitoring_enabled boolean,
    cloudwatch_logs_export_enabled boolean,
    environment text,
    owner_team text,
    criticality text,
    last_seen_at timestamptz default now(),
    primary key (account_id, region, db_instance_identifier)
);
```

4.2 Multi-Region Collector
--------------------------

Collector should run across:

*   All AWS accounts
*   All enabled AWS regions
*   All RDS PostgreSQL instances
*   Primary and replica instances
*   Production and non-production tagged resources

Pseudo flow:

```
For each AWS account:
  Assume role
  For each enabled region:
    describe-db-instances
    filter engine = postgres / aurora-postgresql if needed
    collect:
      instance class
      allocated storage
      max allocated storage
      storage type
      IOPS
      Multi-AZ
      backup retention
      monitoring interval
      performance insights status
      log export status
      parameter group
      option group
      tags
    store in central inventory
```

* * *

5\. Recommended CloudWatch Alarms
=================================

CloudWatch alarms should be configured per DB instance. Composite alarms can reduce noise by alerting only when multiple underlying alarms are in `ALARM` state; AWS documents that composite alarms can combine other alarms using rule expressions, and underlying alarms must generally be in the same account and region unless using cross-account observability. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/alarm-combining.html?utm_source=chatgpt.com)

5.1 Core Alarms
---------------

| Alarm | Metric | Warning | Critical |
| --- | --- | --- | --- |
| High CPU | `CPUUtilization` | \>70% 15 min | \>85% 10 min |
| Low Memory | `FreeableMemory` | <15% RAM | <10% RAM |
| Low Storage | `FreeStorageSpace` | <20% | <10% |
| Storage Emergency | `FreeStorageSpace` | — | <5% |
| High Connections | `DatabaseConnections` | \>70% max | \>85% max |
| High Read Latency | `ReadLatency` | \>20 ms | \>50 ms |
| High Write Latency | `WriteLatency` | \>20 ms | \>50 ms |
| High Disk Queue | `DiskQueueDepth` | \>2 sustained | \>5 sustained |
| High Read IOPS | `ReadIOPS` | \>70% | \>85% |
| High Write IOPS | `WriteIOPS` | \>70% | \>85% |
| WAL Growth | `TransactionLogsDiskUsage` | rising trend | rapid growth |
| Replica Lag | replica lag metric | \>60 sec | \>300 sec |

Thresholds must be tuned based on workload baseline. For OLTP production systems, trend-based alarms and anomaly detection are often safer than fixed thresholds.

* * *

5.2 Composite Alarm Examples
----------------------------

### CPU Saturation Composite

Trigger only when CPU is high and DB connections or DB load is also high:

```
ALARM("rds-prod-high-cpu")
AND
(
  ALARM("rds-prod-high-connections")
  OR
  ALARM("rds-prod-high-db-load")
)
```

### Storage Risk Composite

```
ALARM("rds-prod-low-storage")
AND
(
  ALARM("rds-prod-high-wal-usage")
  OR
  ALARM("rds-prod-high-temp-files")
  OR
  ALARM("rds-prod-storage-growth-rate-high")
)
```

### I/O Bottleneck Composite

```
ALARM("rds-prod-high-iops")
AND
(
  ALARM("rds-prod-high-read-latency")
  OR
  ALARM("rds-prod-high-write-latency")
  OR
  ALARM("rds-prod-high-disk-queue-depth")
)
```

* * *

6\. Notification Design
=======================

6.1 Notification Channels
-------------------------

Use separate channels by severity.

| Severity | Target |
| --- | --- |
| Info | Slack / Teams operational channel |
| Warning | DBA channel |
| Critical | PagerDuty / Opsgenie / on-call |
| Emergency | On-call + engineering escalation + incident channel |

RDS event notifications can be sent through SNS, and RDS events can also be consumed using EventBridge event patterns for more granular automation. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+1](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Events.overview.html?utm_source=chatgpt.com)

6.2 Required Notification Types
-------------------------------

| Event Type | Notification |
| --- | --- |
| DB instance failover | Critical |
| Storage autoscaling started/completed | Warning |
| Storage full | Emergency |
| Instance reboot | Critical |
| Maintenance pending | Warning |
| Backup failure | Critical |
| Parameter group change | Warning |
| Security group change | Critical |
| CA certificate rotation pending | Warning |
| Engine upgrade available | Info/Warning |
| RDS event subscription failure | Critical |
| Replica lag high | Critical |

* * *

7\. Manual Investigation Runbook
================================

7.1 First 5-Minute Triage
-------------------------

When an alarm fires, answer these quickly:

1.  Which instance?
2.  Which account and region?
3.  What changed recently?
4.  Is it primary or replica?
5.  Is the issue CPU, memory, storage, I/O, temp, or connection related?
6.  Is customer impact visible?
7.  Is failover, reboot, maintenance, or backup happening?
8.  Is the metric spike sudden or gradual?
9.  Are top SQL / wait events available?
10.  Is this a real issue or noisy threshold?

* * *

7.2 Standard AWS CLI Checks
---------------------------

### Describe RDS Instance

```
aws rds describe-db-instances \
  --region us-east-1 \
  --db-instance-identifier prod-postgres-01
```

Check:

*   `DBInstanceClass`
*   `AllocatedStorage`
*   `MaxAllocatedStorage`
*   `StorageType`
*   `Iops`
*   `MultiAZ`
*   `DBInstanceStatus`
*   `PendingModifiedValues`
*   `LatestRestorableTime`
*   `EnabledCloudwatchLogsExports`
*   `MonitoringInterval`
*   `PerformanceInsightsEnabled`

* * *

### Get Recent RDS Events

```
aws rds describe-events \
  --region us-east-1 \
  --source-identifier prod-postgres-01 \
  --source-type db-instance \
  --duration 1440
```

Look for:

*   Reboot
*   Failover
*   Storage modification
*   Maintenance
*   Backup
*   Configuration change
*   Low storage
*   Network issue

* * *

### Get CloudWatch Metrics

```
aws cloudwatch get-metric-statistics \
  --region us-east-1 \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=prod-postgres-01 \
  --statistics Average Maximum \
  --period 60 \
  --start-time 2026-06-15T00:00:00Z \
  --end-time 2026-06-15T01:00:00Z
```

Repeat for:

```
FreeableMemory
FreeStorageSpace
DatabaseConnections
ReadIOPS
WriteIOPS
ReadLatency
WriteLatency
DiskQueueDepth
ReadThroughput
WriteThroughput
TransactionLogsDiskUsage
NetworkReceiveThroughput
NetworkTransmitThroughput
```

* * *

8\. PostgreSQL SQL Diagnostics
==============================

8.1 Current Activity
--------------------

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
    now() - xact_start AS xact_age,
    left(query, 500) AS query
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
ORDER BY query_age DESC NULLS LAST;
```

* * *

8.2 Active Queries by Runtime
-----------------------------

```
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS runtime,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY runtime DESC;
```

* * *

8.3 Idle Transactions
---------------------

```
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    now() - xact_start AS xact_age,
    state,
    left(query, 500) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_age DESC;
```

* * *

8.4 Database Size
-----------------

```
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

* * *

8.5 Top Table Sizes
-------------------

```
SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname))) AS total_size,
    pg_size_pretty(pg_relation_size(format('%I.%I', schemaname, relname))) AS table_size,
    pg_size_pretty(pg_indexes_size(format('%I.%I', schemaname, relname))) AS index_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(format('%I.%I', schemaname, relname)) DESC
LIMIT 20;
```

* * *

8.6 Table Bloat Indicators
--------------------------

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_tuple_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 30;
```

* * *

8.7 Temp File Usage by Database
-------------------------------

```
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    deadlocks,
    blk_read_time,
    blk_write_time
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

* * *

8.8 Replication Slot WAL Retention
----------------------------------

```
SELECT
    slot_name,
    plugin,
    slot_type,
    database,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

* * *

8.9 Replication Lag
-------------------

```
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes
FROM pg_stat_replication;
```

* * *

8.10 Checkpoint Pressure
------------------------

```
SELECT
    checkpoints_timed,
    checkpoints_req,
    checkpoint_write_time,
    checkpoint_sync_time,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync
FROM pg_stat_bgwriter;
```

High `checkpoints_req` can indicate checkpoint pressure caused by heavy writes or insufficient checkpoint settings.

* * *

9\. Root-Cause Classification
=============================

9.1 CPU Root Cause Tree
-----------------------

```
High CPU
├── High active sessions?
│   ├── Yes: Check Top SQL / pg_stat_activity
│   └── No: Check background workers, autovacuum, OS/system CPU
├── High reads?
│   ├── Yes: Missing index / sequential scan / reporting query
│   └── No: CPU-heavy functions, joins, sorts, JSON processing
├── High writes?
│   ├── Yes: Batch job / checkpoint / autovacuum
│   └── No: Connection storm or under-sized instance
└── Sustained baseline growth?
    ├── Yes: instance class sizing issue
    └── No: workload spike or bad release
```

* * *

9.2 Memory Root Cause Tree
--------------------------

```
Low FreeableMemory
├── High connections?
│   ├── Yes: connection leak / pool misconfiguration
│   └── No
├── High temp files?
│   ├── Yes: sort/hash spill, work_mem issue
│   └── No
├── Long queries?
│   ├── Yes: reporting query / bad plan
│   └── No
├── Swap increasing?
│   ├── Yes: critical memory pressure
│   └── No: cache fluctuation may be normal
└── Normal workload but low memory?
    └── instance type too small
```

* * *

9.3 Storage Root Cause Tree
---------------------------

```
Low FreeStorageSpace
├── Data growth?
│   ├── Yes: identify large tables
│   └── No
├── Index growth/bloat?
│   ├── Yes: reindex plan
│   └── No
├── Dead tuples/bloat?
│   ├── Yes: vacuum issue / long transaction
│   └── No
├── WAL growth?
│   ├── Yes: replication slot / replica lag / backup issue
│   └── No
├── Temp files?
│   ├── Yes: bad query / work_mem / temp_file_limit
│   └── No
└── Autoscaling failed or max reached?
    └── increase storage / raise max allocated storage
```

* * *

9.4 IOPS Root Cause Tree
------------------------

```
High IOPS / Latency
├── Read-heavy?
│   ├── Missing index
│   ├── Sequential scan
│   ├── Reporting workload
│   └── Cache miss due to memory pressure
├── Write-heavy?
│   ├── Batch job
│   ├── Bulk update/delete
│   ├── WAL generation
│   ├── Checkpoint pressure
│   └── Autovacuum
├── Temp-heavy?
│   ├── Sort/hash spill
│   └── Bad query plan
└── Storage limit?
    ├── gp3 IOPS too low
    ├── throughput too low
    └── instance class EBS bandwidth too low
```

* * *

10\. Simulation Scenarios
=========================

Run simulations only in a **non-production RDS PostgreSQL test environment**.

* * *

Scenario 1: High CPU Due to Expensive Query
-------------------------------------------

### Purpose

Simulate CPU saturation caused by inefficient SQL.

### Setup

```
CREATE TABLE cpu_test AS
SELECT
    generate_series(1, 10000000) AS id,
    md5(random()::text) AS payload;
```

### Simulation

```
SELECT count(*)
FROM cpu_test a
JOIN cpu_test b
ON substring(a.payload, 1, 3) = substring(b.payload, 1, 3);
```

### Detect

```
SELECT pid, wait_event_type, wait_event, now() - query_start AS runtime, query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY runtime DESC;
```

### Expected Metrics

*   `CPUUtilization` high
*   DB load high
*   Top SQL visible
*   Possible high read I/O

### Remediation

*   Cancel query if safe
*   Add index if applicable
*   Rewrite query
*   Limit reporting workload
*   Move analytics to replica

```
SELECT pg_cancel_backend(<pid>);
```

Use `pg_terminate_backend()` only after impact assessment.

* * *

Scenario 2: Low Memory Due to Connection Storm
----------------------------------------------

### Purpose

Simulate too many database sessions consuming memory.

### Simulation

Open many connections using `pgbench`:

```
pgbench -h <endpoint> -U <user> -d <db> -c 300 -j 20 -T 600 -S
```

### Detect

```
SELECT
    count(*) AS total_connections,
    state
FROM pg_stat_activity
GROUP BY state;
```

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

### Expected Metrics

*   `DatabaseConnections` high
*   `FreeableMemory` low
*   CPU may increase
*   Application latency increases

### Remediation

*   Reduce app pool size
*   Enable PgBouncer
*   Kill idle connections if required
*   Tune `max_connections`
*   Fix application connection leak

* * *

Scenario 3: Storage Growth Due to Bulk Insert
---------------------------------------------

### Purpose

Simulate database storage growth.

### Setup

```
CREATE TABLE storage_growth_test (
    id bigserial primary key,
    payload text,
    created_at timestamptz default now()
);
```

### Simulation

```
INSERT INTO storage_growth_test(payload)
SELECT repeat(md5(random()::text), 50)
FROM generate_series(1, 5000000);
```

### Detect

```
SELECT
    pg_size_pretty(pg_total_relation_size('storage_growth_test')) AS total_size;
```

```
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname))
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

### Expected Metrics

*   `FreeStorageSpace` decreases
*   `WriteIOPS` increases
*   `WriteLatency` may increase

### Remediation

*   Stop bad batch
*   Archive/delete data safely
*   Increase storage
*   Enable or raise RDS storage autoscaling max threshold
*   Partition large tables

* * *

Scenario 4: WAL Growth Due to Inactive Replication Slot
-------------------------------------------------------

### Purpose

Simulate WAL retention.

### Setup

```
SELECT pg_create_logical_replication_slot('test_inactive_slot', 'test_decoding');
```

Generate writes:

```
CREATE TABLE wal_test(id bigserial, payload text);

INSERT INTO wal_test(payload)
SELECT md5(random()::text)
FROM generate_series(1, 5000000);
```

### Detect

```
SELECT
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

### Expected Metrics

*   `TransactionLogsDiskUsage` increases
*   `FreeStorageSpace` decreases

### Remediation

Drop unused slot only after confirming no consumer needs it:

```
SELECT pg_drop_replication_slot('test_inactive_slot');
```

* * *

Scenario 5: Temp File Growth Due to Sort Spill
----------------------------------------------

### Purpose

Simulate temp file creation.

### Setup

```
CREATE TABLE temp_spill_test AS
SELECT
    generate_series(1, 10000000) AS id,
    md5(random()::text) AS payload;
```

Set low memory for session:

```
SET work_mem = '1MB';
```

### Simulation

```
SELECT *
FROM temp_spill_test
ORDER BY payload;
```

### Detect

```
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes)
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

Enable temp file logging in parameter group or session where allowed:

```
SET log_temp_files = 0;
```

### Expected Metrics

*   Temp files increase
*   `WriteIOPS` increases
*   `FreeStorageSpace` may decrease
*   Query latency increases

### Remediation

*   Add indexes for sort patterns
*   Increase `work_mem` carefully
*   Set `temp_file_limit`
*   Rewrite query
*   Cancel runaway query

* * *

Scenario 6: IOPS Saturation Due to Random Reads
-----------------------------------------------

### Purpose

Simulate high read IOPS.

### Setup

```
CREATE TABLE iops_test AS
SELECT
    generate_series(1, 20000000) AS id,
    md5(random()::text) AS payload;

CREATE INDEX idx_iops_test_payload ON iops_test(payload);
```

### Simulation

Run concurrent random lookups:

```
pgbench -h <endpoint> -U <user> -d <db> -c 100 -j 20 -T 600 -f random_read.sql
```

`random_read.sql`:

```
SELECT *
FROM iops_test
WHERE id = floor(random() * 20000000)::bigint;
```

### Detect

*   CloudWatch `ReadIOPS`
*   `ReadLatency`
*   `DiskQueueDepth`
*   Performance Insights wait events

AWS documents RDS PostgreSQL wait events and their likely performance causes, which should be used when correlating CloudWatch symptoms with database-level bottlenecks. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Tuning.concepts.summary.html?utm_source=chatgpt.com)

### Remediation

*   Add correct index
*   Improve cache hit ratio
*   Increase instance memory
*   Move read workload to replica
*   Increase gp3 IOPS/throughput or move to io2
*   Tune queries

* * *

Scenario 7: Write IOPS Saturation Due to Bulk Update
----------------------------------------------------

### Setup

```
CREATE TABLE write_iops_test AS
SELECT
    generate_series(1, 10000000) AS id,
    md5(random()::text) AS payload;
```

### Simulation

```
UPDATE write_iops_test
SET payload = md5(random()::text);
```

### Expected Metrics

*   `WriteIOPS` high
*   `WriteLatency` high
*   WAL growth
*   CPU may increase
*   Replication lag may increase

### Remediation

*   Batch updates
*   Use smaller transactions
*   Schedule during low traffic
*   Increase IOPS/throughput
*   Monitor replica lag
*   Vacuum after large changes if needed

* * *

Scenario 8: Wrong Instance Type / Under-Sized Instance
------------------------------------------------------

### Purpose

Validate instance class sizing.

### Symptoms

*   Sustained CPU > 70%
*   Low memory during normal load
*   High DB load close to or above vCPU count
*   High latency without one bad query
*   Normal workload volume but poor performance

### Investigation

```
SELECT
    count(*) FILTER (WHERE state = 'active') AS active_sessions,
    count(*) AS total_sessions
FROM pg_stat_activity;
```

Check CloudWatch:

*   CPU trend for 7/14/30 days
*   FreeableMemory trend
*   Read/write latency trend
*   Connections trend
*   Storage throughput trend

### Remediation

*   Scale vertically
*   Move to memory-optimized class if memory-bound
*   Move to compute-optimized class if CPU-bound
*   Change storage from gp2/gp3 to provisioned IOPS if I/O-bound
*   Add read replica for read-heavy workloads

* * *

11\. Safe Remediation Playbook
==============================

11.1 CPU Emergency
------------------

| Action | Risk | When to Use |
| --- | --- | --- |
| Cancel bad query | Low/Medium | SELECT/reporting query |
| Terminate backend | Medium/High | Query cannot be cancelled |
| Add missing index | Medium | Confirmed bad plan |
| Scale instance | Low/Medium | Sustained CPU pressure |
| Move workload to replica | Medium | Reporting workload |
| Disable bad job | Low | Known batch caused spike |

Commands:

```
SELECT pg_cancel_backend(<pid>);
```

```
SELECT pg_terminate_backend(<pid>);
```

Use terminate only when you understand transaction impact.

* * *

11.2 Memory Emergency
---------------------

| Action | Risk | When to Use |
| --- | --- | --- |
| Kill idle sessions | Low/Medium | Connection leak |
| Reduce app pool | Low | Excess connections |
| Lower `work_mem` | Medium | Too many concurrent memory-heavy queries |
| Set `temp_file_limit` | Medium | Runaway temp usage |
| Scale instance | Low/Medium | Instance too small |
| Add PgBouncer | Medium | Connection management issue |

* * *

11.3 Storage Emergency
----------------------

| Action | Risk | When to Use |
| --- | --- | --- |
| Increase storage | Low | FreeStorageSpace critical |
| Raise max autoscaling storage | Low | Autoscaling max reached |
| Drop unused replication slot | High | Confirmed unused |
| Stop temp-heavy query | Medium | Temp files causing storage pressure |
| Delete/archive old data | High | Requires business approval |
| Reindex bloated indexes | Medium | Need space planning |
| Vacuum | Medium | Bloat cleanup, but does not always return disk to OS |

RDS storage autoscaling can be enabled by setting `MaxAllocatedStorage`; AWS notes that enabling storage autoscaling does not require reboot and takes effect without disrupting database operations. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIOPS.Autoscaling.md?utm_source=chatgpt.com)

* * *

11.4 IOPS Emergency
-------------------

| Action | Risk | When to Use |
| --- | --- | --- |
| Cancel heavy query | Low/Medium | One query causing read storm |
| Stop batch job | Low/Medium | Bulk write causing saturation |
| Increase gp3 IOPS/throughput | Low | Storage config bottleneck |
| Move to io2 | Medium | Sustained I/O critical workload |
| Add indexes | Medium | Read I/O due to scans |
| Batch writes | Medium | Write spikes |

* * *

12\. Agent-Based RCA Workflow
=============================

12.1 Agent Components
---------------------

| Agent | Responsibility |
| --- | --- |
| Metric Collector Agent | Pull CloudWatch metrics across accounts/regions |
| RDS Inventory Agent | Collect instance config and tags |
| Log Analyzer Agent | Analyze PostgreSQL logs in CloudWatch Logs |
| SQL Diagnostic Agent | Run safe read-only SQL diagnostics |
| RCA Classifier Agent | Classify issue type and confidence |
| Remediation Advisor Agent | Suggest safe actions |
| Notification Agent | Send alert summaries |
| Simulation Agent | Run controlled test scenarios in non-prod |
| Post-Incident Agent | Generate RCA report and preventive actions |

* * *

12.2 Agent RCA Input
--------------------

```
{
  "account_id": "123456789012",
  "region": "us-east-1",
  "db_instance_identifier": "prod-postgres-01",
  "alarm_name": "rds-prod-low-storage-critical",
  "metric_name": "FreeStorageSpace",
  "alarm_start_time": "2026-06-15T10:15:00Z",
  "environment": "prod",
  "severity": "critical"
}
```

* * *

12.3 Agent RCA Workflow
-----------------------

```
1. Receive alarm
2. Identify DB instance, account, region, environment, owner
3. Fetch last 6h / 24h CloudWatch metrics
4. Fetch RDS events
5. Fetch instance config
6. Check recent changes:
   - deployment
   - parameter change
   - instance modification
   - storage modification
   - failover
7. Run safe SQL diagnostics
8. Analyze PostgreSQL logs
9. Correlate:
   - metric spike
   - SQL activity
   - logs
   - RDS events
   - deployment/change data
10. Classify root cause
11. Assign confidence score
12. Suggest immediate remediation
13. Suggest preventive action
14. Notify incident channel
15. Store RCA result
```

* * *

12.4 RCA Classification Output
------------------------------

```
{
  "incident_type": "STORAGE_PRESSURE",
  "root_cause_category": "TEMP_FILE_GROWTH",
  "confidence": 0.91,
  "primary_evidence": [
    "FreeStorageSpace dropped from 180GB to 42GB in 40 minutes",
    "pg_stat_database temp_bytes increased by 130GB",
    "CloudWatch WriteIOPS increased 4x",
    "Top active query contains ORDER BY on large unindexed column"
  ],
  "impact": "High query latency and risk of storage exhaustion",
  "recommended_immediate_actions": [
    "Cancel temp-heavy query if business-approved",
    "Increase allocated storage if free space < 10%",
    "Set temporary temp_file_limit for offending role"
  ],
  "recommended_preventive_actions": [
    "Add index for sort/filter pattern",
    "Enable log_temp_files",
    "Create temp_bytes anomaly alarm",
    "Review work_mem and reporting workload isolation"
  ]
}
```

* * *

13\. Agent Diagnostic SQL Library
=================================

Agents should run only safe read-only queries unless explicitly approved.

13.1 Connection Summary
-----------------------

```
SELECT
    application_name,
    client_addr,
    state,
    count(*) AS connections
FROM pg_stat_activity
GROUP BY application_name, client_addr, state
ORDER BY connections DESC;
```

13.2 Wait Event Summary
-----------------------

```
SELECT
    wait_event_type,
    wait_event,
    count(*) AS sessions
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY wait_event_type, wait_event
ORDER BY sessions DESC;
```

13.3 Long Transactions
----------------------

```
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - xact_start AS xact_age,
    wait_event_type,
    wait_event,
    left(query, 500) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_age DESC
LIMIT 20;
```

13.4 Temp Usage
---------------

```
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

13.5 Top Relations by Size
--------------------------

```
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    c.relkind,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 30;
```

13.6 Replication Slot Risk
--------------------------

```
SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE restart_lsn IS NOT NULL
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

* * *

14\. CloudWatch Logs Insights Queries
=====================================

14.1 Slow Queries
-----------------

```
fields @timestamp, @message
| filter @message like /duration:/
| sort @timestamp desc
| limit 100
```

14.2 Temp File Logs
-------------------

```
fields @timestamp, @message
| filter @message like /temporary file/
| sort @timestamp desc
| limit 100
```

14.3 Errors
-----------

```
fields @timestamp, @message
| filter @message like /ERROR:/ or @message like /FATAL:/ or @message like /PANIC:/
| sort @timestamp desc
| limit 100
```

14.4 Connection Failures
------------------------

```
fields @timestamp, @message
| filter @message like /remaining connection slots/
   or @message like /too many connections/
   or @message like /FATAL:/
| sort @timestamp desc
| limit 100
```

AWS recommends configuring PostgreSQL logging parameters and exporting logs to CloudWatch before using CloudWatch Logs Insights to analyze RDS PostgreSQL logs. [![](https://www.google.com/s2/favicons?domain=https://repost.aws&sz=128)Repost](https://repost.aws/knowledge-center/analyze-cloudwatch-logs-rds-postgresql?utm_source=chatgpt.com)

* * *

15\. Preventive Best Practices
==============================

15.1 Monitoring Coverage
------------------------

Every production RDS PostgreSQL instance should have:

*   CloudWatch alarms
*   Enhanced Monitoring enabled
*   Performance Insights / Database Insights enabled where available
*   PostgreSQL logs exported to CloudWatch Logs
*   RDS event notifications
*   SNS / PagerDuty / Slack routing
*   Dashboard per environment
*   Cross-region inventory
*   Weekly trend review

* * *

15.2 Alarm Governance
---------------------

Maintain alarm definitions as code using Terraform, CloudFormation, CDK, or internal deployment automation.

Minimum alarm metadata:

```
alarm_name: rds-prod-high-cpu
metric: CPUUtilization
namespace: AWS/RDS
severity: critical
threshold: 85
period: 60
evaluation_periods: 10
owner_team: dba
runbook_url: https://internal/runbooks/rds/high-cpu
notification_target: pagerduty-prod-db
```

* * *

15.3 Storage Governance
-----------------------

*   Enable storage autoscaling for production.
*   Set max allocated storage high enough for emergency growth.
*   Monitor `FreeStorageSpace`.
*   Monitor `TransactionLogsDiskUsage`.
*   Monitor replication slots.
*   Monitor temp file usage.
*   Review top table/index growth weekly.
*   Archive old data.
*   Partition large time-series tables.
*   Avoid large unbounded deletes during peak hours.

* * *

15.4 Memory Governance
----------------------

*   Use PgBouncer where connection count is high.
*   Avoid excessive `max_connections`.
*   Keep app connection pools bounded.
*   Use role-level `statement_timeout`.
*   Use `idle_in_transaction_session_timeout`.
*   Review `work_mem` carefully because it applies per sort/hash operation, not globally.
*   Use `temp_file_limit` for reporting roles.

Example:

```
ALTER ROLE reporting_user SET statement_timeout = '15min';
ALTER ROLE reporting_user SET temp_file_limit = '20GB';
ALTER ROLE app_user SET idle_in_transaction_session_timeout = '5min';
```

* * *

15.5 CPU Governance
-------------------

*   Review top SQL weekly.
*   Enable `pg_stat_statements`.
*   Track query fingerprints.
*   Add indexes based on real query patterns.
*   Separate OLTP and analytics workloads.
*   Use read replicas for heavy reads.
*   Avoid uncontrolled parallelism.
*   Test query plans before release.

* * *

15.6 IOPS Governance
--------------------

*   Use gp3 with explicitly configured IOPS/throughput for predictable workloads.
*   Use io2 for high-critical, high-I/O workloads.
*   Monitor latency, not just IOPS.
*   Review checkpoint behavior.
*   Batch large writes.
*   Avoid full-table updates in one transaction.
*   Use index-only scans where possible.

* * *

16\. Production Dashboard Design
================================

16.1 Executive Health Dashboard
-------------------------------

Show:

*   Region
*   Account
*   DB identifier
*   Environment
*   Status
*   CPU
*   Free memory
*   Free storage
*   Connections
*   Read/write latency
*   IOPS
*   Replica lag
*   Active alarms
*   Last RDS event

16.2 DBA Deep-Dive Dashboard
----------------------------

Panels:

1.  CPU utilization
2.  Freeable memory
3.  Swap usage from Enhanced Monitoring
4.  Database connections
5.  Active sessions
6.  Read/write IOPS
7.  Read/write latency
8.  Disk queue depth
9.  Free storage
10.  WAL usage
11.  Temp bytes/files
12.  Top wait events
13.  Top SQL
14.  RDS events
15.  PostgreSQL errors
16.  Slow query count

* * *

17\. Incident Response Template
===============================

Incident Summary
----------------

```
Incident ID:
Environment:
Account:
Region:
RDS Instance:
Start Time:
Detected By:
Severity:
Customer Impact:
Current Status:
```

Metric Evidence
---------------

```
CPU:
Memory:
Storage:
IOPS:
Latency:
Connections:
WAL:
Temp Files:
Replica Lag:
```

Database Evidence
-----------------

```
Top active queries:
Top wait events:
Long transactions:
Replication slots:
Large tables:
Temp usage:
Recent errors:
```

Root Cause
----------

```
Primary category:
Detailed cause:
Confidence:
Supporting evidence:
```

Actions Taken
-------------

```
Immediate action:
DB action:
AWS action:
Application action:
Customer communication:
```

Prevention
----------

```
Alarm changes:
Query/index changes:
Capacity changes:
Runbook updates:
Automation changes:
Owner:
Due date:
```

* * *

18\. End-to-End Example RCA
===========================

Alarm
-----

```
Alarm: rds-prod-low-storage-critical
Metric: FreeStorageSpace
Instance: prod-postgres-01
Region: us-east-1
Severity: Critical
```

Investigation
-------------

CloudWatch:

```
FreeStorageSpace dropped from 220GB to 45GB in 35 minutes.
WriteIOPS increased from 1,500 to 9,000.
TransactionLogsDiskUsage stable.
CPU increased from 40% to 78%.
```

SQL:

```
SELECT datname, temp_files, pg_size_pretty(temp_bytes)
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

Result:

```
appdb temp_bytes = 160GB
```

Activity:

```
SELECT pid, now() - query_start AS runtime, left(query, 500)
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY runtime DESC;
```

Result:

```
Large ORDER BY query running for 42 minutes.
```

RCA
---

```
Root Cause:
A reporting query performed a large sort on an unindexed expression.
The query spilled to disk and generated large temporary files, rapidly reducing free storage.

Category:
TEMP_FILE_GROWTH

Confidence:
High
```

Immediate Remediation
---------------------

```
1. Confirmed query was reporting-only.
2. Cancelled backend using pg_cancel_backend.
3. Increased storage because free space was below emergency threshold.
4. Enabled temp file logging threshold.
5. Added temp_file_limit for reporting role.
```

Preventive Actions
------------------

```
1. Add index for reporting filter/sort.
2. Move reporting query to read replica.
3. Add CloudWatch Logs Insights alert for temp file log entries.
4. Add anomaly alarm on temp_bytes custom metric.
5. Add query timeout for reporting user.
```

* * *

19\. Minimum Production Readiness Checklist
===========================================

| Area | Required Control |
| --- | --- |
| CPU | High CPU warning and critical alarms |
| Memory | FreeableMemory and swap monitoring |
| Storage | FreeStorageSpace alarm and storage autoscaling |
| WAL | TransactionLogsDiskUsage and replication slot monitoring |
| IOPS | Read/write IOPS and latency alarms |
| Connections | DatabaseConnections alarm |
| Temp files | `log_temp_files`, temp usage tracking |
| Logs | PostgreSQL logs exported to CloudWatch |
| Events | RDS event notifications enabled |
| Regions | All-region RDS inventory collector |
| Dashboards | Per-region and global dashboard |
| Automation | RCA agent workflow |
| Runbooks | Linked from every alarm |
| Testing | Non-prod simulation scenarios |
| Review | Weekly capacity and trend review |

* * *

20\. Final Recommended Implementation Plan
==========================================

Phase 1: Visibility
-------------------

*   Build all-region RDS inventory.
*   Enable CloudWatch logs export.
*   Enable Enhanced Monitoring.
*   Enable Performance Insights / Database Insights where available.
*   Create standard dashboards.

Phase 2: Alarms and Notifications
---------------------------------

*   Add CPU, memory, storage, IOPS, latency, connection alarms.
*   Add RDS event subscriptions.
*   Route by severity.
*   Add composite alarms to reduce noise.
*   Add runbook links.

Phase 3: RCA Automation
-----------------------

*   Build metric collector.
*   Build SQL diagnostic agent.
*   Build log analyzer.
*   Build root-cause classifier.
*   Store RCA evidence in PostgreSQL.
*   Send structured incident summaries.

Phase 4: Simulation and Drill
-----------------------------

Run drills for:

*   CPU saturation
*   Memory pressure
*   Connection storm
*   Storage growth
*   WAL retention
*   Temp file growth
*   IOPS saturation
*   Wrong instance sizing
*   Notification failure
*   Multi-region visibility gap

Phase 5: Preventive Governance
------------------------------

*   Weekly capacity review.
*   Monthly alarm tuning.
*   Quarterly failover and storage drills.
*   Query performance review before release.
*   Enforce DB production checklist for schema/data changes.
*   Maintain per-instance ownership and escalation mapping.

This gives your DBA/support team both a **manual production runbook** and a foundation for an **agent-based RCA system** for RDS PostgreSQL infrastructure monitoring.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)