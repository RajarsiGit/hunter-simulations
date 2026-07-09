# Locks, Deadlocks & Blocking Queries — Drill Scripts

Simulation and first-response scripts for PostgreSQL/RDS locking incidents.
Ported from the original `locks-deadlocks-blocking-queries/` drill set
(scripts 10–27) onto the shared `simulations/_lib/env.sh` conventions — `.env`
credential loading, with `confirm_drill()` printing a banner and firing
immediately (no confirmation gate) — plus one new automated-RCA script (20)
derived from `gpt-docs/ChatGPT-RDS PostgreSQL Lock Troubleshooting.md`.

See `SKILL.md` in this folder for the full script catalog and agent-usage
notes, and `simulations/.env.example` for the credential template.

## Setup (run once)

```bash
cp ../.env.example .env   # then edit with real credentials
set -a; source .env; set +a
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -f 01_setup_lock_drill_tables.sql
```

Creates `lock_test_accounts`, `lock_test_parent`/`lock_test_child`,
`lock_test_credits`, `lock_test_job_queue`, `lock_test_mvw`/`lock_test_mvw_base`,
and `lock_test_workflow_jobs` — all required by scripts 02–18.

## Drill scripts

Every hold-type default below is 900s unless noted — clears the
locks-deadlocks-blocking-queries hunter's 300s poll interval with 3 ticks of
margin, and (for 02/11) LB-3's 300s idle-in-txn threshold with 600s margin.
Every session explicitly disables the SysCloud baseline `statement_timeout`/
`lock_timeout`/`idle_in_transaction_session_timeout` (runbook §7.3: 5min/10s/60s)
for itself — those settings would otherwise kill/abort every drill session
long before the durations below are ever reached.

| File | Reproduces | Key observation |
|---|---|---|
| `02_simulate_row_lock_blocking.sh` | Session A holds RowExclusiveLock genuinely idle-in-transaction (via a client-side `\! sleep`, not `pg_sleep` in one statement — see note below); Session B blocks | `wait_event='transactionid'`, `state='idle in transaction'` |
| `03_simulate_deadlock.sh` | Classic 2-session deadlock | `pg_stat_database.deadlocks` increments; one session gets SQLSTATE 40P01 |
| `04_simulate_table_access_exclusive.sh` | `LOCK TABLE` holds AccessExclusiveLock; SELECTs and UPDATEs both block | `mode='AccessExclusiveLock'`, `granted=true` in `pg_locks` |
| `05_simulate_ddl_blocking_dml.sh` | Active UPDATE → CREATE INDEX (waits) → second UPDATE (queues behind DDL) | Full A→B→C cascade; `pg_stat_progress_create_index` shows B's progress |
| `06_simulate_advisory_lock.sh` | Session A holds `pg_advisory_lock`; Session B blocks; Session C demonstrates `pg_try_advisory_lock` | Advisory lock visible in `pg_locks` with `locktype='advisory'` |
| `07_simulate_credits_deadlock.sh` | Multi-module credits deadlock (buggy mode) vs. ordered-lock fix (fixed mode) | Run `buggy` to see deadlock; run `fixed` to confirm no deadlock |
| `08_simulate_mvw_refresh_lock.sh` | MVW REFRESH (blocking mode, 900s hold) vs. REFRESH CONCURRENTLY; optional duplicate injection | Blocking mode: AccessExclusiveLock on MVW; concurrent + duplicate: unique index violation |
| `11_simulate_idle_in_transaction.sh` | `blocker_count` (default 5) sessions genuinely idle-in-transaction, one per row; the first also gets a Session B waiter | Feeds LB-3 idle_in_transaction_critical (blocker idle>=300s + blocked>=1) AND LH-1 idle_txn_accumulation (cluster-wide idle-in-txn>=3) in one run — was previously broken (see note below) |
| `12_simulate_long_txn_vacuum_bloat.sh` | Session A holds an old `REPEATABLE READ` snapshot; Session B creates dead tuples; VACUUM can't reclaim them | `n_dead_tup` stays > 0 after VACUUM while Session A holds `backend_xmin` — not gated by any check in this hunter (bloat detection lives in the autovacuum-bloat-replication-temp-files hunter) |
| `13_simulate_fk_contention.sh` | `child_blocks_parent` and `parent_blocks_child` FK contention modes | Blocker and blocked sessions are on **different** tables; feeds FK-1 fk_contention_detected |
| `14_simulate_vacuum_full_blocking.sh` | Mode A: VACUUM FULL holds AccessExclusiveLock; Mode B: long transaction blocks vacuum horizon (900s) | Mode A has a real coverage gap: `lock_test_accounts` is only 5 rows, so VACUUM FULL finishes in milliseconds regardless of hold settings — see script header |
| `15_simulate_index_blocking.sh` | Active DML → non-concurrent CREATE INDEX queues → unrelated DML queues behind the DDL | Same small-table coverage gap as 14 once Session A releases — see script header |
| `16_simulate_connection_exhaustion.sh` | Mode A: idle connection flood; Mode B: idle-in-transaction connection flood | Demonstrates connection exhaustion can masquerade as lock blocking; not gated by any check in this hunter — see `01-connection-exhaustion/` for the dedicated drill set |
| `17_simulate_workflow_blockage.sh` | Mode A: stuck worker holds `FOR UPDATE`; Mode B: `SKIP LOCKED` demo | Mode A: `FOR UPDATE SKIP LOCKED` succeeds immediately on a different row |
| `18_simulate_lock_queue_amplification.sh` | 1 old DML + 1 queuing DDL → `waiter_count` (default 12) unrelated sessions block behind the DDL waiter | Full A→B→N-waiter recursive chain visible in `09_lock_triage_queries.sql` §3 — 12 waiters clears LB-2 critical (blocked_count>=10) AND LH-2 (lock_waiting>=5), not just LB-1's >=3 warning tier |

