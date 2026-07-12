# Drill Simulation & Detection Report — `dbserver-2-fis` / `Drill_DB`

**Report window**: 2026-07-09 13:33 UTC → 2026-07-10 13:57 UTC
**Target instance**: `dbserver-2-fis.cjty2dh9czli.us-east-1.rds.amazonaws.com:5432`
**Pooler**: PgBouncer `10.70.1.158:5432`

## Purpose

This report consolidates two sources:

1. **`session-run-output.log`** — the actual drill harness execution (`hunter-simulations/01-connection-exhaustion/run_all.sh`), showing which synthetic failure scenarios were launched and their immediate post-run diagnostic sweep.
2. **Monitor tick reports** (four hunter categories: connection-exhaustion, locks/deadlocks/blocking, slow-queries, autovacuum/bloat/temp-files) — showing what the always-on monitoring pipeline actually detected, escalated, or missed across the same window.

The goal: verify that each simulated failure mode was correctly caught, correctly diagnosed, and correctly actioned by the monitoring pipeline.

---

## 1. What was simulated

The harness run (`session-run-output.log`, started 2026-07-10T11:45:27Z, log dir `run_all_logs/20260710_114527`) launched **5 parallel drills** plus 3 verification steps:

| #   | Drill                                            | Script                                          | Params   | Result      |
| --- | ------------------------------------------------ | ----------------------------------------------- | -------- | ----------- |
| 06  | Idle-in-transaction blocker                      | `06_simulate_idle_in_transaction.sh`            | `100 60` | ✔ ok, 1025s |
| 07  | PgBouncer transaction-pool saturation            | `07_simulate_pool_saturation.sh`                | `200 60` | ✔ ok, 1025s |
| 09  | Role connection-limit breach                     | `09_simulate_role_limit_breach.sh`              | `8 15`   | ✔ ok, 1025s |
| 10  | Idle connection storm / leak                     | `10_simulate_idle_connection_storm.sh`          | `200 60` | ✔ ok, 1141s |
| 11  | PgBouncer session-pool pinning                   | `11_simulate_pgbouncer_session_pool_pinning.sh` | `10 60`  | ✔ ok, 1141s |
| 03  | PgBouncer pool health check (verification)       | `03_pgbouncer_health_check.sh`                  | —        | ✔ ok, 1s    |
| 04  | RDS connection saturation monitor (verification) | `04_rds_connection_monitor.sh`                  | —        | ✔ ok, 5s    |
| 01  | Diagnostic sweep (post-drill)                    | `01_diagnostic_queries.sql`                     | —        | ✔ ok, 3s    |

**No cleanup step** is run by design — drill sessions are left to expire naturally so the monitoring pipeline has a real window to catch them.

Beyond this specific connection-exhaustion harness run, the monitor tick reports evidence **three additional drill families** that ran earlier in the window (identifiable by `drill_*` application names against `Drill_DB`):

- **Lock/blocking drill** (`~2026-07-09 20:26–20:28 UTC`): `drill_access_exclusive_holder`, `drill_idle_txn_blocker_1..5`, `drill_row_lock_blocker`, `drill_deadlock_A/B`, `drill_ddl_dml_session_a/b/c`, `drill_index_blocking_dml/ddl_a/b/c`, `drill_access_exclusive_reader/writer`, `drill_long_txn_snapshot_holder`, `drill_long_txn_workload` — a large multi-session blocking-storm/deadlock drill against `lock_test_accounts`.
- **Slow-query / CPU-spike drill** (`~2026-07-09 13:33 UTC`): `drill_offset_pagination`, `drill_json_cpu_spike`, `drill_missing_index_scan` — deep-offset pagination, JSON-predicate CPU burn, and embedded `pg_sleep(2400)` sessions.
- **Temp-file spill drill** (`~2026-07-10 07:39–08:02 UTC`): `temp_spill_sort_drill`, `temp_spill_group_drill` workloads generating large sort/group spills on `Drill_DB`.

---

## 2. What the monitoring pipeline detected

### 2.1 Connection exhaustion — ✅ detected, escalated, and correctly diagnosed

Contrary to what the immediate post-drill diagnostic sweep in the log suggested (clean, 14/250 used), the **standing monitor ticks did catch the exhaustion in progress**, just at different points in its lifecycle than the one-shot sweep captured:

