# AWS RDS Cost Anomalies

**User:** Anonymous  
**Created:**   
**Updated:**   
**Exported:** 7/7/2026 14:42:14  
**Link:** [https://chatgpt.com/share/e/6a3bb3c1-bdc4-83ee-824e-c17d8978d63d](https://chatgpt.com/share/e/6a3bb3c1-bdc4-83ee-824e-c17d8978d63d)  

## Prompt:
Can you list out AWS RDS Infra and RDS Postgres Cost Anomaly

## Response:
I’ll frame this as an operational checklist: first AWS RDS infrastructure-level cost anomalies, then PostgreSQL-specific cost drivers, with examples of what to monitor and likely root causes.

Thought for 5s

Below is a practical list of **AWS RDS Infrastructure** and **RDS PostgreSQL-specific cost anomalies** that can happen in production.

AWS RDS cost is mainly driven by **DB instance hours, storage, provisioned IOPS, backup/snapshot storage, data transfer, monitoring/Performance Insights/CloudWatch Database Insights, replicas, Multi-AZ, and add-on services like RDS Proxy**. AWS Cost Anomaly Detection can be configured to detect abnormal spend by service, account, tag, or cost category. [![](https://www.google.com/s2/favicons?domain=https://aws.amazon.com&sz=128)Amazon Web Services, Inc.+2![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation+2](https://aws.amazon.com/rds/pricing/?utm_source=chatgpt.com)

* * *

1\. AWS RDS Infrastructure Cost Anomalies
=========================================

A. Instance / Compute Cost Anomalies
------------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Sudden DB instance cost increase | RDS hourly cost jumps | Instance scaled up manually or by automation |
| Oversized instance running continuously | High fixed cost despite low CPU/memory usage | No right-sizing review |
| Test/dev RDS running 24x7 | Non-prod cost increases | No stop/start schedule |
| Old unused RDS instances still running | Cost continues with no traffic | Forgotten migration/testing instances |
| Multiple temporary RDS instances created | Daily cost spike | Restore testing, clone testing, migration dry runs |
| Multi-AZ enabled unexpectedly | Compute/storage cost increases | Production setting enabled on dev/test |
| Wrong instance family selected | Higher cost than required | Using memory-optimized or older generation unnecessarily |
| Burstable instance credit charges/limitations | Performance issue or unexpected cost behavior | T-class instance under sustained load |
| Reserved Instance underutilization | Paying for RI but using On-Demand elsewhere | Region/class mismatch or instance decommissioned |
| On-Demand usage when RI/Savings Plan expected | Monthly cost increases | New RDS not covered by reservation |

* * *

B. Storage Cost Anomalies
-------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Storage autoscaling increases allocated storage | Storage cost permanently increases | Data growth, table bloat, indexes, WAL retention |
| Storage never shrinks after cleanup | Cost remains high | RDS allocated storage cannot automatically reduce |
| gp2/gp3/io1/io2 misconfiguration | Paying more than needed | Wrong storage type for workload |
| Provisioned IOPS overallocated | High monthly charge even with low actual IOPS | io1/io2 or gp3 IOPS provisioned too high |
| Storage bloat from PostgreSQL dead tuples | Storage grows rapidly | Autovacuum not keeping up |
| Index bloat increases storage | Storage and backup cost increase | Frequent updates/deletes, poor maintenance |
| Duplicate/unused indexes | Higher storage and write I/O cost | Indexes created without review |
| Large temporary files consuming storage | Free storage drops suddenly | Sort/hash/query spill to disk |
| Large TOAST data growth | Storage spike | Large JSONB/text/blob columns growing |
| Partition/table retention failure | Storage keeps growing | Old data not purged or partition cleanup failed |

* * *

C. IOPS / Throughput Cost Anomalies
-----------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Provisioned IOPS cost spike | Higher storage bill | IOPS increased for incident and not reverted |
| gp3 throughput overprovisioned | Extra recurring cost | Throughput set higher than needed |
| Heavy random read/write workload | I/O pressure and possible cost increase | Missing indexes, bad query plans |
| Full table scans causing high I/O | Read IOPS spike | Missing index or stale statistics |
| Write amplification | High write IOPS | Too many indexes, frequent updates |
| Vacuum-related I/O spike | Sustained IOPS increase | Autovacuum catching up after bloat |
| Reindex/VACUUM FULL I/O surge | Temporary high resource usage | Maintenance operation during peak |
| Logical replication slot lag | WAL retained, storage grows | Subscriber down or slow |

* * *

D. Backup and Snapshot Cost Anomalies
-------------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Backup storage increases suddenly | Backup cost rises | DB size growth or longer retention |
| Manual snapshots accumulate | Snapshot cost grows over time | No lifecycle cleanup |
| Pre-migration snapshots not deleted | Cost leakage | Migration/testing snapshots retained |
| Cross-region snapshot copy cost | Extra storage and transfer charges | DR/testing copy retained |
| Automated backup retention too high | Backup storage cost increases | Retention changed from 7 to 30/35 days |
| Frequent snapshots | Higher storage usage | Automation taking unnecessary snapshots |
| Snapshot export to S3 cost | Extra S3 and export cost | Data export jobs not monitored |
| Large DB clone/restore tests | Temporary but expensive cost | Multiple restored DBs kept alive |

RDS backup storage includes automated backups and active DB snapshots; increasing backup retention or taking more snapshots increases backup storage consumption. [![](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com&sz=128)AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/User_DBInstanceBilling.html?utm_source=chatgpt.com)

* * *

E. Data Transfer Cost Anomalies
-------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Cross-AZ data transfer increase | Network cost increases | App and RDS in different AZs |
| Cross-region replication cost | Higher transfer cost | Read replica/DR replica in another region |
| Public internet data transfer | Data transfer out charges | External apps/BI tools pulling data |
| Heavy reporting queries from another region | Network cost spike | Centralized reporting pulling large data |
| ETL/export jobs transferring large data | Data transfer and CPU increase | Bulk extraction jobs |
| Read replica traffic spike | Transfer cost increases | Replica in different AZ/region |
| Backup/snapshot copy across region | Transfer and storage increase | DR snapshot automation |

* * *

F. Read Replica Cost Anomalies
------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Unused read replicas running | Extra compute/storage cost | Old reporting or migration replica not removed |
| Replica oversized compared to workload | High cost | Same size as primary without need |
| Cross-region replica cost spike | Compute + storage + transfer | DR/read replica in another region |
| Replica lag causing WAL retention | Primary storage grows | Slow or broken replica |
| Multiple replicas created for testing | Temporary cost becomes permanent | Testing cleanup missed |
| Replica promoted but old primary retained | Duplicate production-sized DB cost | Failover/migration cleanup gap |

* * *

G. Multi-AZ and HA Cost Anomalies
---------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Multi-AZ enabled on non-prod | Cost nearly doubles for instance/storage architecture | Dev/test copied from prod settings |
| Multi-AZ DB cluster created instead of standard instance | Higher cost | Wrong deployment type selected |
| Standby storage/IO cost increase | Storage and I/O cost growth | Primary bloat/data growth replicated |
| Failover testing leaves extra instances | Cost spike | Temporary HA setup not deleted |

* * *

H. Monitoring / Observability Cost Anomalies
--------------------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| Enhanced Monitoring enabled at high granularity | CloudWatch log ingestion cost increases | 1-second granularity used unnecessarily |
| Performance Insights extended retention | Additional monitoring cost | Retention increased beyond free/default |
| CloudWatch Database Insights Advanced enabled | Additional observability cost | Advanced mode enabled broadly |
| Excessive PostgreSQL logs shipped to CloudWatch | CloudWatch Logs cost increases | `log_statement=all`, high slow-query logging |
| High log retention | Storage cost in CloudWatch Logs | No retention policy |
| Audit logging explosion | Log ingestion spike | pgaudit or verbose DML logging enabled |
| Too many custom metrics | CloudWatch custom metric cost | Agent publishing high-cardinality metrics |

AWS notes that Performance Insights/Database Insights has free and paid retention modes, and some advanced database analysis capabilities are moving under CloudWatch Database Insights Advanced mode. [![](https://www.google.com/s2/favicons?domain=https://aws.amazon.com&sz=128)Amazon Web Services, Inc.+1](https://aws.amazon.com/rds/performance-insights/pricing/?utm_source=chatgpt.com)

* * *

I. RDS Proxy / Connection Management Cost Anomalies
---------------------------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| RDS Proxy enabled but unused | Extra recurring cost | Proxy created for testing and forgotten |
| Too many proxies | Cost duplication | One proxy per app/service without review |
| Proxy used for low-traffic DB | Cost not justified | Added by default without workload need |
| Connection storm still reaching DB | Proxy cost plus DB scaling cost | Bad pooling configuration |

* * *

J. Regional / Account / Tagging Cost Anomalies
----------------------------------------------

| Cost Anomaly | What Happens | Common Root Cause |
| --- | --- | --- |
| RDS created in wrong region | Unexpected regional cost | Manual console mistake |
| Untagged RDS resources | Cost cannot be attributed | Missing mandatory tags |
| Cost appears under shared account | No owner visibility | Centralized account without allocation tags |
| Old customer/tenant DB not deleted | Customer-level cost leak | Offboarding process incomplete |
| DR region cost grows silently | Hidden cost outside primary region | Backup/replica automation |

* * *

2\. RDS PostgreSQL-Specific Cost Anomalies
==========================================

A. PostgreSQL Table and Index Bloat
-----------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Storage grows faster than business data | High dead tuples, table bloat | Autovacuum not aggressive enough |
| Backup cost increases | DB size increases | Bloat included in backups/snapshots |
| IOPS increases | More pages scanned | Bloated tables/indexes |
| Query runtime increases | More blocks read | Bloated indexes/table pages |
| FreeStorageSpace drops | Physical storage growth | Dead tuples not reclaimed |

**Examples:**

```
SELECT schemaname, relname, n_dead_tup, n_live_tup,
       last_autovacuum, last_vacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

* * *

B. Autovacuum Failure / Lag
---------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Storage growth | Dead tuples accumulating | Autovacuum blocked or under-tuned |
| Transaction ID wraparound emergency vacuum | Sudden I/O spike | Vacuum lag |
| CPU/IOPS spike | Multiple autovacuums running | Catch-up vacuum |
| Query slowness | Bloated tables | Autovacuum not keeping up |

**Common causes:**

```
Long-running transactions
Idle in transaction sessions
High update/delete workload
Low autovacuum thresholds
Insufficient autovacuum workers
Autovacuum cost delay too conservative
```

* * *

C. WAL Growth and Replication Slot Issues
-----------------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Storage fills unexpectedly | WAL retained on primary | Replication slot inactive |
| Backup/replica cost increases | WAL/log volume high | Heavy write workload |
| I/O spike | WAL generation surge | Bulk load/update/delete |
| Cross-region transfer cost | WAL streamed to replica | Cross-region replica/logical replication |

**Diagnostic query:**

```
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

* * *

D. Long-Running Transactions
----------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Autovacuum cannot clean dead rows | Old `backend_xmin` | Open transaction |
| Storage keeps growing | Dead tuples retained | Idle transaction |
| IOPS increases | Larger table scans | Vacuum blocked |
| Connection cost pressure | More sessions retained | App transaction leak |

**Diagnostic query:**

```
SELECT pid, usename, state, now() - xact_start AS xact_age,
       wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

* * *

E. Temp File Explosion
----------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Free storage drops suddenly | High temp file usage | Sort/hash spilling to disk |
| IOPS spike | Temporary file read/write | Low `work_mem`, bad query |
| Query cost spike | Large joins/order by/group by | Missing index or bad plan |
| CloudWatch log cost spike | Temp file logging enabled | Many temp file events |

**Common query causes:**

```
Large ORDER BY
Large GROUP BY
Hash join spill
CREATE INDEX
Materialized report query
ETL aggregation
Missing index
Low work_mem
```

Enable controlled logging:

```
ALTER SYSTEM SET log_temp_files = '100MB';
```

* * *

F. Bad Query Plans / Missing Indexes
------------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| CPU spike | High DB load | Inefficient query |
| IOPS spike | Sequential scans | Missing index |
| Storage cost indirectly increases | More temp files | Sort/hash spills |
| Need to scale instance | Bigger instance used to hide bad SQL | Query not optimized |

**Detection:**

```
SELECT queryid, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

* * *

G. Unused / Duplicate Indexes
-----------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Storage cost increase | Large index size | Too many indexes |
| Write IOPS increase | Every write updates indexes | Unused indexes |
| Backup size increase | Indexes included in snapshot | Duplicate indexes |
| Vacuum/reindex cost increase | More index maintenance | Index bloat |

**Detection:**

```
SELECT schemaname, relname, indexrelname, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;
```

* * *

H. Partition Retention Failure
------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| Storage grows daily | Old partitions retained | Cleanup job failed |
| Backup cost increases | Larger DB | Retention policy not enforced |
| Query cost increases | More partitions scanned | Partition pruning issue |
| IOPS increases | Historical data scanned | Missing partition filter |

**Examples:**

```
Audit tables not purged
Event logs retained forever
Tenant activity history not archived
Time-series partitions not dropped
```

* * *

I. Logging Configuration Cost Anomalies
---------------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| CloudWatch Logs cost spike | Huge PostgreSQL log volume | `log_statement = all` |
| Slow query logs too noisy | Many log entries | `log_min_duration_statement` too low |
| Audit logs explode | pgaudit logs every statement | pgaudit misconfiguration |
| Storage pressure | Local log generation | High verbosity logging |

**Risky settings:**

```
log_statement = all
log_min_duration_statement = 0
log_connections = on during connection storm
log_disconnections = on during connection storm
pgaudit.log = all
log_temp_files = 0
```

* * *

J. Connection Storm / PgBouncer Issues
--------------------------------------

| Cost Anomaly | PostgreSQL Signal | Root Cause |
| --- | --- | --- |
| DB scaled up unnecessarily | High connection count | No pooling or bad pooling |
| RDS Proxy/PgBouncer cost added | Additional infra cost | App connection storm |
| CPU/memory spike | Too many backends | Connection leak |
| Query latency increases | Context switching | High idle connections |
| Failover recovery delay | Too many sessions | Pool misconfiguration |

**Detection:**

```
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count(*) DESC;
```

* * *

3\. Cost Anomaly Categories by AWS Bill Line Item
=================================================

| Bill Area | Possible Anomaly |
| --- | --- |
| RDS Instance | Instance size changed, new DB created, Multi-AZ enabled |
| RDS Storage | Autoscaling, bloat, WAL retention, temp files |
| RDS Provisioned IOPS | io1/io2/gp3 IOPS increased and not reverted |
| RDS Backup Storage | Snapshot accumulation, long retention |
| RDS Data Transfer | Cross-AZ, cross-region, internet, ETL traffic |
| RDS Performance Insights / Database Insights | Extended retention or Advanced mode |
| CloudWatch Logs | PostgreSQL/audit/temp log explosion |
| CloudWatch Metrics | Too many custom/high-cardinality metrics |
| RDS Proxy | Proxy enabled but unused or overused |
| KMS | High encrypted snapshot/copy activity |
| S3 | Snapshot exports, log exports, DMS exports |
| DMS | Migration/replication tasks left running |
| Secrets Manager | Many DB credentials/secrets/rotations |
| Lambda/Step Functions | Automation repeatedly starting restore/export jobs |

* * *

4\. Real-Time RDS PostgreSQL Cost Anomaly Scenarios
===================================================

Scenario 1: Storage Autoscaling Due to Table Bloat
--------------------------------------------------

**Symptom:**  
RDS storage cost increases suddenly.

**Likely root cause:**  
High update/delete workload created dead tuples. Autovacuum failed to keep up.

**Signals:**

```
FreeStorageSpace decreasing
VolumeBytesUsed increasing
High n_dead_tup
Long-running transactions
Autovacuum not running recently
```

**Fix:**

```
Identify bloated tables
Kill/resolve long transactions
Tune autovacuum
Run VACUUM where safe
Use pg_repack or planned maintenance for severe bloat
```

* * *

Scenario 2: WAL Storage Growth Due to Inactive Replication Slot
---------------------------------------------------------------

**Symptom:**  
Storage fills rapidly even though table data size is stable.

**Likely root cause:**  
Logical replication slot is inactive and retaining WAL.

**Signals:**

```
SELECT slot_name, active, restart_lsn
FROM pg_replication_slots;
```

**Fix:**

```
Validate whether slot is still required
Restart subscriber if valid
Drop unused slot carefully
Monitor retained WAL size
```

* * *

Scenario 3: Snapshot Cost Increase After Migration Testing
----------------------------------------------------------

**Symptom:**  
RDS backup/snapshot cost increases after migration.

**Likely root cause:**  
Manual snapshots or restored DBs were not deleted.

**Fix:**

```
List manual snapshots
Check owner/project tags
Delete expired snapshots after approval
Create snapshot lifecycle policy
```

* * *

Scenario 4: CloudWatch Logs Cost Spike
--------------------------------------

**Symptom:**  
CloudWatch Logs cost suddenly increases.

**Likely root cause:**  
PostgreSQL logging changed to verbose mode.

**Common causes:**

```
log_statement = all
log_min_duration_statement = 0
pgaudit.log = all
log_temp_files = 0
Connection storm with log_connections enabled
```

**Fix:**

```
Reduce log verbosity
Set retention period
Keep slow query logging threshold reasonable
Use sampling where possible
```

* * *

Scenario 5: Data Transfer Cost Spike from Reporting Job
-------------------------------------------------------

**Symptom:**  
Data transfer cost increases daily during reporting window.

**Likely root cause:**  
BI/ETL system in another AZ, region, VPC, or external network pulls large data.

**Fix:**

```
Move reporting service closer to DB
Use read replica in same region/AZ strategy
Pre-aggregate data
Export only incremental deltas
Avoid full-table extracts
```

* * *

Scenario 6: Provisioned IOPS Left High After Incident
-----------------------------------------------------

**Symptom:**  
RDS cost remains high after performance incident.

**Likely root cause:**  
IOPS/throughput was increased temporarily but not reverted.

**Fix:**

```
Compare provisioned IOPS vs actual IOPS
Review incident changes
Right-size gp3/io1/io2 settings
Add expiry/review date for emergency scaling
```

* * *

Scenario 7: Dev/Test Environment Running Like Production
--------------------------------------------------------

**Symptom:**  
Non-prod RDS cost is close to production cost.

**Likely root cause:**  
Dev/test copied from prod with same instance size, Multi-AZ, backups, Performance Insights, high retention.

**Fix:**

```
Right-size non-prod
Disable Multi-AZ where not needed
Reduce backup retention
Stop non-prod outside working hours
Use smaller instances
Delete stale clones
```

* * *

5\. Cost Anomaly Detection Rules to Create
==========================================

AWS Cost Anomaly Detection Monitors
-----------------------------------

Create monitors for:

```
Service = Amazon Relational Database Service
Linked account = each AWS account
Cost category = Production / Non-production / Customer / Team
Cost allocation tags = Environment, CustomerId, Owner, Application, Region
```

AWS Cost Anomaly Detection can alert through email or SNS and supports monitors that adapt as accounts, tags, and cost categories change. [![](https://www.google.com/s2/favicons?domain=https://aws.amazon.com&sz=128)Amazon Web Services, Inc.+1](https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/?utm_source=chatgpt.com)

* * *

Recommended Custom Alerts
-------------------------

| Metric / Source | Alert Condition |
| --- | --- |
| RDS cost daily spend | \> 30% above 7-day average |
| FreeStorageSpace | Drops rapidly or below threshold |
| VolumeBytesUsed | Sudden increase |
| WriteIOPS / ReadIOPS | \> baseline for sustained period |
| DiskQueueDepth | Sustained high |
| CPUUtilization | Sustained > 80% |
| DatabaseConnections | Near max connections |
| ReplicaLag | Above threshold |
| TransactionLogsDiskUsage | Increasing abnormally |
| OldestReplicationSlotLag | Increasing |
| CloudWatch Logs ingestion | Sudden spike |
| Backup storage | Increasing faster than DB data size |
| Snapshot count | Unexpected increase |
| Cross-region data transfer | Above baseline |
| Performance Insights retention | Non-standard retention enabled |
| RDS instances without tags | Any count > 0 |
| Non-prod RDS running after hours | Any active instance |

* * *

6\. Quick Investigation Checklist
=================================

When RDS cost increases, check in this order:

```
1. Which AWS account?
2. Which region?
3. Which RDS resource?
4. Which cost dimension increased?
   - Instance
   - Storage
   - IOPS
   - Backup
   - Snapshot
   - Data transfer
   - CloudWatch logs
   - Monitoring
   - RDS Proxy
5. Was there a deployment, migration, restore, failover, or incident?
6. Did storage autoscaling happen?
7. Were new snapshots or read replicas created?
8. Did any PostgreSQL table/index/WAL/temp growth occur?
9. Did logging change?
10. Was any emergency scaling not reverted?
```

* * *

7\. PostgreSQL Queries for Cost RCA
===================================

Database Size
-------------

```
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
```

Top Table Sizes
---------------

```
SELECT schemaname, relname,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 20;
```

Dead Tuples
-----------

```
SELECT schemaname, relname, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;
```

Replication Slots
-----------------

```
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

Long Transactions
-----------------

```
SELECT pid, usename, state,
       now() - xact_start AS transaction_age,
       wait_event_type, wait_event,
       query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;
```

Top Costly Queries
------------------

```
SELECT queryid, calls,
       round(total_exec_time::numeric, 2) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Unused Large Indexes
--------------------

```
SELECT schemaname, relname, indexrelname,
       idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 50;
```

* * *

8\. Final Categorized List
==========================

Infra-Level RDS Cost Anomalies
------------------------------

```
1. Instance size increase
2. Wrong instance family
3. Unused RDS instance
4. Dev/test running 24x7
5. Multi-AZ enabled unexpectedly
6. Read replica created or forgotten
7. Cross-region replica cost
8. Storage autoscaling increase
9. Overprovisioned gp3/io1/io2 IOPS
10. Backup retention increase
11. Manual snapshot accumulation
12. Cross-region snapshot copy
13. Restore/clone instances not deleted
14. Data transfer across AZ/region/internet
15. Performance Insights extended retention
16. CloudWatch Database Insights Advanced usage
17. Enhanced Monitoring high granularity
18. CloudWatch Logs ingestion spike
19. RDS Proxy enabled but unused
20. Untagged resources causing ownership gaps
```

RDS PostgreSQL-Specific Cost Anomalies
--------------------------------------

```
1. Table bloat
2. Index bloat
3. Dead tuple accumulation
4. Autovacuum failure
5. Long-running transaction preventing cleanup
6. Idle in transaction sessions
7. WAL retention from replication slots
8. Replica lag retaining WAL
9. Temp file explosion
10. Bad query plans
11. Missing indexes
12. Duplicate/unused indexes
13. Excessive logging
14. pgaudit log explosion
15. Partition retention failure
16. Large JSONB/TOAST growth
17. Connection storm
18. PgBouncer/RDS Proxy misconfiguration
19. ETL/reporting full-table scans
20. Emergency scaling not reverted
```

A good cost anomaly workflow should connect **AWS billing signals** with **RDS metrics** and **PostgreSQL internals**. The billing spike tells you _where cost increased_; CloudWatch/RDS tells you _which resource dimension changed_; PostgreSQL diagnostics tell you _why the database caused that change_.



---
Powered by [ChatGPT Exporter](https://www.chatgptexporter.com)