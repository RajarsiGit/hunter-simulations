# RDS PostgreSQL Investigation Guide

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:23  
**Link:** [https://chatgpt.com/share/e/6a4c970e-74bc-83ee-9a0b-71e3c380f834](https://chatgpt.com/share/e/6a4c970e-74bc-83ee-9a0b-71e3c380f834)  

## Prompt:
Act as a Senior PostgreSQL DBA and AWS RDS PostgreSQL production support expert. 

I need a complete investigation and simulation plan for the topic: "RDS Postgres - Autovacuum & Bloat, Replication Issues, Temp File Explosion, Monitoring Blind Spots(Cloudwatch, DB Insights etc) - AWS RDS Postgres Environment" 

Create a complete guide for investigating, simulating, and resolving. Include manual troubleshooting steps, analysis, root-cause classification, reproducible simulation scenarios, agent-based RCA workflows, safe remediation steps, and preventive best practices. 

Please cover this in depth from both manual troubleshooting steps and agent-based/root-cause analysis automation perspectives. The goal is to identify, diagnose, reproduce, and resolve production issues. 

Create Multiple scenarios for each Category

Show moreShow less

## Response:
I’ll structure this as an operations runbook plus a simulation/RCA playbook, with separate sections for autovacuum/bloat, replication, temp file explosions, and monitoring blind spots. I’ll anchor the PostgreSQL/RDS-specific behavior against current official docs where it affects production decisions.

Thought for 5s

Below is a production-grade investigation, simulation, and remediation guide for:

**RDS PostgreSQL – Autovacuum & Bloat, Replication Issues, Temp File Explosion, and Monitoring Blind Spots in AWS RDS PostgreSQL**

This is written as a **Senior DBA + production support runbook** and also includes **agent-based RCA automation workflows**.

* * *

1\. Production Support Mindset
==============================

For these issue categories, do not investigate each symptom independently.

In RDS PostgreSQL, these problems often chain together:

```
Heavy UPDATE / DELETE workload
        ↓
Dead tuples increase
        ↓
Autovacuum cannot keep up
        ↓
Table/index bloat increases
        ↓
Queries become slower
        ↓
More temp files, higher IOPS, higher CPU
        ↓
Replica replay slows
        ↓
WAL retention increases
        ↓
Storage pressure / replica lag / monitoring alert gaps
```

PostgreSQL autovacuum is required to reclaim dead tuples, keep statistics fresh, and prevent transaction ID wraparound. Even if autovacuum is disabled, PostgreSQL can still launch anti-wraparound vacuum workers. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL+1](https://www.postgresql.org/docs/current/routine-vacuuming.html?utm_source=chatgpt.com)

For RDS PostgreSQL, you must combine:

1.  **CloudWatch metrics**
2.  **RDS Enhanced Monitoring**
3.  **Performance Insights / CloudWatch Database Insights**
4.  **PostgreSQL catalog views**
5.  **PostgreSQL logs**
6.  **Application deployment/change timeline**
7.  **Replica health and WAL metrics**

AWS recommends using CloudWatch metrics such as `ReplicaLag` for RDS PostgreSQL read replicas, and log analysis for tuning replication-related behavior. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PostgreSQL.Replication.ReadReplicas.Monitor.html?utm_source=chatgpt.com)

* * *

2\. Core Diagnostic Checklist
=============================

Use this checklist before deep-diving into any one category.

2.1 First 5-Minute Triage
-------------------------

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
ORDER BY temp_bytes DESC;
```

Check active workload:

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
WHERE state <> 'idle'
ORDER BY query_age DESC;
```

Check long transactions:

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
    left(query, 500) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC;
```

Check vacuum progress:

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

PostgreSQL exposes `pg_stat_progress_vacuum` to show active VACUUM/autovacuum progress, including current phase and scanned/vacuumed blocks. [![](https://www.google.com/s2/favicons?domain=https://www.postgresscripts.com&sz=128)PostgreSQL Scripts](https://www.postgresscripts.com/post/monitor-postgresql-vacuum-progress-pg-stat-progress-vacuum/?utm_source=chatgpt.com)

* * *

3\. Category A – Autovacuum & Bloat
===================================

3.1 Conceptual Overview
-----------------------

Autovacuum performs three major functions:

1.  Removes dead tuples left by UPDATE/DELETE.
2.  Runs ANALYZE to refresh planner statistics.
3.  Prevents transaction ID and multixact wraparound.

Bloat occurs when dead tuples are not removed quickly enough, or when vacuum cannot shrink/reuse space effectively.

In RDS PostgreSQL, autovacuum behavior is controlled through the DB parameter group and table-level storage parameters. Some settings require reboot if static; others can be changed dynamically depending on parameter type.

* * *

3.2 Common Symptoms
-------------------

| Symptom | Possible Meaning |
| --- | --- |
| Table size keeps increasing | Dead tuples, table bloat, index bloat |
| Queries slower over time | Bloated indexes/table scans, stale statistics |
| High CPU | More pages scanned for same logical data |
| High read IOPS | Bloated table/index access |
| High write IOPS | Heavy UPDATE/DELETE + vacuum/index cleanup |
| Replica lag | WAL generated by vacuum or write-heavy workload |
| Storage full | Bloat + retained WAL + temp files |
| Autovacuum visible but slow | Cost delay too conservative or worker saturation |
| Autovacuum not running | Threshold not reached, disabled per table, workers busy |
| Wraparound warning | Very old transaction age, vacuum blocked |

* * *

3.3 Investigation Queries
-------------------------

### 3.3.1 Database-Level Dead Tuple and Vacuum Overview

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n_dead_tup DESC
LIMIT 50;
```

### 3.3.2 Tables Not Vacuumed Recently

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    now() - last_autovacuum AS since_last_autovacuum
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  AND n_dead_tup > 10000
ORDER BY last_autovacuum NULLS FIRST, n_dead_tup DESC;
```

### 3.3.3 Transaction ID Wraparound Risk

```
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    2000000000 - age(datfrozenxid) AS tx_remaining_before_wraparound
FROM pg_database
ORDER BY xid_age DESC;
```

Table-level:

```
SELECT
    c.oid::regclass AS table_name,
    age(c.relfrozenxid) AS xid_age,
    c.relpages,
    c.reltuples
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY xid_age DESC
LIMIT 50;
```

### 3.3.4 Autovacuum Workers Currently Running

```
SELECT
    pid,
    datname,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS runtime,
    left(query, 500) AS query
