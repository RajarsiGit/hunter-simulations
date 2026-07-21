---
name: 02-locks-deadlocks-blocking-queries
description: Simulate/reproduce and triage PostgreSQL (RDS) lock contention — row/table locks, deadlocks, DDL-blocks-DML cascades, advisory locks, FK contention, VACUUM FULL blocking, lock queue amplification, idle-in-transaction blockers, and stuck-worker workflow blockage — plus automated incident RCA. Use when asked to reproduce a locking/blocking/deadlock incident, drill an on-call response, or triage "something is stuck/blocked" on a non-production PostgreSQL instance.
---

# Locks, Deadlocks & Blocking Queries — Drill Scripts

Simulation and first-response scripts for PostgreSQL/RDS locking incidents,
derived from SysCloud's lock/deadlock incident history (`gpt-docs/ChatGPT-RDS
PostgreSQL Lock Investigation.md`, `...Lock Troubleshooting.md`) and the prior
`locks-deadlocks-blocking-queries/` drill set (10–27), ported here onto the
shared `.env` + non-interactive convention used across `simulations/`.

## Setup

1. Copy `simulations/.env.example` to `.env` in the directory you'll run
   scripts from (repo root works) and fill in `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`.
2. Run `01_setup_lock_drill_tables.sql` once to create the `lock_test_*` tables
   used by every drill:
   ```bash
   set -a; source .env; set +a
   psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
     -f simulations/02-locks-deadlocks-blocking-queries/01_setup_lock_drill_tables.sql
   ```
3. Run any `NN_simulate_*.sh` script from that same directory (or with an
   absolute/relative path — it locates the shared lib relative to itself).

## Non-interactive / agent convention

Every drill (`.sh`) prints a safety banner and fires immediately — no typed
`yes` confirmation gate. `--yes` / `-y` / `DRILL_YES=1` are still accepted
(harmlessly) but no longer required. Example invocation:

```bash
./03_simulate_deadlock.sh 1 2
```

⚠️ **NON-PRODUCTION ONLY.** Every drill runs real blocking/deadlock scenarios
against the target database. Never point `.env` at a production endpoint.

## Automated full run

`run_all.sh` runs setup once, then launches all 15 drills (02-08, 11-18)
CONCURRENTLY (not one at a time) to stack simultaneous lock contention, then
runs the triage sweep (09) and automated RCA (20) once every drill has
finished — one command for the whole topic. No cleanup step. `--list`
previews the manifest; `--only`/`--skip` narrow it to specific ids; `--fast`
(default) / `--full` control hold durations — every drill still guarantees
at least a 90s minimum observation window.

```bash
./run_all.sh --list                # preview
DRILL_YES=1 ./run_all.sh           # fast, full manifest
./run_all.sh --skip 16 --yes       # skip the connection-exhaustion overlap drill
```

`run_sequential.sh` is the one-drill-at-a-time counterpart: setup (01) runs
once, then the same 15 drills run in order and each finishes before the
next starts, then the script pauses on a manual Enter-to-continue prompt
before the next drill (not skipped by `--yes` — that gate is the point),
with a configurable per-drill hold (`--hold`, default 20s) — useful when
you want each drill individually visible to a hunter rather than stacked.

```bash
./run_sequential.sh --list             # preview
DRILL_YES=1 ./run_sequential.sh        # 20s hold, manual gate between drills
./run_sequential.sh --hold 900 --yes   # longer hold for reliable detection
```

## Scripts

| File | Reproduces | When to reach for it |
|---|---|---|
| `01_setup_lock_drill_tables.sql` | — | Run once before any drill. Creates `lock_test_*` tables. |
| `02_simulate_row_lock_blocking.sh` | Row-level lock blocking (idle-in-transaction holder) | Most common production pattern — two sessions update the same row. |
| `03_simulate_deadlock.sh` | Classic 2-session deadlock | Reproduce `ERROR: deadlock detected` / SQLSTATE 40P01. |
| `04_simulate_table_access_exclusive.sh` | `LOCK TABLE ... ACCESS EXCLUSIVE` | TRUNCATE/VACUUM FULL/REINDEX-style full-table blocking. |
| `05_simulate_ddl_blocking_dml.sh` | DDL-blocks-DML cascade | Non-concurrent `CREATE INDEX` during peak hours. |
| `06_simulate_advisory_lock.sh` | `pg_advisory_lock` contention | Job-serialization locks that never got released. |
| `07_simulate_credits_deadlock.sh` | Multi-module deadlock (buggy vs. fixed lock ordering) | Demonstrate/validate ordered-lock-acquisition fixes. |
| `08_simulate_mvw_refresh_lock.sh` | Materialized view refresh locking | Blocking vs. `REFRESH ... CONCURRENTLY`, incl. duplicate-row failure mode. |
| `09_lock_triage_queries.sql` | — | First-response detection sweep (blocking tree, pg_locks, deadlock counter, etc). Run on ANY suspected incident. |
| `11_simulate_idle_in_transaction.sh` | Idle-in-transaction blocker (`pg_cancel_backend` has no effect) | The most insidious real pattern — only `pg_terminate_backend` resolves it. |
| `12_simulate_long_txn_vacuum_bloat.sh` | Long transaction blocks VACUUM cleanup | Old snapshot (`backend_xmin`) prevents dead-tuple reclamation. |
| `13_simulate_fk_contention.sh` | FK contention (`child_blocks_parent` / `parent_blocks_child`) | Parent/child DML collide via FK checks, on different tables. |
| `14_simulate_vacuum_full_blocking.sh` | `VACUUM FULL` (ACCESS EXCLUSIVE) or long-txn-blocks-vacuum | Never run `VACUUM FULL` on a busy table during business hours. |
| `15_simulate_index_blocking.sh` | Non-concurrent `CREATE INDEX` blocks DML cascade | Unrelated DML queues behind a pending index build. |
| `16_simulate_connection_exhaustion.sh` | Connection/idle-in-txn flood (looks like blocking, isn't) | Rule out "it's not actually a lock" before you triage locks. |
| `17_simulate_workflow_blockage.sh` | Stuck job-queue worker vs. `SKIP LOCKED` | Backup/restore/export worker crashed holding `FOR UPDATE`. |
| `18_simulate_lock_queue_amplification.sh` | 1 old DML + 1 queuing DDL blocks unrelated DML | High blast-radius incident from FIFO lock queue behavior. |
| `20_lock_incident_rca.sh` | — | **New**: automated snapshot + classification + blast-radius + RCA report. Safe mode by default; `--remediate-cancel`/`--remediate-terminate` to act. |

No cleanup script is included — drill sessions/tables are left in place
after a run so the hunters have a real window to detect them.

## Typical flow for an agent

1. `09_lock_triage_queries.sql` or `20_lock_incident_rca.sh` to see what's
   actually happening right now.
2. Pick the matching `NN_simulate_*.sh` to reproduce the same shape safely on
   a drill instance, if you need to validate a runbook step or train a
   response.