**Mechanism fix (02, 11):** the original idle-in-transaction scripts ran
`BEGIN; UPDATE ...; SELECT pg_sleep(N); ROLLBACK;` as one `psql -c` string.
PostgreSQL's simple-query protocol executes an entire multi-statement string
as a single continuous message — the backend never returns control to wait
for the client in between, so `state` stayed `'active'` (wait_event=`'PgSleep'`)
for the whole duration, never `'idle in transaction'`, regardless of how long
the hold was. This silently meant LB-3/LH-1 could never fire from these
scripts. Fixed by splitting into two round trips with a genuine client-side
pause (the psql `\! sleep N` meta-command) between the UPDATE and the ROLLBACK.

## Detection / cleanup

| File | Purpose |
|---|---|
| `09_lock_triage_queries.sql` | Full first-response triage sweep (blocking tree, recursive chain, idle-in-txn sessions, pg_locks inventory, deadlock counter, long transactions, index/vacuum progress, connection headroom, advisory locks). |
| `20_lock_incident_rca.sh` | **New.** Automated session + lock snapshot, incident classification, blast-radius calculation, and RCA report. Safe (read-only) by default. |

No cleanup scripts are included in this folder, and no drill blocks on a
confirmation prompt — every drill fires immediately, guarantees at least a
900s hold (3 poll-interval ticks of margin — see table above), and leaves
its sessions/tables in place so the hunters have a real window to detect them.

## Automated full run

`run_all.sh` runs setup once, then launches all 15 drills CONCURRENTLY (not
one at a time) against the shared `lock_test_*` tables to stack simultaneous
lock contention, then runs the triage sweep and automated RCA once every
drill has finished — one command instead of stepping through 01-20 by hand.
No cleanup step.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest
DRILL_YES=1 ./run_all.sh

# Skip script 16 (connection-exhaustion overlap with topic 01) when running both topics
./run_all.sh --skip 16 --yes

# Doc-example scale
./run_all.sh --full --yes
```

## Quick-start examples

```bash
# Row-level lock blocking
./02_simulate_row_lock_blocking.sh 1 900 --yes

# In another terminal — detect the blocking:
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -f 09_lock_triage_queries.sql

# Or get an automated classification + RCA instead:
./20_lock_incident_rca.sh

# ─────────────────────────────────────────────

# Classic deadlock (watch the auto-resolution)
./03_simulate_deadlock.sh 1 2 --yes

# ─────────────────────────────────────────────

# Credits deadlock (production incident reproduction)
./07_simulate_credits_deadlock.sh buggy --yes
./07_simulate_credits_deadlock.sh fixed --yes   # confirm the ordered-lock fix

# ─────────────────────────────────────────────

# MVW refresh + duplicate-row production incident
./08_simulate_mvw_refresh_lock.sh concurrent yes --yes   # inject duplicate → fails
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -c "DELETE FROM lock_test_mvw_base WHERE id = 999;"
./08_simulate_mvw_refresh_lock.sh concurrent no --yes    # now succeeds

# ─────────────────────────────────────────────

# Lock queue amplification — see the full A→B→12-waiters chain, then resolve
./18_simulate_lock_queue_amplification.sh 900 12 --yes
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -f 09_lock_triage_queries.sql
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'drill_lqa_session_b';"

# ─────────────────────────────────────────────

# Automated RCA with remediation (after confirming it's safe to act)
./20_lock_incident_rca.sh --remediate-cancel --yes
```

**Safety:** every simulator fires immediately with no confirmation gate
(`--yes`/`DRILL_YES=1` are accepted but no longer required), and tags its
sessions with a `drill_*` `application_name`. There is no cleanup script —
drill sessions/tables are left in place after the run. Never point `.env` at
a production endpoint.