FROM pg_stat_activity
WHERE query ILIKE '%autovacuum%'
ORDER BY query_start;
```

### 3.3.5 Estimate Table and Index Size

```
SELECT
    schemaname,
    relname,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_indexes_size(relid)) AS index_size,
    n_live_tup,
    n_dead_tup
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 50;
```

* * *

3.4 Root-Cause Classification – Autovacuum & Bloat
--------------------------------------------------

| RCA Class | Description | Evidence |
| --- | --- | --- |
| Heavy churn table | Frequent UPDATE/DELETE creates dead tuples faster than vacuum can clean | High `n_dead_tup`, high UPDATE/DELETE rate |
| Autovacuum threshold too high | Large tables need too many changes before vacuum triggers | `last_autovacuum` old, dead tuples high |
| Worker starvation | All autovacuum workers busy on large tables | `pg_stat_activity`, `pg_stat_progress_vacuum` |
| Cost delay too conservative | Vacuum runs but progresses slowly | Long vacuum duration, low I/O pressure |
| Long transaction blocking cleanup | Old snapshot prevents tuple removal | Long `xact_start`, `backend_xmin` |
| Idle in transaction | App holds transaction open | `state='idle in transaction'` |
| Index bloat | Index larger than table or degraded index scans | Large `pg_indexes_size`, slow index scans |
| Stale statistics | Planner chooses bad plans | Old `last_analyze`, plan row estimate mismatch |
| Wraparound pressure | Old xid age causes aggressive vacuum | High `age(datfrozenxid)` |
| Bulk delete/update | One-time batch caused bloat | Deployment/job timeline |

* * *

3.5 Scenario A1 – Autovacuum Cannot Keep Up With Heavy UPDATE Workload
----------------------------------------------------------------------

### How It Happens

A table receives continuous updates. Autovacuum starts, but dead tuples are generated faster than vacuum removes them.

### Simulation

Create test table:

```
CREATE TABLE av_bloat_test (
    id bigserial PRIMARY KEY,
    tenant_id int,
    status text,
    payload text,
    updated_at timestamptz DEFAULT now()
);

INSERT INTO av_bloat_test (tenant_id, status, payload)
SELECT
    (random() * 100)::int,
    'ACTIVE',
    repeat(md5(random()::text), 20)
FROM generate_series(1, 1000000);

ANALYZE av_bloat_test;
```

Generate churn:

```
DO $$
DECLARE
    i int;
BEGIN
    FOR i IN 1..100 LOOP
        UPDATE av_bloat_test
        SET payload = repeat(md5(random()::text), 20),
            updated_at = now()
        WHERE id % 10 = 0;
        COMMIT;
    END LOOP;
END $$;
```

### Detect

```
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_all_tables
WHERE relname = 'av_bloat_test';
```

### Identify Root Cause

```
SELECT
    relname,
    n_tup_upd,
    n_tup_del,
    n_dead_tup,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'av_bloat_test';
```

### Safe Remediation

First:

```
VACUUM (VERBOSE, ANALYZE) av_bloat_test;
```

If bloat is severe and downtime is acceptable:

```
VACUUM FULL av_bloat_test;
```

But `VACUUM FULL` takes an exclusive lock and rewrites the table. Avoid during production traffic.

Safer options:

```
REINDEX INDEX CONCURRENTLY index_name;
```

Or use online table rebuild tooling such as `pg_repack` where available and approved.

### Prevention

Tune table-level autovacuum:

```
ALTER TABLE av_bloat_test SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_analyze_threshold = 5000
);
```

For very large/high-churn tables, prefer low scale factor and meaningful fixed threshold.

* * *

3.6 Scenario A2 – Long Transaction Prevents Dead Tuple Cleanup
--------------------------------------------------------------

### How It Happens

A long-running transaction keeps an old snapshot. Autovacuum can scan the table but cannot remove tuples that may still be visible to that transaction.

### Simulation

Session 1:

```
BEGIN;
SELECT count(*) FROM av_bloat_test;
-- Keep this transaction open
```

Session 2:

```
UPDATE av_bloat_test
SET status = 'UPDATED'
WHERE id <= 500000;

VACUUM (VERBOSE, ANALYZE) av_bloat_test;
```

### Detect

```
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - xact_start AS xact_age,
    backend_xmin,
    left(query, 300) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start;
```

### Safe Remediation

If the long transaction is safe to terminate:

```
SELECT pg_terminate_backend(<pid>);
```

Use this only after confirming the session owner, application, and impact.

### Prevention

Set timeouts:

```
ALTER DATABASE appdb SET idle_in_transaction_session_timeout = '5min';
ALTER DATABASE appdb SET statement_timeout = '15min';
```

Application-side:

*   Avoid holding transactions across API calls.
*   Avoid transactions during user think time.
*   Commit in batches.
*   Use read-only replicas carefully for long analytical queries.

* * *

3.7 Scenario A3 – Autovacuum Worker Starvation
----------------------------------------------

### How It Happens

Several large tables become eligible for vacuum at once. PostgreSQL has limited autovacuum workers, so some tables wait. PostgreSQL documentation notes that if several large tables become eligible together, all workers may be occupied for a long time. [![](https://www.google.com/s2/favicons?domain=https://www.postgresql.org&sz=128)PostgreSQL](https://www.postgresql.org/docs/current/routine-vacuuming.html?utm_source=chatgpt.com)

### Detect

```
SHOW autovacuum_max_workers;
SHOW autovacuum_naptime;
SHOW autovacuum_vacuum_cost_delay;
SHOW autovacuum_vacuum_cost_limit;
```

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

Find tables waiting:

```
SELECT
    relname,
    n_dead_tup,
    last_autovacuum,
    autovacuum_count
FROM pg_stat_user_tables
WHERE n_dead_tup > 100000
ORDER BY n_dead_tup DESC;
```

### Remediation

Increase worker capacity cautiously through parameter group:

```
autovacuum_max_workers
autovacuum_vacuum_cost_limit
autovacuum_vacuum_cost_delay
maintenance_work_mem
```

For emergency cleanup:

```
VACUUM (ANALYZE) high_churn_table;
```

Do not blindly run `VACUUM FULL` on many production tables.

* * *

3.8 Scenario A4 – Index Bloat After Repeated Updates
----------------------------------------------------

### How It Happens

Indexes accumulate dead entries after frequent updates. Table may look acceptable, but index size grows and query performance degrades.

### Detect

```
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 50;
```

### Remediation

Use concurrent reindexing:

```
REINDEX INDEX CONCURRENTLY index_name;
```

Or for all indexes on table:

```
REINDEX TABLE CONCURRENTLY table_name;
```

### Prevention

*   Avoid unnecessary indexes on high-churn tables.
*   Use partial indexes where possible.
*   Avoid updating indexed columns frequently.
*   Use fillfactor for hot update-heavy tables:

```
ALTER TABLE av_bloat_test SET (fillfactor = 80);
VACUUM FULL av_bloat_test; -- requires maintenance window
```

* * *

3.9 Scenario A5 – Stale Statistics Cause Bad Query Plans
--------------------------------------------------------

### How It Happens

Autovacuum or autoanalyze does not run frequently enough. Planner estimates become wrong.

### Detect

```
SELECT
    schemaname,
    relname,
    n_mod_since_analyze,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_mod_since_analyze DESC
LIMIT 50;
```

Check plan:

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM av_bloat_test
WHERE tenant_id = 10
  AND status = 'ACTIVE';
```

### Remediation

```
ANALYZE av_bloat_test;
```

For skewed data:

```
ALTER TABLE av_bloat_test ALTER COLUMN tenant_id SET STATISTICS 1000;
ANALYZE av_bloat_test;
```

### Prevention

Table-level autoanalyze tuning:

