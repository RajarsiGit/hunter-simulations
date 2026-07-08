---
name: 01-connection-exhaustion
description: Simulate and diagnose PostgreSQL/RDS/PgBouncer connection exhaustion — idle-in-transaction floods, PgBouncer transaction/session pool saturation, role connection-limit breaches, plain idle-connection storms/leaks. Use when asked to reproduce, drill, test, or investigate "too many connections", "too many clients already", PgBouncer maxwait/cl_waiting, or connection-pool exhaustion on a non-production Postgres/RDS instance.
---

# Connection Exhaustion Drills

Runnable diagnostic and drill scripts for the Connection Exhaustion failure
class, derived from `gpt-docs/` investigation guides. Every drill script
fires immediately (no confirmation gate — `--yes`/`DRILL_YES=1` are accepted
but no longer required) and tags its sessions with a distinct
`application_name` so they're trivially identifiable. There is no
mitigation/cleanup script — every drill self-expires after its hold
duration (minimum 60s in fast mode) so hunters get a real detection window,
and `run_all.sh` launches all its drills concurrently by default.

**⚠️ Non-production only.** Never point `.env` at a production endpoint when
running a script numbered 06 and above (the drills).

## Setup

Copy `../.env.example` to `.env` in the directory you'll run scripts from
(repo root works) and fill in `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` at
minimum. Scripts that talk to PgBouncer also need `PGBOUNCER_HOST`; role-limit
drills need `DRILL_ROLE`/`DRILL_ROLE_PASSWORD`. See that file for the full list.

## Agent / non-interactive use

No confirmation gate to get past — every drill script fires as soon as
you run it, no TTY or `--yes` needed. `--yes` (or `-y`) and `DRILL_YES=1`
are still accepted (harmlessly) for backward compatibility with existing
invocations.

```bash
./06_simulate_idle_in_transaction.sh 5 300 my_test_table
# or, equivalently
./07_simulate_pool_saturation.sh 200 120
```

## Automated full run

`run_all.sh` launches drills 06/07/09/10/11 CONCURRENTLY (not one at a
time), waits for all of them, then runs 03/04/01 (detection) — one command
for the whole topic instead of one script at a time. No cleanup step: drill
sessions self-expire on their own. `--list` previews the resolved manifest
without running anything; `--only`/`--skip` narrow it to specific ids;
`--fast` (default, aggressive small-scale) / `--full` (doc-example scale,
even more aggressive) control drill duration/size.

```bash
./run_all.sh --list                    # preview
DRILL_YES=1 ./run_all.sh               # fast, full manifest
./run_all.sh --skip 09,11 --yes        # skip drills needing extra config
```

## Scripts

| File | Type | Purpose |
|---|---|---|
| `01_diagnostic_queries.sql` | Detection | Full sweep: active/blocked sessions, blocking tree, idle-in-txn, connection usage by db/user/client, `max_connections` %, role/db limits, query age buckets |
| `03_pgbouncer_health_check.sh` | Monitoring | `SHOW POOLS;` maxwait check — exit 0/1/2/3 for cron/Grafana |
| `04_rds_connection_monitor.sh` | Monitoring | `used/max_connections` %, idle-in-txn count, top idle-connection source — exit 0/1/2/3 |
| `06_simulate_idle_in_transaction.sh` | **Drill** | N transactions that never commit; optional real row lock |
| `07_simulate_pool_saturation.sh` | **Drill** | Many concurrent connections *through PgBouncer* → transaction-pool saturation |
| `09_simulate_role_limit_breach.sh` | **Drill** | Temporarily limits a dedicated role, breaches it, restores it |
| `10_simulate_idle_connection_storm.sh` | **Drill** | Plain idle (no txn) direct connection flood — leaked-pool / deploy-storm signature |
| `11_simulate_pgbouncer_session_pool_pinning.sh` | **Drill** | Session-mode PgBouncer pool pinning (requires `pool_mode=session` already configured) |

## Typical flow

1. Reproduce: run a drill script (06/07/09/10/11) — no flags required.
2. Detect: `psql -f 01_diagnostic_queries.sql` or `./03_pgbouncer_health_check.sh` / `./04_rds_connection_monitor.sh`.
3. The drill self-expires on its own after its hold duration (minimum 60s
   in `run_all.sh` fast mode) — no mitigation or cleanup step is run.

See `README.md` in this folder for full usage examples.