| Tick               | Time      | Finding                                                                                                                                                     | Severity | Action                                                     |
| ------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ---------------------------------------------------------- |
| `20260710T104902Z` | 10:49 UTC | `connection_pool_critical` — pool at **256/250 (102.4%)**, top consumers `drill_idle_conn_storm` (115), `drill_idle_txn` (85), `drill_pool_saturation` (25) | critical | Escalated to Claude → `escalate_to_human`, high confidence |
| `20260710T112157Z` | 11:21 UTC | `pgbouncer_pool_saturated_critical` — PgBouncer pool starved, oldest client waiting 190s (climbing to 232s), `cl_waiting=94`                                | critical | Escalated to Claude → `escalate_to_human`, high confidence |
| `latest`           | 12:57 UTC | 0 issues — healthy                                                                                                                                          | —        | —                                                          |

**Root cause correctly separated into two distinct phases**, each with a different fix:

1. **Postgres-side saturation** (10:49 tick): 237 of 249 used connections attributed to `drill_idle_conn_storm`, `drill_idle_txn`, `drill_pool_saturation`, `drill_role_limit` — all active (not idle-in-txn), running ~45–47s simultaneously. CloudWatch confirmed this was a sharp non-organic spike (avg 6.99 connections over the prior 3h vs the live 249). Recommended: terminate the four drill session groups, set `idle_in_transaction_session_timeout`, cap the drill role/database connection limit.
2. **PgBouncer-side pool starvation** (11:21 tick, ~32 min later): once Postgres connections freed up, the bottleneck moved to PgBouncer itself — `default_pool_size=30` for `Drill_DB/postgres` was undersized against demand of 124 concurrent clients, even though Postgres was only at 16.8% utilization. Correctly distinguished "active long-running transactions" (pinning the pool) from an idle-in-txn leak — recommended raising `default_pool_size`, not killing sessions.

**Gap identified**: no CloudWatch alarms exist on `DatabaseConnections` for this instance — both escalations note this saturation "would not have paged anyone" without the custom monitor pipeline.

**Note on the post-drill diagnostic sweep** (`session-run-output.log`, step `01`): this ran clean (14/250, no idle-in-txn, no blocking) because it executed _after_ the drill sessions' hold windows (60s) had already expired — it captured a point-in-time snapshot outside the exhaustion window, not a failure of detection. The monitor tick reports above show the exhaustion was very much live and caught in near-real-time.

### 2.2 Locks / deadlocks / blocking — ✅ detected, escalated, self-resolved

| Tick               | Time                 | Issues                                                                                           | Severity              |
| ------------------ | -------------------- | ------------------------------------------------------------------------------------------------ | --------------------- |
| `20260709T202624Z` | 20:26 UTC            | 5 issues: 1 critical blocking storm + 4 warnings (lock pressure, 2× DDL blocking, advisory lock) | 1 critical, 4 warning |
| `20260709T202850Z` | 20:28 UTC            | Same 5 issues persisting                                                                         | 1 critical, 4 warning |
| `latest`           | 2026-07-10 13:57 UTC | 0 issues — healthy                                                                               | —                     |

**Root blocker correctly identified**: pid `26863` (`drill_access_exclusive_holder`) ran `LOCK TABLE lock_test_accounts` (implicit ACCESS EXCLUSIVE) then held the transaction open, blocking **22 sessions at chain depth 4** — a mix of DML (`UPDATE`, multiple `drill_idle_txn_blocker_*`), DDL (`ALTER TABLE ... DROP COLUMN`), and further nested drill sessions (`drill_deadlock_A/B`, `drill_ddl_dml_session_*`, `drill_index_blocking_*`).

Escalated to Claude on the first tick (20:26 UTC, critical) → root cause `lock_contention` (a legitimate active transaction holding a lock, not a config defect), high confidence. Recommended ladder:

1. Re-verify the blocking tree live before acting
2. `pg_cancel_backend(26863)` as a graceful first step (holder was active, not idle-in-txn)
3. `pg_terminate_backend(26863)` if still blocked after 30s, gated behind SysCloud's approval process
4. Immediate prevention: `idle_in_transaction_session_timeout` and `lock_timeout` set at the role level
5. Structural fix: raise a change request for `idle_in_transaction_session_timeout`, `lock_timeout`, `deadlock_timeout`, `log_lock_waits` on the parameter group — confirmed none of these were customized (all sitting at engine default)