```
ALTER TABLE av_bloat_test SET (
    autovacuum_analyze_scale_factor = 0.01,
    autovacuum_analyze_threshold = 5000
);
```

* * *

4\. Category B – Replication Issues
===================================

4.1 Conceptual Overview
-----------------------

RDS PostgreSQL read replicas use physical streaming replication. Replication issues usually appear as:

*   Replica lag
*   WAL retention growth
*   Replica query cancellation
*   Slow replay
*   Read-after-write inconsistency
*   Cross-region replication delay
*   Storage growth on primary due to retained WAL

AWS documents `ReplicaLag` as the CloudWatch metric for monitoring RDS PostgreSQL read replica lag. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PostgreSQL.Replication.ReadReplicas.Monitor.html?utm_source=chatgpt.com)

For cross-region replicas, RDS creates a physical replication slot and CloudWatch metrics such as `Oldest Replication Slot Lag` and `Transaction Logs Disk Usage` can show retained WAL pressure. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.Monitoring.html?utm_source=chatgpt.com)

* * *

4.2 Key CloudWatch Metrics
--------------------------

| Metric | Meaning |
| --- | --- |
| `ReplicaLag` | Replica delay in seconds |
| `TransactionLogsDiskUsage` | WAL disk usage |
| `OldestReplicationSlotLag` | Lag of oldest replication slot |
| `WriteIOPS` | High write workload |
| `WriteThroughput` | WAL/data write pressure |
| `ReadIOPS` | Replica read pressure |
| `CPUUtilization` | Replay/query pressure |
| `FreeStorageSpace` | WAL/temp/bloat storage pressure |
| `NetworkReceiveThroughput` | Replica receiving WAL |
| `NetworkTransmitThroughput` | Primary sending WAL |

* * *

4.3 PostgreSQL Replication Queries
----------------------------------

On primary:

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
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

Replication slots:

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
FROM pg_replication_slots;
```

On replica:

```
SELECT
    pg_is_in_recovery() AS is_replica,
    now() - pg_last_xact_replay_timestamp() AS replay_delay,
    pg_last_wal_receive_lsn(),
    pg_last_wal_replay_lsn(),
    pg_size_pretty(
        pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
    ) AS receive_replay_gap;
```

Replica activity:

```
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_age,
    left(query, 500) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;
```

* * *

4.4 Root-Cause Classification – Replication
-------------------------------------------

| RCA Class | Description | Evidence |
| --- | --- | --- |
| Primary write surge | WAL generated faster than replica can consume | High WriteIOPS, WAL bytes, lag |
| Replica CPU bottleneck | Replay competes with read workload | Replica high CPU, slow replay |
| Replica I/O bottleneck | WAL replay/data writes slow | High disk queue, high WriteLatency |
| Long query on replica | Replay conflicts with snapshot | Long SELECT on replica |
| Cross-region network delay | WAN latency or throughput limit | Cross-region replica lag |
| Replication slot retaining WAL | Inactive slot or slow consumer | `pg_replication_slots`, WAL disk usage |
| Vacuum cleanup conflicts | Replica query conflicts with cleanup records | Query cancellations, logs |
| DDL or bulk load | Large WAL burst | Deployment timeline, WAL spike |
| Under-sized replica | Smaller instance/storage than primary | CPU/IOPS saturation |
| Monitoring gap | Replica lag not alarmed per instance/region | Missing alarms |

* * *

4.5 Scenario B1 – Write Surge Causes Replica Lag
------------------------------------------------

### Simulation

On primary:

```
CREATE TABLE repl_lag_test (
    id bigserial PRIMARY KEY,
    payload text,
    created_at timestamptz DEFAULT now()
);

INSERT INTO repl_lag_test (payload)
SELECT repeat(md5(random()::text), 50)
FROM generate_series(1, 3000000);
```

Or generate heavy WAL:

```
UPDATE repl_lag_test
SET payload = repeat(md5(random()::text), 50)
WHERE id <= 2000000;
```

### Detect

Primary:

```
SELECT
    application_name,
    state,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes,
    replay_lag
FROM pg_stat_replication;
```

Replica:

```
SELECT now() - pg_last_xact_replay_timestamp() AS replica_delay;
```

CloudWatch:

*   `ReplicaLag`
*   `WriteIOPS`
*   `WriteThroughput`
*   `TransactionLogsDiskUsage`

### Remediation

*   Pause batch job if business allows.
*   Throttle batch writes.
*   Commit in smaller batches.
*   Scale replica instance class if replay cannot keep up.
*   Increase storage IOPS/throughput if I/O bound.
*   Route fewer analytical reads to lagging replica.

### Prevention

*   Add write-rate guardrails.
*   Add deployment alarms for WAL spike.
*   Use batch chunking:

```
UPDATE table_name
SET ...
WHERE id BETWEEN 1 AND 10000;
COMMIT;
```

* * *

4.6 Scenario B2 – Long-Running Query on Replica Delays Replay
-------------------------------------------------------------

### Simulation

On replica:

```
BEGIN;
SELECT count(*)
FROM large_table, pg_sleep(600);
```

On primary:

```
UPDATE large_table
SET updated_at = now()
WHERE id <= 1000000;
```

### Detect

On replica:

```
SELECT
    pid,
    state,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 500) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;
```

Replica delay:

```
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

### Remediation

Cancel/terminate long query if safe:

```
SELECT pg_cancel_backend(<pid>);
-- If not responding:
SELECT pg_terminate_backend(<pid>);
```

### Prevention

*   Set query timeout on replicas:

```
ALTER DATABASE appdb SET statement_timeout = '10min';
```

*   Separate OLTP read replicas from analytics replicas.
*   Do not run unbounded reporting queries on production replicas.
*   Use materialized reporting tables or warehouse pipeline.

* * *

4.7 Scenario B3 – Inactive Logical Replication Slot Retains WAL
---------------------------------------------------------------

### How It Happens

A logical replication consumer stops. Slot remains inactive. PostgreSQL keeps WAL required by that slot, causing storage growth.

### Detect

```
SELECT
    slot_name,
    slot_type,
    database,
    active,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

### Remediation

Only drop a slot after confirming the consumer no longer needs it:

```
SELECT pg_drop_replication_slot('slot_name');
```

For AWS DMS or external consumers, confirm with the owning team before dropping.

### Prevention

*   Alert on inactive slots.
*   Alert on retained WAL size.
*   Maintain slot ownership registry.
*   Add automated stale slot review.

* * *

4.8 Scenario B4 – Replica Under-Sized Compared to Primary
---------------------------------------------------------

### How It Happens

Primary is larger or has more IOPS. Replica has lower CPU, memory, or I/O capacity and cannot replay WAL fast enough.

### Detect

Compare primary vs replica:

*   Instance class
*   Storage type
*   Provisioned IOPS
*   CPU
*   FreeableMemory
*   Read/write latency
*   ReplicaLag

SQL:

```
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

### Remediation

*   Scale replica instance.
*   Increase storage IOPS/throughput.
*   Reduce read workload.
*   Create dedicated reporting replica.
*   Rebuild replica if lag is unrecoverable and business allows.

### Prevention

