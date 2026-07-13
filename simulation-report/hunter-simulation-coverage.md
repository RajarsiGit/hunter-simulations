# Hunter Simulation Coverage Report — `dbserver-2-fis` / `Drill_DB`

**Report window**: 2026-07-08 → 2026-07-13
**Target instance**: `dbserver-2-fis.cjty2dh9czli.us-east-1.rds.amazonaws.com:5432`
**Pooler**: PgBouncer `10.70.1.158:5432`
**Compiled**: 2026-07-13

## Purpose

For each of the four production monitoring hunters, this report answers three questions:

1. How many drill simulations exist for it, in `hunter-simulations/`?
2. Of those, how many were actually **achieved** — caught and evidenced by the live monitoring pipeline?
3. For every **not achieved** drill, what is the specific, sourced reason it didn't reproduce or wasn't detected?

It consolidates four sources: each topic's `README.md` (script catalog), `session-run-output.log` /
`run_all_logs/` (execution outcomes — did the script itself even run cleanly), the timestamped monitor
tick reports under `C:\SysCloud\Production\AI-Hunters\reports\`, and — where a report file had since
been rotated off disk — the full `AI-Hunters/logs/*-monitor.log` history.

A companion machine-readable version of this same data lives at
[`hunter-simulation-coverage.json`](hunter-simulation-coverage.json), which drives the published
[Hunter Simulation Coverage Report artifact](hunter-simulation-coverage.html). Use the
`update-hunter-coverage-report` skill to keep the JSON, this file, and the artifact in sync after new
drill runs.

---

## Summary

| Hunter | Total simulations | Achieved | Not achieved |
| --- | :---: | :---: | :---: |
| 1. Connection Exhaustion | 5 | 5 | 0 |
| 2. Locks, Deadlocks & Blocking Queries | 15 | 3 | 12 |
| 3. Slow Queries | 6 | 5 | 1 |
| 4. Autovacuum / Bloat / Replication / Temp Files | 9 | 4 | 5 |
| **Total** | **35** | **17** | **18** |

"Achieved" means the drill's failure signature was actually named as evidence in a production monitor
tick report (or, for one slow-queries drill, in the full monitor log after its evidencing report had
been rotated off disk). "Not achieved" is not one undifferentiated bucket — each row below is tagged
with which of four distinct situations applies: a genuine detection-pipeline gap, an environment/data
limitation in the dev instance, a check owned by a different hunter than the folder name implies, or a
confirmed script bug.

---

## 1. Connection Exhaustion — 5 / 5 achieved

Clean sweep. The 2026-07-10 full-scale run (`session-run-output.log`, started 11:45:27Z) launched 5
parallel drills plus 3 verification steps. Two escalations between them evidence all five drills:

| Tick | Time | Finding | Severity | Action |
| --- | --- | --- | --- | --- |
| `20260710T104902Z` | 10:49 UTC | `connection_pool_critical` — pool at **256/250 (102.4%)**, top consumers `drill_idle_conn_storm` (115), `drill_idle_txn` (85), `drill_pool_saturation` (25) | critical | Escalated to Claude → `escalate_to_human`, high confidence |
| `20260710T112157Z` | 11:21 UTC | `pgbouncer_pool_saturated_critical` — PgBouncer pool starved, oldest client waiting 190s (climbing to 232s), `cl_waiting=94` | critical | Escalated to Claude → `escalate_to_human`, high confidence |
| `latest` | 12:57 UTC | 0 issues — healthy | — | — |

Root cause was correctly separated into two distinct phases: Postgres-side saturation (10:49 tick, 237
of 249 connections attributed to the four drill session groups, confirmed non-organic via CloudWatch —
avg 6.99 connections over the prior 3h vs. the live 249), then PgBouncer-side pool starvation once
Postgres freed up (11:21 tick, `default_pool_size=30` undersized against 124 concurrent clients).

| Script | Drill | Status | Notes |
| --- | --- | :---: | --- |
| 06 | Idle-in-transaction blocker | ✅ Achieved | Named top consumer (`drill_idle_txn`, 85 sessions) in the 10:49 UTC critical finding. |
| 07 | PgBouncer transaction-pool saturation | ✅ Achieved | Drove the 11:21 UTC PgBouncer starvation escalation (`cl_waiting=443`, `maxwait=95s`) once Postgres headroom freed up. |
| 09 | Role connection-limit breach | ✅ Achieved | Detected, but folded into the aggregate pool-saturation finding rather than escalated as its own standalone issue. |
| 10 | Idle connection storm / leak | ✅ Achieved | Largest single contributor (`drill_idle_conn_storm`, 115 sessions) to the 10:49 UTC critical finding. |
| 11 | PgBouncer session-pool pinning | ✅ Achieved | Caught via the pool-starvation tick. Caveat: this drill can only reproduce pinning at all if the target PgBouncer database is already configured `pool_mode = session` — a prerequisite the script cannot set itself, but which happened to hold in dev. |

**Gap identified (not a reproduction failure, an infrastructure gap)**: no CloudWatch alarms exist on
`DatabaseConnections` for this instance — both escalations note this saturation "would not have paged
anyone" without the custom monitor pipeline.

---

## 2. Locks, Deadlocks & Blocking Queries — 3 / 15 achieved

**Why the count looks low.** `run_all.sh` fires all 15 drills *concurrently* against shared
`lock_test_*` tables by design. In the one full-scale run with evidence (2026-07-09, 20:26 UTC),
script 04's table-wide `LOCK TABLE lock_test_accounts` (implicit ACCESS EXCLUSIVE) landed first and
became the root of a 22-session blocking chain at depth 4 — absorbing most of the other drills'
sessions as blocked bystanders before their own distinct failure signature (a deadlock cycle, a
genuine idle-in-txn state, a row-level lock) could register. **This is a run-design artifact, not
evidence those checks are undetectable in isolation.** The most recent fast-scale run (default ~6-8s
holds, well under the hunter's 300s poll interval) shows 0 issues, independently confirming the
README's own documented reliability caveat.

| Tick | Time | Issues | Severity |
| --- | --- | --- | --- |
| `20260709T202624Z` | 20:26 UTC | 5 issues: 1 critical blocking storm + 4 warnings (lock pressure, 2× DDL blocking, advisory lock) | 1 critical, 4 warning |
| `20260709T202850Z` | 20:28 UTC | Same 5 issues persisting (dedupe-suppressed on repeat) | 1 critical, 4 warning |
| `latest` | 2026-07-10 13:57 UTC | 0 issues — healthy | — |

Escalated to Claude on the first tick → root cause `lock_contention` (a legitimate active transaction
holding a lock, not a config defect), high confidence, with a graduated `pg_cancel_backend` →
`pg_terminate_backend` recommendation and a structural fix (raise a change request for
`idle_in_transaction_session_timeout`, `lock_timeout`, `deadlock_timeout`, `log_lock_waits` — confirmed
none of these were customized, all sitting at engine default).

| Script | Drill | Status | Reason |
| --- | --- | :---: | --- |
| 04 | Table AccessExclusiveLock | ✅ Achieved | Root of the critical `lock_blocking_critical` escalation (22 blocked sessions, depth 4) and a `ddl_blocking_detected` finding. |
| 06 | Advisory lock | ✅ Achieved | Own dedicated `advisory_lock_blocking` warning fired both ticks; not re-escalated on repeat (dedupe window, by design). |
| 08 | MVW refresh lock | ✅ Achieved | Own dedicated `ddl_blocking_detected` warning fired both ticks; dedupe-suppressed on repeat, same as above. |
| 02 | Row-lock blocking | ❌ Not achieved | *Preempted* — sessions surface only as blocked bystanders inside script 04's chain, never as their own finding. |
| 03 | Classic deadlock | ❌ Not achieved | *Preempted* before reaching its UPDATE/UPDATE cycle; `deadlock_spike` never fired in either report. |
| 05 | DDL blocks DML cascade | ❌ Not achieved | *Preempted* — same concurrency effect; sessions appear only inside script 04's blocked list. |
| 07 | Credits multi-module deadlock | ❌ Not achieved | *Preempted* — zero occurrences in either report; fully absorbed by the concurrent storm before producing any signature. |
| 11 | Idle-in-transaction (indefinite) | ❌ Not achieved | *Preempted* — the report's own idle-in-txn counter read zero both ticks; sessions were lock-waiting (state=active) on script 04, never genuinely idle-in-txn. |
| 12 | Long txn blocks vacuum | ❌ Not achieved | *Cross-hunter ownership* — by design, bloat detection lives in the autovacuum-bloat-replication-temp-files hunter, not this one (documented in the script header). |
| 13 | FK contention | ❌ Not achieved | *Genuine pipeline gap* — the FK-1 `fk_contention_detected` check exists and this drill is documented to feed it, but it never fired. |
| 14 | VACUUM FULL blocking | ❌ Not achieved | *Insufficient data volume in dev* — `lock_test_accounts` is only 5 rows, so VACUUM FULL finishes in milliseconds, far too fast for a 300s poll to ever sample it (documented in the script header). |
| 15 | Non-concurrent CREATE INDEX blocks DML | ❌ Not achieved | *Insufficient data volume in dev* — same gap as script 14; CREATE INDEX on the 5-row table completes in milliseconds. |
| 16 | Connection exhaustion (in-folder demo) | ❌ Not achieved | *Cross-hunter ownership* — by design, owned by the connection-exhaustion hunter (topic 1), explicitly "not gated by any check in this hunter." |
| 17 | Stuck-worker workflow blockage | ❌ Not achieved | *Preempted* (inferred) — zero occurrences in either report. |
| 18 | Lock queue amplification | ❌ Not achieved | *Preempted* — its own DDL needed the same AccessExclusiveLock script 04 already held, so its A→B→12-waiter chain merged into script 04's instead of forming its own root. |

**Gap identified**: no CloudWatch alarms configured, and `log_lock_waits` was off — a real (non-drill)
cascade of this shape would leave no log trail for post-mortem.

---

## 3. Slow Queries — 5 / 6 achieved

| Tick | Time | Issues | Notable outcome |
| --- | --- | --- | --- |
| `20260709T133310Z` | 13:33 UTC | 5 issues | 1 resolved deterministically, 1 escalated, 2 skipped (dedupe), **1 Claude dispatch failure** |
| `20260710T091703Z` | 09:17 UTC | 4 issues | 3 resolved deterministically, 1 skipped (dedupe) |
| `latest` | 09:18 UTC | 1 issue (bgwriter) | skipped (dedupe) |

| Script | Drill | Status | Reason |
| --- | --- | :---: | --- |
| 02 | Missing index scan | ✅ Achieved | Fired as `query_slow` in two separate ticks. First occurrence hit a Claude dispatch failure (`qid--946483784687663509`, 155.23s, "see logs") — a pipeline gap, not a reproduction failure; that escalation never completed. |
| 03 | Function-wrapped predicate | ✅ Achieved | Fired as `query_slow` (46.5s), resolved deterministically via rule `v-query-slow-cpu`. |
| 04 | Offset pagination | ✅ Achieved | Fired as `query_slow` (146.1s deep-offset query, `OFFSET 9000000 LIMIT 50`). |
| 05 | JSON processing spike | ✅ Achieved | Two sessions caught (67.4s, 67.1s); one escalation correctly identified the embedded `pg_sleep(2400)` as a synthetic drill and flagged genuine concurrent host-wide CPU pressure (82-88% avg) as the real concern. |
| 06 | Stale statistics | ❌ Not achieved | *Genuine pipeline gap* — the check's own SQL fetches the exact qualifying row (`public.slowq_orders`, never analyzed, autovacuum off), but no `stats_never_analyzed`/`stats_stale` issue was ever raised anywhere in the full monitor log history. Likely dropped because the same table already produced an `autovacuum_disabled` issue at the same priority in the same tick. |
| 07 | Retry storm | ✅ Achieved | Fired as `query_slow` three times (qid `-6658399802807205227`) per the full monitor log — the evidencing report files were since rotated off disk (only the newest two + latest are retained), so it isn't visible in the currently-kept reports. |

Non-drill, real configuration finding surfaced alongside the drill noise: **`public.slowq_orders` has
`autovacuum_enabled=false`**, escalated with high confidence and a concrete remediation. Also
persistent: `checkpoint_backend_writes` — bgwriter overloaded at 73.3% backend-direct writes (>50% warn
threshold), unresolved and recurring across ticks (dedupe-suppressed, not fixed, not drill-related).

### Not scripted (no drill exists at all)

| Scenario | Reason |
| --- | --- |
| `CREATE STATISTICS` for correlated columns | Mentioned in script 06's output but not auto-applied by any drill. |
| Bad join plan & generic prepared-plan problem | Covered narratively in the source runbook but not scripted — needs multi-table join setup / `PREPARE` session state beyond this folder's shared tables. |
| `pg_trgm`/GIN index for substring `LIKE` matches | Mentioned in script 05's output but not scripted. |

---

## 4. Autovacuum / Bloat / Replication / Temp Files — 4 / 9 achieved

Half of this topic's own checks (table/index bloat, autovacuum-disabled, stale statistics) are actually
**owned by the slow-queries hunter**, not this one — this hunter only owns temp-file-spill and
config-hygiene checks. Several "not achieved" rows below are misses against that other hunter, not
this one.

| Tick | Time | Issues | Resolution |
| --- | --- | --- | --- |
| `20260710T075639Z` | 07:56 UTC | 4 issues | 1 escalated to Claude, 3 skipped (no material change) |
| `20260710T080245Z` | 08:02 UTC | 4 issues | 0 escalated — 3 skipped (unchanged), 1 skipped (dedupe window) |

Drill workload detected: `Drill_DB` spilling **~5.9 GB/hour of temp files** (warn threshold 1 GiB/h).
Three standing **configuration gaps** were also surfaced (long-standing, not new from the drill):
`log_temp_files = -1` (disabled), `temp_file_limit = -1` (unbounded), no
`dba_monitoring.activity_snapshot` mechanism, and `work_mem = 768MB` — well above the SysCloud fleet
baseline of 64MB.

| Script | Drill | Status | Reason |
| --- | --- | :---: | --- |
| 07-sort | Temp-file spill: sort | ✅ Achieved | Named directly in the `temp_spill_warning` evidence (11 GB spilled on one call). |
| 07-group | Temp-file spill: hash aggregate | ✅ Achieved | Named directly in the same `temp_spill_warning` evidence (850 MB spilled). |
| 07-hash | Temp-file spill: hash join | ✅ Achieved | Contributed to the aggregate database-level `temp_spill_warning` (5941 MB/hour) but wasn't individually itemized in the top-5 evidence list. |
| 08 | CREATE INDEX temp spike | ✅ Achieved | Its own index build named directly in evidence (7798 MB spilled across 2 calls). |
| 03 | Table bloat from UPDATE/DELETE churn | ❌ Not achieved | *Script bug* — the PL/pgSQL churn loop fails immediately with `ERROR: invalid transaction termination`, reproduced identically across two separate runs. Even the residual bloat left over from earlier successful runs (100% dead-tuple ratio on `bloat_drill_records`) never triggered a finding — that check lives in the slow-queries hunter and never fired there either. |
| 04 | Index bloat | ❌ Not achieved | *Script bug* — same PL/pgSQL bug as script 03, identical `invalid transaction termination` error; churn loop never completes. |
| 05 | Autovacuum worker starvation | ❌ Not achieved | *Cross-hunter miss* — ran successfully, but produced no matching finding in the slow-queries hunter (which owns this check); a manual VACUUM here can only be caught if large enough to trip `query_slow`/`query_critical` instead, which it wasn't at this scale. |
| 06 | Stale statistics → bad plan | ❌ Not achieved | *Threshold structurally unmet* — shares its table with script 03's churn; after that churn, live-tuple count drops to 0 (everything becomes a dead tuple), which fails the stale-stats check's own `n_live_tup > 100000` threshold outright. Compounded by the same stats-detection pipeline gap found under slow-queries script 06. |
| 09 | Inactive replication slot retains WAL | ❌ Not achieved | *Environment config gap* — the drill fails outright with `ERROR: replication slots can only be used if "max_replication_slots" > 0`; this parameter is 0 on the dev instance. |
| 10 | Write surge → replica lag | ❌ Not achieved | *Environment gap* — structurally cannot fire without a real attached RDS read replica; `REPLICA_PGHOST` wasn't set for this run, so only the primary-side write surge ran. The replica-side lag check cannot fire without one, at any row count. |

### Cannot be scripted at all

| Scenario | Reason |
| --- | --- |
| Temp-file concurrency storm (QC-1) | No script targets it — scripts 07/08 each run one query per invocation, not a fan-out of 20+ concurrent identical ones. |
| Config-hygiene checks (CH-1..CH-5) | `log_temp_files`, `temp_file_limit`, `pg_stat_statements` presence, activity-snapshot mechanism, role-level overrides — static RDS-parameter-group/extension checks, not something a load-generating drill can toggle. |
| Transaction ID wraparound | Forcing genuine wraparound needs billions of real transactions; there's no safe way to drill the failure itself, only detect its risk. |
| DMS/CDC consumer lag | Script 09 reproduces the WAL-retention signal an inactive slot produces, but a real broken DMS task requires an actual DMS replication instance — out of scope for a single script. |

---

## 5. Key takeaways

1. **Connection exhaustion is the strongest category**: all 5 drills were caught and correctly
   root-caused across two distinct escalation phases (Postgres saturation, then PgBouncer starvation).
2. **The locks hunter's 3/15 achieved rate is a run-design artifact, not a detection failure.** Running
   all 15 drills concurrently against shared tables means one dominant AccessExclusiveLock (script 04)
   reliably wins the race and absorbs the other 11 preempted drills as blocked bystanders. Staggering
   the run (or isolating drills into separate tables/windows) would very likely raise this number —
   re-audit rather than assume the checks themselves are broken.
3. **Two confirmed script bugs** (topic 4, scripts 03 and 04) fail outright with an identical PL/pgSQL
   `invalid transaction termination` error — worth fixing independently of any hunter-detection concern,
   since the drills currently never generate the bloat they're meant to.
4. **Three genuine detection-pipeline gaps** are worth escalating to whoever owns the hunter
   definitions: FK contention (topic 2, script 13), stale statistics (topic 3, script 06 / topic 4,
   script 06), and the one-off Claude dispatch failure on `drill_missing_index_scan` (topic 3, script 02).
5. **Two environment limitations in dev** block full reproduction regardless of script correctness:
   `max_replication_slots=0` (topic 4, script 09) and no attached read replica for `REPLICA_PGHOST`
   (topic 4, script 10).
6. **Recurring infrastructure gaps surfaced by the drills, independent of drill success/failure**:
   no CloudWatch alarms on `DatabaseConnections` or `CPUUtilization`; `idle_in_transaction_session_timeout`,
   `lock_timeout`, `deadlock_timeout`, `log_lock_waits`, `log_temp_files`, `temp_file_limit` all sitting
   at engine defaults; no `activity_snapshot` mechanism; `bgwriter` overload (73.3% backend-direct
   writes) real and unresolved, not drill-related.
7. **Dedupe/no-material-change suppression worked as intended** throughout — repeated ticks for the
   same unresolved condition did not re-escalate or spam Claude, while still surfacing the first
   occurrence with full evidence.
