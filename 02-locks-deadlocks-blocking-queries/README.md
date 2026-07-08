# Locks, Deadlocks & Blocking Queries — Drill Scripts

Simulation and first-response scripts for PostgreSQL/RDS locking incidents.
Ported from the original `locks-deadlocks-blocking-queries/` drill set
(scripts 10–27) onto the shared `simulations/_lib/env.sh` conventions — `.env`
credential loading and a non-interactive `--yes` / `DRILL_YES=1` confirmation
bypass — plus one new automated-RCA script (20) derived from
`gpt-docs/ChatGPT-RDS PostgreSQL Lock Troubleshooting.md`.

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

| File | Reproduces | Key observation |
|---|---|---|
| `02_simulate_row_lock_blocking.sh` | Session A holds RowExclusiveLock idle-in-transaction; Session B blocks | `wait_event='transactionid'`, `state='idle in transaction'` |
| `03_simulate_deadlock.sh` | Classic 2-session deadlock | `pg_stat_database.deadlocks` increments; one session gets SQLSTATE 40P01 |
| `04_simulate_table_access_exclusive.sh` | `LOCK TABLE` holds AccessExclusiveLock; SELECTs and UPDATEs both block | `mode='AccessExclusiveLock'`, `granted=true` in `pg_locks` |
| `05_simulate_ddl_blocking_dml.sh` | Active UPDATE → CREATE INDEX (waits) → second UPDATE (queues behind DDL) | Full A→B→C cascade; `pg_stat_progress_create_index` shows B's progress |
| `06_simulate_advisory_lock.sh` | Session A holds `pg_advisory_lock`; Session B blocks; Session C demonstrates `pg_try_advisory_lock` | Advisory lock visible in `pg_locks` with `locktype='advisory'` |
| `07_simulate_credits_deadlock.sh` | Multi-module credits deadlock (buggy mode) vs. ordered-lock fix (fixed mode) | Run `buggy` to see deadlock; run `fixed` to confirm no deadlock |
| `08_simulate_mvw_refresh_lock.sh` | MVW REFRESH (blocking mode) vs. REFRESH CONCURRENTLY; optional duplicate injection | Blocking mode: AccessExclusiveLock on MVW; concurrent + duplicate: unique index violation |
| `11_simulate_idle_in_transaction.sh` | Session A updates a row and parks idle-in-transaction; Session B blocks indefinitely | `pg_cancel_backend` returns true but has no effect; only `pg_terminate_backend` resolves it |
| `12_simulate_long_txn_vacuum_bloat.sh` | Session A holds an old `REPEATABLE READ` snapshot; Session B creates dead tuples; VACUUM can't reclaim them | `n_dead_tup` stays > 0 after VACUUM while Session A holds `backend_xmin` |
| `13_simulate_fk_contention.sh` | `child_blocks_parent` and `parent_blocks_child` FK contention modes | Blocker and blocked sessions are on **different** tables |
| `14_simulate_vacuum_full_blocking.sh` | Mode A: VACUUM FULL holds AccessExclusiveLock; Mode B: long transaction blocks vacuum horizon | Mode A: cancel VACUUM FULL to unblock; Mode B: same pattern as script 12 |
| `15_simulate_index_blocking.sh` | Active DML → non-concurrent CREATE INDEX queues → unrelated DML queues behind the DDL | Cancel the CREATE INDEX to immediately unblock the unrelated DML |
| `16_simulate_connection_exhaustion.sh` | Mode A: idle connection flood; Mode B: idle-in-transaction connection flood | Demonstrates connection exhaustion can masquerade as lock blocking |
| `17_simulate_workflow_blockage.sh` | Mode A: stuck worker holds `FOR UPDATE`; Mode B: `SKIP LOCKED` demo | Mode A: `FOR UPDATE SKIP LOCKED` succeeds immediately on a different row |
| `18_simulate_lock_queue_amplification.sh` | 1 old DML + 1 queuing DDL → all subsequent DML blocks behind the DDL waiter | Full A→B→C→D→E recursive chain visible in `09_lock_triage_queries.sql` §3 |

## Detection / cleanup

| File | Purpose |
|---|---|
| `09_lock_triage_queries.sql` | Full first-response triage sweep (blocking tree, recursive chain, idle-in-txn sessions, pg_locks inventory, deadlock counter, long transactions, index/vacuum progress, connection headroom, advisory locks). |
| `19_cleanup_drill_sessions.sql` | Generic kill-switch — terminates any session matching a `drill_*` `application_name` pattern. |
| `10_cleanup_lock_drill.sql` | Full teardown — terminates drill sessions AND drops every `lock_test_*` table/index/MVW. |
| `20_lock_incident_rca.sh` | **New.** Automated session + lock snapshot, incident classification, blast-radius calculation, and RCA report. Safe (read-only) by default. |

## Automated full run

`run_all.sh` runs setup, all 15 drills, the triage sweep, automated RCA, and
full cleanup — one command instead of stepping through 01-20 by hand.

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
./02_simulate_row_lock_blocking.sh 1 120 --yes

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

# Lock queue amplification — see the full A→B→C→D→E chain, then resolve
./18_simulate_lock_queue_amplification.sh 60 --yes
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" -f 09_lock_triage_queries.sql
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'drill_lqa_session_b';"

# ─────────────────────────────────────────────

# Automated RCA with remediation (after confirming it's safe to act)
./20_lock_incident_rca.sh --remediate-cancel --yes
```

## Cleanup

```bash
# Kill just the drill sessions from a specific script:
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -v app_pattern='%drill_row_lock_blocker%' -f 19_cleanup_drill_sessions.sql

# Full teardown — drill sessions + all lock_test_* tables/indexes/MVWs:
psql -h "$PGHOST" -p "${PGPORT:-5432}" -U "$PGUSER" -d "$PGDATABASE" \
  -f 10_cleanup_lock_drill.sql
```

**Safety:** every simulator requires a typed `yes` confirmation (or `--yes`/
`DRILL_YES=1` for non-interactive/agent use) before running, and tags its
sessions with a `drill_*` `application_name`. Never point `.env` at a
production endpoint.