*   Replica sizing policy must match workload, not just primary size.
*   Alert when replica CPU > 70% and lag increasing.
*   Test replica replay under peak write load.

* * *

4.9 Scenario B5 – Cross-Region Replica Lag
------------------------------------------

### How It Happens

Network distance, write burst, or cross-region throughput bottleneck delays WAL shipping/replay.

### Detect

CloudWatch:

*   `ReplicaLag`
*   `OldestReplicationSlotLag`
*   `TransactionLogsDiskUsage`
*   Network throughput

AWS notes that `Transaction Logs Disk Usage` can substantially increase when a cross-region read replica lags significantly. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.Monitoring.html?utm_source=chatgpt.com)

### Remediation

*   Reduce write burst.
*   Scale replica.
*   Check region-level service health.
*   Consider same-region replica for low-latency reads.
*   Use cross-region replica for DR, not strict read-after-write.

### Prevention

*   Define acceptable RPO/RPO-lag.
*   Add region-specific alarms.
*   Avoid routing latency-sensitive reads to cross-region replicas.

* * *

5\. Category C – Temp File Explosion
====================================

5.1 Conceptual Overview
-----------------------

Temp files are created when PostgreSQL operations exceed memory and spill to disk. Common causes:

*   Sorts
*   Hash joins
*   Hash aggregates
*   `CREATE INDEX`
*   `DISTINCT`
*   `ORDER BY`
*   `GROUP BY`
*   Large CTE/materialization
*   Bad joins due to stale stats
*   Low `work_mem`
*   Many concurrent queries multiplying memory use

AWS RDS PostgreSQL supports parameters such as `log_temp_files` and `temp_file_limit`; AWS describes `temp_file_limit` as a parameter that cancels queries exceeding the configured temporary file size limit. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.ManagingTempFiles.html?utm_source=chatgpt.com)