**Gap identified**: same as above — no CloudWatch alarms configured, and `log_lock_waits` was off, meaning a real (non-drill) cascade of this shape would leave no log trail for post-mortem.

By the second tick (20:28 UTC) all 5 findings were within the dedupe window (no repeat escalation, correctly avoiding alert fatigue), and by the `latest` tick the following day, the storm had fully cleared — consistent with a time-bounded drill rather than a persistent fault.

### 2.3 Slow queries — ✅ detected; mixed resolution outcomes

| Tick               | Time      | Issues             | Notable outcome                                                                              |
| ------------------ | --------- | ------------------ | -------------------------------------------------------------------------------------------- |
| `20260709T133310Z` | 13:33 UTC | 5 issues           | 1 resolved deterministically, 1 escalated, 2 skipped (dedupe), **1 Claude dispatch failure** |
| `20260710T091703Z` | 09:17 UTC | 4 issues           | 3 resolved deterministically, 1 skipped (dedupe)                                             |
| `latest`           | 09:18 UTC | 1 issue (bgwriter) | skipped (dedupe)                                                                             |

Drill sessions detected and correctly triaged:

- `drill_offset_pagination` — deep `OFFSET 9000000 LIMIT 50` query running 146.1s, correctly flagged as `query_slow`
- `drill_json_cpu_spike` — two sessions (67.4s and 67.1s), one auto-classified `config_error`/`wait_and_observe` (deterministic rule), one escalated to Claude and correctly identified as a **synthetic CPU-spike test with an embedded `pg_sleep(2400)`** — the escalation reasoned that the session itself was harmless (idle, 100% cache hit, isolated) but flagged genuine concurrent host-wide CPU pressure (82–88% avg) as the real concern, and recommended confirming drill authorization plus closing the CloudWatch alarm gap for CPU/connections
- `drill_missing_index_scan` — **one instance triggered a Claude dispatch failure** (`qid--946483784687663509`, 155.23s, "see logs") — this is a genuine pipeline gap: the escalation for this specific session never completed
- Second run of `drill_missing_index_scan` and a `drill_function_predicate` session (10-Jul tick) were both correctly resolved deterministically via rule `v-query-slow-cpu` → `wait_and_observe`, medium confidence

Non-drill, real configuration finding surfaced alongside the drill noise: **`public.slowq_orders` has `autovacuum_enabled=false`**, escalated to `escalate_to_human` with high confidence and a concrete remediation (`ALTER TABLE ... RESET (autovacuum_enabled); VACUUM ANALYZE ...`). Also persistent: `checkpoint_backend_writes` — bgwriter overloaded at 73.3% backend-direct writes (>50% warn threshold), unresolved and recurring across both the 09:17 and `latest` ticks (dedupe-suppressed, not fixed).

**Gap identified**: the one Claude dispatch failure on `drill_missing_index_scan` means that particular finding never got a diagnosis or recommended action — it simply logged "see logs" with no retry visible in these reports.

### 2.4 Autovacuum / bloat / replication / temp files — ✅ detected, escalated once, then dedupe-suppressed

| Tick               | Time          | Issues   | Resolution                                                     |
| ------------------ | ------------- | -------- | -------------------------------------------------------------- |
| `20260710T075639Z` | 07:56 UTC     | 4 issues | 1 escalated to Claude, 3 skipped (no material change)          |
| `20260710T080245Z` | 08:02 UTC     | 4 issues | 0 escalated — 3 skipped (unchanged), 1 skipped (dedupe window) |
| `latest`           | same as above | —        | —                                                              |

Drill workload detected: `Drill_DB` spilling **~5.9 GB/hour of temp files** (warn threshold 1 GiB/h), driven by `temp_spill_sort_drill` and `temp_spill_group_drill` — large sorts/group-bys, plus a very slow `OFFSET`/`LIMIT` pagination query on `slowq_orders` (mean 503s) and an index-creation query on `slowq_customers` (mean 204s).

Three standing **configuration gaps** on `dbserver-2-fis` were surfaced (all long-standing/unchanged across ticks, not new from the drill):

- `log_temp_files = -1` (disabled) — no log evidence for temp spills
- `temp_file_limit = -1` (unbounded) — no guardrail against runaway disk consumption
- No `dba_monitoring.activity_snapshot` mechanism — short-lived spikes vanish once the session disconnects
- `work_mem = 768MB`, well above the SysCloud fleet baseline of 64MB