PostgreSQL’s `log_temp_files` logs temporary file names and sizes when temp files are deleted; `0` logs all temp files, while positive values log files above the threshold. [![](https://www.google.com/s2/favicons?domain=https://postgresqlco.nf&sz=128)PostgreSQL CO](https://postgresqlco.nf/doc/en/param/log_temp_files/?utm_source=chatgpt.com)

* * *

5.2 Symptoms
------------

| Symptom | Meaning |
| --- | --- |
| Sudden FreeStorageSpace drop | Temp file burst |
| High ReadIOPS/WriteIOPS | Disk spill |
| High `temp_bytes` | Queries spilling |
| Slow queries | Sort/hash spilling |
| CPU high + IOPS high | Large joins/sorts |
| Replica lag | Heavy query on replica or WAL from temp-heavy operations |
| RDS storage full | Temp files + WAL + bloat |

* * *

5.3 Investigation Queries
-------------------------

### 5.3.1 Database Temp Usage

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

### 5.3.2 Active Queries Likely Creating Temp Files

```
SELECT
    pid,
    usename,
    datname,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS query_age,
    left(query, 1000) AS query
FROM pg_stat_activity
WHERE state <> 'idle'
  AND (
      query ILIKE '%order by%'
      OR query ILIKE '%group by%'
      OR query ILIKE '%distinct%'
      OR query ILIKE '%create index%'
      OR query ILIKE '%hash%'
      OR query ILIKE '%join%'
  )
ORDER BY query_start;
```

### 5.3.3 Check Temp Settings

```
SHOW work_mem;
SHOW maintenance_work_mem;
SHOW temp_file_limit;
SHOW log_temp_files;
```

### 5.3.4 Find Top SQL Using `pg_stat_statements`

Requires extension:

```
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Query:

```
SELECT
    queryid,
    calls,
    total_exec_time,
    mean_exec_time,
    rows,
    shared_blks_read,
    shared_blks_hit,
    temp_blks_read,
    temp_blks_written,
    left(query, 1000) AS query
FROM pg_stat_statements
ORDER BY temp_blks_written DESC
LIMIT 20;
```

* * *

5.4 Root-Cause Classification – Temp File Explosion
---------------------------------------------------

| RCA Class | Description | Evidence |
| --- | --- | --- |
| Bad query plan | Wrong join/sort path spills | EXPLAIN shows external sort/hash batches |
| Low `work_mem` | Sort/hash cannot fit memory | Temp blocks high |
| High concurrency | Many queries each use temp | Many active similar queries |
| Missing index | Large sort or join required | Sequential scan + sort |
| Stale stats | Planner underestimates rows | `ANALYZE` old, estimate mismatch |
| Reporting query on OLTP | Large analytics query spills | App/user/source query |
| CREATE INDEX / REINDEX | Maintenance operation spills | Active DDL |
| Hash aggregate explosion | GROUP BY high cardinality | HashAgg batches |
| Temp limit absent | One query can consume large disk | `temp_file_limit = -1` |
| Monitoring blind spot | Logs not enabled, no temp alarms | No `log_temp_files`, no temp metric |

* * *

5.5 Scenario C1 – ORDER BY Sort Spill
-------------------------------------

### Simulation

```
CREATE TABLE temp_sort_test AS
SELECT
    generate_series(1, 5000000) AS id,
    md5(random()::text) AS name,
    repeat(md5(random()::text), 10) AS payload;

ANALYZE temp_sort_test;
```

Set low memory for session:

```
SET work_mem = '1MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM temp_sort_test
ORDER BY payload;
```

Look for:

```
Sort Method: external merge Disk: ...
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

Using `pg_stat_statements`:

```
SELECT
    calls,
    temp_blks_read,
    temp_blks_written,
    mean_exec_time,
    left(query, 500)
FROM pg_stat_statements
ORDER BY temp_blks_written DESC
LIMIT 10;
```

### Remediation

*   Add useful index if query pattern is valid:

```
CREATE INDEX CONCURRENTLY idx_temp_sort_test_payload
ON temp_sort_test(payload);
```

*   Increase `work_mem` carefully for session or role:

```
SET work_mem = '128MB';
```

Do not globally increase `work_mem` without concurrency calculation.

Memory risk formula:

```
Worst-case memory ≈ active_connections × work_mem × sort/hash nodes per query
```

### Prevention

*   Add `log_temp_files`.
*   Add query review for large `ORDER BY`.
*   Use pagination with index support.
*   Avoid sorting large result sets in OLTP path.

* * *

5.6 Scenario C2 – Hash Join Spill Due to Missing Index / Low Work Mem
---------------------------------------------------------------------

### Simulation

```
CREATE TABLE temp_join_a AS
SELECT
    generate_series(1, 2000000) AS id,
    (random() * 1000000)::int AS join_key,
    repeat(md5(random()::text), 5) AS payload;

CREATE TABLE temp_join_b AS
SELECT
    generate_series(1, 2000000) AS id,
    (random() * 1000000)::int AS join_key,
    repeat(md5(random()::text), 5) AS payload;

ANALYZE temp_join_a;
ANALYZE temp_join_b;

SET work_mem = '1MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM temp_join_a a
JOIN temp_join_b b ON a.join_key = b.join_key;
```

Look for:

```
Hash ... Batches: ...
temp read/write
```

### Remediation

```
CREATE INDEX CONCURRENTLY idx_temp_join_a_key ON temp_join_a(join_key);
CREATE INDEX CONCURRENTLY idx_temp_join_b_key ON temp_join_b(join_key);

ANALYZE temp_join_a;
ANALYZE temp_join_b;
```

Then recheck plan.

* * *

5.7 Scenario C3 – GROUP BY / Hash Aggregate Explosion
-----------------------------------------------------

### Simulation

```
SET work_mem = '1MB';

EXPLAIN (ANALYZE, BUFFERS)
SELECT payload, count(*)
FROM temp_sort_test
GROUP BY payload;
```

### Detect

Check for:

```
HashAggregate
Batches:
Disk Usage:
```

### Remediation

*   Add pre-aggregated summary table.
*   Increase `work_mem` only for the reporting role/session.
*   Move analytics to replica/warehouse.
*   Add filters to reduce cardinality.

* * *

5.8 Scenario C4 – CREATE INDEX Causes Temp Spike
------------------------------------------------

### Simulation

```
CREATE INDEX idx_temp_sort_payload_regular
ON temp_sort_test(payload);
```

### Detect

```
SELECT
    pid,
    phase,
    lockers_total,
    lockers_done,
    blocks_total,
    blocks_done,
    tuples_total,
    tuples_done
FROM pg_stat_progress_create_index;
```

Temp files may appear during index build depending on data size and memory.

### Remediation

Use maintenance window:

```
CREATE INDEX CONCURRENTLY idx_temp_sort_payload
ON temp_sort_test(payload);
```

Increase maintenance memory carefully:

```
SET maintenance_work_mem = '1GB';
```

On RDS, prefer parameter group or session-level where allowed.

* * *

5.9 Scenario C5 – High Concurrency Temp Explosion
-------------------------------------------------

### How It Happens

One query creates 2 GB temp file. That may be acceptable. But 100 concurrent copies create 200 GB of temp files.

### Simulation

Run this from multiple sessions:

```
SET work_mem = '1MB';

SELECT *
FROM temp_sort_test
ORDER BY payload;
```

### Detect

```
SELECT
    application_name,
    usename,
    count(*) AS active_queries,
    min(query_start) AS oldest_query,
    left(query, 200) AS sample_query
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY application_name, usename, left(query, 200)
ORDER BY active_queries DESC;
```

### Remediation

*   Kill only runaway queries if storage is at risk:

```
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE query ILIKE '%ORDER BY payload%'
  AND now() - query_start > interval '10 minutes';
```

*   Reduce application concurrency.
*   Add queueing/rate limits.
*   Add `temp_file_limit`.

Example:

```
ALTER ROLE reporting_user SET temp_file_limit = '5GB';
```

* * *

6\. Category D – Monitoring Blind Spots
=======================================

6.1 Why Monitoring Blind Spots Happen
-------------------------------------

CloudWatch and Database Insights are necessary, but not sufficient.

CloudWatch shows infrastructure-level symptoms. PostgreSQL catalog views show database internals. Logs show events that metrics do not retain in detail.

CloudWatch Database Insights is intended to monitor and troubleshoot RDS and Aurora databases at scale. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Database-Insights.html?utm_source=chatgpt.com) Performance Insights / Database Insights can visualize database load and filter by waits, SQL statements, hosts, and users. [![](https://www.google.com/s2/favicons?domain=https://docs.amazonaws.cn&sz=128)Amazon Docs](https://docs.amazonaws.cn/en_us/AmazonRDS/latest/UserGuide/USER_PerfInsights.html?utm_source=chatgpt.com)

But blind spots remain when:

*   Metrics are not enabled.
*   Logs are not exported.
*   Alarms are missing per region/replica.
*   RDS metrics are checked, but SQL-level views are not.
*   Dashboards hide short spikes due to 5-minute aggregation.
*   `pg_stat_statements` is not enabled.
*   `log_temp_files` is disabled.
*   Autovacuum progress is not monitored.
*   Replication slots are not monitored.
*   Dead tuples and bloat are not trended.
*   Alert thresholds are static and not workload-aware.

* * *

6.2 Required Observability Layers
---------------------------------

| Layer | Tool | What It Catches |
| --- | --- | --- |
| AWS Infra | CloudWatch | CPU, IOPS, storage, replica lag |
| OS/process | Enhanced Monitoring | Process-level pressure |
| DB load | Performance Insights / Database Insights | Waits, Top SQL, users, hosts |
| SQL stats | `pg_stat_statements` | Expensive SQL, temp blocks |
| Vacuum | `pg_stat_all_tables`, `pg_stat_progress_vacuum` | Dead tuples, vacuum progress |
| Replication | `pg_stat_replication`, `pg_replication_slots` | WAL/replication issues |
| Logs | PostgreSQL logs | temp files, autovacuum, deadlocks |
| App | APM/logs | tenant/user/API correlation |

* * *

6.3 Monitoring Blind Spot Scenarios
-----------------------------------

Scenario D1 – No Alert for Dead Tuples / Bloat
----------------------------------------------

### Problem

CloudWatch shows storage growth, but no alarm tells which table is bloated.

### Detection Query

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n_dead_tup DESC
LIMIT 20;
```

### Preventive Monitoring

Create custom metric:

```
Top table dead tuple percentage
Top table dead tuple count
Database max xid age
Autovacuum running worker count
Oldest transaction age
```

* * *

Scenario D2 – No Temp File Logging
----------------------------------

### Problem

Storage drops suddenly, but there is no query-level evidence.

### Check

```
SHOW log_temp_files;
```

### Enable

For investigation:

```
ALTER DATABASE appdb SET log_temp_files = 0;
```

For production baseline:

```
ALTER DATABASE appdb SET log_temp_files = '100MB';
```

RDS logging behavior is controlled through DB parameter groups and PostgreSQL logging parameters. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.overview.parameter-groups.html?utm_source=chatgpt.com)

### Preventive Monitoring

*   Export PostgreSQL logs to CloudWatch Logs.
*   Create metric filter for:

```
temporary file:
```

*   Alarm on temp file count/size.

* * *

Scenario D3 – Replica Lag Alarm Exists Only for One Region
----------------------------------------------------------

### Problem

Primary-region replica has alarms. Cross-region DR replica does not. WAL builds up quietly.

### Detection

Inventory replicas across all regions:

```
For each AWS account + region:
    list RDS instances
    identify replicas
    verify ReplicaLag alarm
    verify FreeStorageSpace alarm
    verify TransactionLogsDiskUsage alarm
```

### SQL

```
SELECT
    slot_name,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

### Prevention

*   Cross-account, cross-region alarm compliance checker.
*   Alarm template enforced by IaC.
*   Daily drift report.

* * *

Scenario D4 – Performance Insights Shows Top SQL But Not Root Cause
-------------------------------------------------------------------

### Problem

Top SQL is visible, but no one correlates it with table bloat, stale stats, temp files, or deployment.

### RCA Correlation

For a top SQL query:

1.  Get queryid from `pg_stat_statements`.
2.  Check temp blocks.
3.  Run `EXPLAIN`.
4.  Check table stats.
5.  Check last analyze/autovacuum.
6.  Check index size.
7.  Check deployment timestamp.

Example:

```
SELECT
    queryid,
    calls,
    mean_exec_time,
    rows,
    temp_blks_written,
    shared_blks_read,
    left(query, 1000)
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

* * *

Scenario D5 – Short Spikes Hidden by 5-Minute Metrics
-----------------------------------------------------

### Problem

A 90-second temp explosion or CPU spike is averaged down and missed.

### Prevention

*   Use 1-minute CloudWatch metrics where available.
*   Enable Enhanced Monitoring at lower granularity.
*   Capture periodic SQL snapshots every 30–60 seconds during incidents.
*   Store snapshots into a DBA diagnostics schema.

Snapshot table example:

```
CREATE SCHEMA IF NOT EXISTS dba_monitoring;

CREATE TABLE dba_monitoring.activity_snapshot (
    captured_at timestamptz DEFAULT now(),
    pid int,
    usename text,
    application_name text,
    state text,
    wait_event_type text,
    wait_event text,
    query_age interval,
    xact_age interval,
    query text
);
```

Snapshot insert:

```
INSERT INTO dba_monitoring.activity_snapshot
SELECT
    now(),
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start,
    now() - xact_start,
    left(query, 2000)
FROM pg_stat_activity
WHERE state <> 'idle';
```

* * *

7\. Manual Investigation Runbooks
=================================

7.1 Runbook – Autovacuum & Bloat Incident
-----------------------------------------

### Trigger

*   Free storage decreasing
*   Query latency increasing
*   Dead tuples high
*   Autovacuum warnings
*   XID age high
*   Table/index size abnormal

### Step 1 – Confirm Database Health

```
SELECT
    datname,
    numbackends,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    deadlocks
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

### Step 2 – Find Dead Tuple Hotspots

```
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_all_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n_dead_tup DESC
LIMIT 30;
```

### Step 3 – Check If Vacuum Is Running

```
SELECT * FROM pg_stat_progress_vacuum;
```

### Step 4 – Check Long Transactions

```
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - xact_start AS xact_age,
    backend_xmin,
    left(query, 500)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start ASC;
```

### Step 5 – Check XID Age

```
SELECT
    datname,
    age(datfrozenxid) AS xid_age
FROM pg_database
ORDER BY xid_age DESC;
```

### Step 6 – Classify RCA

Use this decision tree:

```
Dead tuples high?
    ├─ Vacuum not running?
    │   ├─ Autovacuum disabled/table settings wrong
    │   └─ Worker starvation
    ├─ Vacuum running but not cleaning?
    │   ├─ Long transaction
    │   └─ Idle in transaction
    ├─ Vacuum running but too slow?
    │   ├─ Cost delay too high
    │   ├─ I/O pressure
    │   └─ Large table backlog
    └─ Dead tuples cleaned but size high?
        ├─ Table bloat requires rewrite
        └─ Index bloat requires reindex
```

### Step 7 – Safe Remediation

Low risk:

```
ANALYZE table_name;
VACUUM (ANALYZE) table_name;
```

Medium risk:

```
REINDEX INDEX CONCURRENTLY index_name;
```

High risk / maintenance window:

```
VACUUM FULL table_name;
CLUSTER table_name USING index_name;
```

Emergency:

```
SELECT pg_terminate_backend(pid);
```

Only terminate after validating impact.

* * *

7.2 Runbook – Replication Lag Incident
--------------------------------------

### Trigger

*   `ReplicaLag` alarm
*   Stale reads
*   Replica falling behind
*   Primary WAL storage increasing
*   Cross-region lag

### Step 1 – Confirm Lag

On replica:

```
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

On primary:

```
SELECT
    application_name,
    state,
    sync_state,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
```

### Step 2 – Check Replication Slots

```
SELECT
    slot_name,
    slot_type,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

### Step 3 – Check Primary Workload

```
SELECT
    queryid,
    calls,
    total_exec_time,
    rows,
    shared_blks_dirtied,
    shared_blks_written,
    wal_bytes,
    left(query, 500)
FROM pg_stat_statements
ORDER BY wal_bytes DESC
LIMIT 20;
```

`wal_bytes` is available in newer PostgreSQL versions when supported by your RDS version.

### Step 4 – Check Replica Workload

```
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 500)
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start;
```

### Step 5 – Classify RCA

```
Replica lag high?
    ├─ Primary write spike?
    │   ├─ Bulk load
    │   ├─ Mass update/delete
    │   └─ Index/table rewrite
    ├─ Replica overloaded?
    │   ├─ CPU high
    │   ├─ IOPS high
    │   └─ Long read queries
    ├─ WAL retained?
    │   ├─ Inactive slot
    │   └─ Slow logical consumer
    ├─ Cross-region?
    │   ├─ Network/throughput
    │   └─ DR replica undersized
    └─ Monitoring issue?
        ├─ Missing alarms
        └─ Wrong thresholds
```

### Step 6 – Remediation

*   Stop or throttle write job.
*   Cancel long replica query.
*   Scale replica.
*   Increase IOPS/throughput.
*   Drop stale replication slot only after owner approval.
*   Rebuild replica if unrecoverable.
*   Temporarily route reads to primary only if business approves.

* * *

7.3 Runbook – Temp File Explosion
---------------------------------

### Trigger

*   Free storage drops quickly
*   High temp bytes
*   High IOPS
*   Slow reporting/API queries
*   Log entries for temporary files

### Step 1 – Confirm Temp Growth

```
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
ORDER BY temp_bytes DESC;
```

### Step 2 – Find Top Temp SQL

```
SELECT
    queryid,
    calls,
    total_exec_time,
    mean_exec_time,
    temp_blks_read,
    temp_blks_written,
    left(query, 1000) AS query
FROM pg_stat_statements
ORDER BY temp_blks_written DESC
LIMIT 20;
```

### Step 3 – Check Active Queries

```
SELECT
    pid,
    usename,
    application_name,
    now() - query_start AS query_age,
    wait_event_type,
    wait_event,
    left(query, 1000)
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_start;
```

### Step 4 – Check Settings

```
SHOW work_mem;
SHOW temp_file_limit;
SHOW log_temp_files;
```

### Step 5 – Classify RCA

```
Temp files high?
    ├─ One bad query?
    │   ├─ ORDER BY
    │   ├─ GROUP BY
    │   ├─ DISTINCT
    │   ├─ Hash join
    │   └─ CREATE INDEX
    ├─ Many concurrent queries?
    │   ├─ API fanout
    │   ├─ Report burst
    │   └─ Job retry storm
    ├─ Bad plan?
    │   ├─ Stale stats
    │   ├─ Missing index
    │   └─ Wrong join order
    └─ Guardrail missing?
        ├─ No temp_file_limit
        └─ No log_temp_files
```

### Step 6 – Remediation

Immediate:

```
SELECT pg_cancel_backend(pid);
```

Emergency:

```
SELECT pg_terminate_backend(pid);
```

Prevent query from consuming unlimited temp:

```
ALTER ROLE reporting_user SET temp_file_limit = '5GB';
```

Tune query/index/statistics:

```
ANALYZE table_name;

CREATE INDEX CONCURRENTLY idx_name
ON table_name(column_name);
```

* * *

8\. Agent-Based RCA Automation
==============================

8.1 Agent Architecture
----------------------

Use a multi-agent workflow:

```
CloudWatch Alarm / User Report
        ↓
Incident Intake Agent
        ↓
Metric Correlation Agent
        ↓
PostgreSQL Diagnostic Agent
        ↓
RCA Classifier Agent
        ↓
Simulation Recommendation Agent
        ↓
Safe Remediation Agent
        ↓
Post-Incident Prevention Agent
```

* * *

8.2 Required Agent Inputs
-------------------------

### AWS Metrics

For each RDS instance:

```
CPUUtilization
FreeableMemory
FreeStorageSpace
ReadIOPS
WriteIOPS
ReadLatency
WriteLatency
DiskQueueDepth
DatabaseConnections
ReplicaLag
TransactionLogsDiskUsage
OldestReplicationSlotLag
FreeLocalStorage if applicable
```

### PostgreSQL SQL Snapshots

The agent should collect:

```
pg_stat_activity
pg_stat_database
pg_stat_all_tables
pg_stat_user_tables
pg_stat_user_indexes
pg_stat_progress_vacuum
pg_stat_progress_create_index
pg_stat_replication
pg_replication_slots
pg_stat_statements
```

### Logs

CloudWatch Logs filters:

```
temporary file:
automatic vacuum
deadlock detected
canceling statement due to conflict with recovery
terminating connection
remaining connection slots are reserved
could not write to file
No space left on device
```

* * *

8.3 Agent RCA Decision Logic – Autovacuum & Bloat
-------------------------------------------------

Pseudo workflow:

```
Input: storage alarm, latency alarm, or bloat scan

1. Fetch top tables by n_dead_tup.
2. Fetch top tables by total size growth.
3. Check last_autovacuum and last_autoanalyze.
4. Check pg_stat_progress_vacuum.
5. Check long transactions and backend_xmin.
6. Check xid age.
7. Classify:

IF xid_age > threshold:
    RCA = wraparound risk
ELSE IF long transaction exists AND n_dead_tup high:
    RCA = vacuum blocked by old snapshot
ELSE IF no autovacuum and dead tuples high:
    RCA = autovacuum threshold/tuning issue
ELSE IF all workers busy:
    RCA = autovacuum worker starvation
ELSE IF dead tuples low but size high:
    RCA = persistent bloat requiring reorganization
ELSE:
    RCA = needs deeper query/workload analysis
```

Recommended actions:

```
Low risk:
    ANALYZE
    VACUUM ANALYZE
    tune table autovacuum

Medium risk:
    REINDEX CONCURRENTLY

High risk:
    VACUUM FULL during maintenance
    table rewrite
```

* * *

8.4 Agent RCA Decision Logic – Replication
------------------------------------------

```
Input: ReplicaLag alarm or stale read report

1. Confirm lag from CloudWatch.
2. Query pg_stat_replication on primary.
3. Query pg_last_xact_replay_timestamp on replica.
4. Query pg_replication_slots.
5. Compare primary write metrics with lag start time.
6. Check replica CPU/IOPS.
7. Check long-running queries on replica.
8. Classify:

IF primary write spike at lag start:
    RCA = WAL generation surge
ELSE IF replica CPU/IOPS saturated:
    RCA = replica resource bottleneck
ELSE IF inactive slot retaining WAL:
    RCA = stale replication slot
ELSE IF long query on replica:
    RCA = replay conflict / read workload blocking recovery
ELSE IF cross-region and network throughput high:
    RCA = cross-region replication bottleneck
ELSE:
    RCA = unknown, collect logs
```

Safe action ranking:

```
1. Reduce read traffic to replica.
2. Cancel long-running replica query.
3. Pause/throttle batch write.
4. Scale replica.
5. Drop stale slot only with approval.
6. Rebuild replica only as last resort.
```

* * *

8.5 Agent RCA Decision Logic – Temp File Explosion
--------------------------------------------------

```
Input: FreeStorageSpace drop, high IOPS, temp log alarm

1. Query pg_stat_database temp_bytes.
2. Query pg_stat_statements temp_blks_written.
3. Query active sessions.
4. Check log_temp_files and temp_file_limit.
5. EXPLAIN top query if safe on non-production clone.
6. Classify:

IF one query dominates temp:
    RCA = single query spill
ELSE IF many same queries active:
    RCA = concurrency storm
ELSE IF stats stale:
    RCA = bad plan due to stale stats
ELSE IF missing index:
    RCA = sort/hash due to missing index
ELSE IF temp_file_limit disabled:
    RCA = missing guardrail
```

Safe action ranking:

```
1. Cancel runaway query.
2. Reduce app/report concurrency.
3. Set role-level temp_file_limit.
4. ANALYZE affected tables.
5. Add index concurrently.
6. Tune work_mem only for role/session.
```

* * *

8.6 Agent RCA Decision Logic – Monitoring Blind Spots
-----------------------------------------------------

```
Input: incident happened but no early alert

1. Check whether CloudWatch alarm existed.
2. Check whether alarm threshold was meaningful.
3. Check whether metric exists for all replicas and regions.
4. Check log export status.
5. Check pg_stat_statements availability.
6. Check Database Insights/PI enabled status.
7. Check custom DB-level monitoring coverage.
8. Classify:

IF no alarm:
    RCA = missing alarm
ELSE IF alarm too late:
    RCA = threshold/timing issue
ELSE IF no logs:
    RCA = log visibility gap
ELSE IF no SQL stats:
    RCA = database observability gap
ELSE IF one region missing:
    RCA = regional monitoring drift
```

* * *

9\. Simulation Lab Matrix
=========================

Use a non-production RDS instance or PostgreSQL test environment.

| Category | Scenario | Expected Symptom | Key Detection |
| --- | --- | --- | --- |
| Autovacuum | Heavy UPDATE churn | Dead tuples high | `pg_stat_user_tables` |
| Autovacuum | Long transaction | Vacuum cannot clean | `backend_xmin`, `xact_age` |
| Autovacuum | Worker starvation | Backlog across tables | `pg_stat_progress_vacuum` |
| Autovacuum | Index bloat | Slow index scans | Index size stats |
| Autovacuum | Stale stats | Bad plans | `last_analyze`, EXPLAIN |
| Replication | Bulk insert/update | Replica lag | `ReplicaLag`, `pg_stat_replication` |
| Replication | Long read on replica | Replay delay | Replica `pg_stat_activity` |
| Replication | Stale slot | WAL retained | `pg_replication_slots` |
| Replication | Under-sized replica | Lag + CPU/IOPS | CloudWatch |
| Replication | Cross-region lag | DR replica delay | `OldestReplicationSlotLag` |
| Temp files | Sort spill | Temp bytes high | `pg_stat_database` |
| Temp files | Hash join spill | High temp blocks | `pg_stat_statements` |
| Temp files | Group aggregate | Disk HashAgg | EXPLAIN |
| Temp files | Concurrent reports | Storage drop | Active sessions |
| Temp files | Index build | Temp/IO spike | `pg_stat_progress_create_index` |
| Monitoring | Missing temp logs | No query evidence | `log_temp_files` |
| Monitoring | Missing replica alarm | Silent lag | Alarm audit |
| Monitoring | Missing bloat trend | Storage surprise | Custom SQL metric |
| Monitoring | Missing SQL stats | No Top SQL | `pg_stat_statements` |
| Monitoring | Aggregation blind spot | Short spike missed | Enhanced Monitoring |

* * *

10\. Safe Remediation Matrix
============================

| Problem | Low-Risk Action | Medium-Risk Action | High-Risk Action |
| --- | --- | --- | --- |
| Dead tuples high | `VACUUM ANALYZE` | Tune autovacuum | `VACUUM FULL` |
| Stale stats | `ANALYZE` | Increase statistics target | Schema/query rewrite |
| Index bloat | Monitor first | `REINDEX CONCURRENTLY` | Drop/recreate index |
| Long transaction | Contact owner | `pg_cancel_backend` | `pg_terminate_backend` |
| Replica lag | Reduce read traffic | Scale replica | Rebuild replica |
| Stale slot | Notify owner | Disable consumer | Drop slot |
| Temp spill | Cancel query | Add index/tune query | Terminate sessions |
| Temp storm | Reduce concurrency | Set `temp_file_limit` | Kill workload |
| Monitoring gap | Add dashboard | Add alarms/log filters | Enforce IaC compliance |

* * *

11\. Preventive Best Practices
==============================

11.1 Autovacuum & Bloat Prevention
----------------------------------

For high-churn tables:

```
ALTER TABLE table_name SET (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.005,
    autovacuum_analyze_threshold = 5000
);
```

Recommended practices:

*   Monitor dead tuples daily.
*   Monitor XID age.
*   Tune autovacuum per table, not only globally.
*   Keep transactions short.
*   Set `idle_in_transaction_session_timeout`.
*   Avoid mass UPDATE/DELETE without batching.
*   Prefer partitioning for large delete/archive patterns.
*   Reindex bloated indexes using `CONCURRENTLY`.
*   Schedule periodic bloat review.

* * *

11.2 Replication Prevention
---------------------------

*   Alert on `ReplicaLag`.
*   Alert on `TransactionLogsDiskUsage`.
*   Alert on inactive replication slots.
*   Keep replicas appropriately sized.
*   Do not run heavy analytics on OLTP replicas.
*   Use dedicated reporting replicas.
*   Define read-after-write consistency rules.
*   Throttle bulk jobs.
*   Monitor cross-region replicas separately.
*   Test failover/replica rebuild procedures.

* * *

11.3 Temp File Prevention
-------------------------

Enable temp logging:

```
ALTER DATABASE appdb SET log_temp_files = '100MB';
```

Set guardrails:

```
ALTER ROLE app_user SET temp_file_limit = '2GB';
ALTER ROLE reporting_user SET temp_file_limit = '10GB';
```

Query design:

*   Avoid unbounded `ORDER BY`.
*   Avoid large `DISTINCT` without indexes.
*   Avoid wide SELECTs for sorting.
*   Add indexes for common sort/join/filter patterns.
*   Use pagination correctly.
*   Move analytics to warehouse/reporting replica.
*   Tune `work_mem` per role/session, not blindly global.

* * *

11.4 Monitoring Prevention
--------------------------

Minimum alarms per RDS instance:

```
CPUUtilization
FreeableMemory
FreeStorageSpace
ReadIOPS
WriteIOPS
ReadLatency
WriteLatency
DiskQueueDepth
DatabaseConnections
ReplicaLag
TransactionLogsDiskUsage
OldestReplicationSlotLag
Deadlocks
```

Minimum custom SQL monitors:

```
Top dead tuple tables
Oldest transaction age
Max xid age
Autovacuum active workers
Tables not vacuumed recently
Top temp_bytes database
Top temp SQL
Replication slot retained WAL
Long-running queries
Idle in transaction sessions
```

Minimum log filters:

```
temporary file:
automatic vacuum
deadlock detected
canceling statement due to statement timeout
canceling statement due to conflict with recovery
remaining connection slots are reserved
No space left on device
```

* * *

12\. Production DBA Decision Tree
=================================

12.1 Storage Full or Storage Dropping
-------------------------------------

```
FreeStorageSpace dropping?
    ├─ temp_bytes increasing?
    │   └─ Temp file explosion
    ├─ TransactionLogsDiskUsage increasing?
    │   └─ Replica lag / stale slot
    ├─ table/index size increasing?
    │   └─ Bloat / heavy churn
    ├─ large index build running?
    │   └─ Maintenance operation
    └─ unknown?
        └─ Check logs + pg_stat_activity + object sizes
```

12.2 CPU High + IOPS High
-------------------------

```
CPU + IOPS high?
    ├─ Top SQL has temp blocks?
    │   └─ Temp spill
    ├─ Dead tuples/bloat high?
    │   └─ Bloat causing inefficient scans
    ├─ Autovacuum workers active?
    │   └─ Vacuum load
    ├─ Replica replay lagging?
    │   └─ WAL replay pressure
    └─ Many active sessions?
        └─ Connection/concurrency storm
```

12.3 Replica Lag
----------------

```
ReplicaLag high?
    ├─ Primary write spike?
    │   └─ WAL generation surge
    ├─ Replica resource high?
    │   └─ Replay bottleneck
    ├─ Long query on replica?
    │   └─ Recovery conflict
    ├─ Slot retained WAL?
    │   └─ Stale/slow slot
    └─ Cross-region?
        └─ Network/DR lag
```

* * *

13\. Final Operational Recommendations
======================================

For your RDS PostgreSQL production environment, I would implement the following as a standard DBA package:

1.  **Daily bloat/autovacuum report**
    *   Top dead tuple tables
    *   Tables not vacuumed recently
    *   XID age
    *   Long transactions
    *   Autovacuum progress
2.  **Replica health report**
    *   Replica lag by region
    *   WAL retained by slots
    *   Transaction log disk usage
    *   Replica CPU/IOPS pressure
    *   Long queries on replicas
3.  **Temp file report**
    *   Top databases by temp bytes
    *   Top SQL by temp blocks
    *   Temp file log summary
    *   Queries breaching threshold
4.  **Monitoring compliance report**
    *   CloudWatch alarms missing
    *   Log exports disabled
    *   `pg_stat_statements` missing
    *   `log_temp_files` disabled
    *   Replica alarms missing by region
5.  **Agent-based RCA workflow**
    *   CloudWatch alarm triggers SQL snapshot.
    *   SQL snapshot is classified into RCA category.
    *   Agent recommends only safe first actions.
    *   Dangerous actions require DBA approval.
    *   Post-incident agent creates prevention tasks.

The most important production principle is this:

```
Do not treat autovacuum, replication lag, temp files, and monitoring as separate problems.

In RDS PostgreSQL, they are usually connected through workload churn, WAL generation, query plans, storage pressure, and missing visibility.
```



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)