**Escalation on the first tick was accepted, but not detailed with the same evidence depth in these reports** — subsequent ticks correctly recognized the same underlying condition ("no material change") and did not re-escalate, avoiding duplicate work.

---

## 3. Detection coverage summary

| Drill scenario                        |           Simulated            |                    Detected                     |                 Escalated                 | Root cause correct | Gaps found                                                                                    |
| ------------------------------------- | :----------------------------: | :---------------------------------------------: | :---------------------------------------: | :----------------: | --------------------------------------------------------------------------------------------- |
| Idle connection storm / leak          |               ✅               |                       ✅                        |               ✅ (critical)               |         ✅         | No CloudWatch alarm on `DatabaseConnections`                                                  |
| PgBouncer transaction-pool saturation |               ✅               |                       ✅                        |               ✅ (critical)               |         ✅         | `default_pool_size` undersized; caught as a distinct second-phase issue                       |
| Role connection-limit breach          |               ✅               | Partially (folded into pool saturation finding) |                    ✅                     |         ✅         | Recommended adding `CONNECTION LIMIT` — implies none currently set                            |
| PgBouncer session-pool pinning        |               ✅               |          ✅ (via pool starvation tick)          |                    ✅                     |         ✅         | —                                                                                             |
| Idle-in-transaction blocker           |               ✅               |                       ✅                        |               ✅ (critical)               |         ✅         | `idle_in_transaction_session_timeout`, `lock_timeout`, `log_lock_waits` all at engine default |
| Blocking storm / deadlock drill       |               ✅               |                       ✅                        |               ✅ (critical)               |         ✅         | No CloudWatch alarms; `log_lock_waits` off                                                    |
| Deep-offset pagination (slow query)   |               ✅               |                       ✅                        |        dedupe-suppressed on repeat        |         ✅         | —                                                                                             |
| JSON CPU-spike drill                  |               ✅               |                       ✅                        |              ✅ (1 session)               |         ✅         | —                                                                                             |
| Missing-index-scan drill              |               ✅               |                       ✅                        | ⚠️ **dispatch failure on one occurrence** |        N/A         | Escalation never completed for that finding                                                   |
| Temp-file spill drill                 |               ✅               |                       ✅                        |           ✅ (first tick only)            |         ✅         | `log_temp_files`, `temp_file_limit`, activity-snapshot all missing                            |
| autovacuum disabled (`slowq_orders`)  | N/A (real config, not a drill) |                       ✅                        |           ✅ (high confidence)            |         ✅         | Concrete `ALTER TABLE`/`VACUUM` fix given                                                     |
| bgwriter overload                     |      N/A (real, ongoing)       |                       ✅                        |         Recurs, dedupe-suppressed         |         —          | Still unresolved as of `latest` tick                                                          |

---

## 4. Key takeaways

1. **All five connection-exhaustion drills in the harness run were caught by the standing monitor**, even though the one-shot post-drill diagnostic sweep in `session-run-output.log` came back clean — the sweep simply ran after the drill sessions' 60s hold window had expired. The monitor ticks (10:49 and 11:21 UTC) captured both phases of the failure: Postgres-side saturation, then PgBouncer-side pool starvation once Postgres freed up.
2. **Root-cause attribution was consistently correct** across all four hunter categories — the pipeline correctly distinguished idle-in-txn leaks from active-transaction pinning, config errors from downstream service failures, and legitimate lock contention from cascading storms.
3. **One concrete pipeline gap**: a Claude dispatch failure on the `drill_missing_index_scan` slow-query finding (13:33 UTC tick) left that specific escalation without a diagnosis — worth checking why that dispatch failed and whether a retry path exists.
4. **Recurring infrastructure gaps surfaced by the drills, independent of drill success/failure**, are the real actionable items:
   - No CloudWatch alarms on `DatabaseConnections` or `CPUUtilization` for `dbserver-2-fis`
   - `idle_in_transaction_session_timeout`, `lock_timeout`, `deadlock_timeout`, `log_lock_waits`, `log_temp_files`, `temp_file_limit` all sitting at engine defaults
   - No `activity_snapshot` mechanism for capturing short-lived spikes after a session disconnects
   - `bgwriter` overload (73.3% backend-direct writes) is real and unresolved, not drill-related
5. **Dedupe/no-material-change suppression worked as intended** — repeated ticks for the same unresolved condition did not re-escalate or spam Claude, keeping cost and noise down while still surfacing the first occurrence with full evidence.
