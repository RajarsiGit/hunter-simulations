# Connection Exhaustion — Drill & Diagnostic Scripts

Ported from the top-level `connection-exhaustion/` folder onto the shared
`.env` + non-interactive (`--yes`/`DRILL_YES=1`) conventions used across
`simulations/`, plus two new drills covering scenarios found in `gpt-docs/`
that weren't previously scripted. See `SKILL.md` for the Claude-Code-facing
summary and agent-usage notes.

## Setup

```bash
cp ../.env.example .env
$EDITOR .env   # set PGHOST/PGUSER/PGPASSWORD/PGDATABASE (+ PGBOUNCER_* / DRILL_ROLE* as needed)
chmod +x *.sh  # already executable in this checkout, but harmless to re-run
```

## Scripts

| File | Maps to (gpt-docs) | Purpose |
|---|---|---|
| `01_diagnostic_queries.sql` | RDS Postgres Issue Guide §7.2/§8.2, Senthil §11.4 | Full diagnostic sweep — **run first on any incident** |
| `03_pgbouncer_health_check.sh` | PgBouncer Connection Exhaustion | `SHOW POOLS;` maxwait evaluator, exit codes for cron/Grafana |
| `04_rds_connection_monitor.sh` | Issue Guide §8.2 | `max_connections` saturation + idle-in-txn + top idle source |
| `06_simulate_idle_in_transaction.sh` | Senthil §10.5, PgBouncer doc S3 | Idle-in-transaction blocker drill |
| `07_simulate_pool_saturation.sh` | Senthil §10.4, PgBouncer doc S4 | PgBouncer transaction-pool saturation drill |
| `09_simulate_role_limit_breach.sh` | Issue Guide §8.1 | Per-role hard connection limit breach drill |
| `10_simulate_idle_connection_storm.sh` | Issue Guide §8.3 Scenarios 1/2/5, Senthil §11.6 Rule 1 | **New.** Plain idle (no txn) connection flood — leak / deploy-storm signature |
| `11_simulate_pgbouncer_session_pool_pinning.sh` | PgBouncer doc Scenario S5, Senthil §10.8 | **New.** Session-mode PgBouncer pool pinning |

No mitigation (session termination/throttling) or cleanup scripts are
included in this folder, and no drill blocks on a confirmation prompt —
every drill fires immediately, only demonstrates the problem, and leaves it
in place (sessions self-expire on their own after their hold duration — 60s
by default in every script and in both `run_all.sh --fast`/`--full`, sized
for a ~1 minute local drill window). That default is still well under the
connection-exhaustion hunter's 300s poll interval, so hunter-detection
reliability is NOT guaranteed out of the box — pass a larger `hold_seconds`
explicitly (e.g. 2400, ~8 poll ticks of overlap) if you need a hunter to
reliably catch it mid-drill.

## Automated full run

`run_all.sh` launches every drill in this folder CONCURRENTLY (not one at a
time) to stack simultaneous connection-exhaustion signatures, then runs the
detection scripts once all drills finish — one command instead of stepping
through 06/07/09/10/11 by hand. See `--list` for a full flag reference.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest
DRILL_YES=1 ./run_all.sh

# Skip the two drills that need extra pre-existing config (DRILL_ROLE / PgBouncer session mode)
./run_all.sh --skip 09,11 --yes

# Doc-example scale (larger connection/attempt counts, same ~60s hold)
./run_all.sh --full --yes
```

## Automated sequential run

`run_sequential.sh` is the one-at-a-time counterpart to `run_all.sh`: it
runs the same five drills in order (06 → 07 → 09 → 10 → 11), each one
blocking until it self-expires, then stops and waits for you to press
Enter before starting the next one — a manual gate instead of a timed
pause, so you can check the hunter/dashboard between drills. Detection
(03/04/01) runs once, after every drill finishes.

```bash
# Preview the manifest without touching the DB
./run_sequential.sh --list

# Defaults: 20s hold per drill, manual Enter-to-continue gate between drills
DRILL_YES=1 ./run_sequential.sh

# Skip the two drills that need extra pre-existing config (DRILL_ROLE / PgBouncer session mode)
./run_sequential.sh --skip 09,11 --yes

# Longer hold for reliable hunter detection (poller runs every 300s)
./run_sequential.sh --hold 300 --yes
```

## Quick-start examples

```bash
# Drill: idle-in-transaction blocker (agent/non-interactive)
DRILL_YES=1 ./06_simulate_idle_in_transaction.sh 200 60 my_test_table

# Detect
psql -f 01_diagnostic_queries.sql

# ─────────────────────────────────────────────

# Drill: PgBouncer transaction-pool saturation
./07_simulate_pool_saturation.sh 500 60 --yes
psql -h "$PGBOUNCER_HOST" -p "$PGBOUNCER_PORT" -U "$PGBOUNCER_ADMIN_USER" pgbouncer -c "SHOW POOLS;"
./03_pgbouncer_health_check.sh

# ─────────────────────────────────────────────

# Drill: per-role connection limit breach (single terminal, self-cleaning)
./09_simulate_role_limit_breach.sh 8 15 --yes

# ─────────────────────────────────────────────

# Drill: plain idle connection storm / leak signature
./10_simulate_idle_connection_storm.sh 500 60 --yes
psql -c "SELECT state, count(*) FROM pg_stat_activity WHERE application_name='drill_idle_conn_storm' GROUP BY state;"

# ─────────────────────────────────────────────

# Drill: PgBouncer session-mode pool pinning (needs pool_mode=session already set;
# override arg 1 with the target's real default_pool_size if it isn't 20)
./11_simulate_pgbouncer_session_pool_pinning.sh 20 60 --yes
```

## Notes

- `01`/`04`/`06`/`09`/`10` connect **directly to RDS** (port 5432) so `pg_stat_activity` reflects true backend state.
- `03`/`07`/`11` connect to **PgBouncer** — `03`/`11`'s admin checks use the `pgbouncer` virtual database (`SHOW`/`PAUSE`/`KILL`/`RESUME` only, no normal SQL); `07`/`11`'s drill traffic uses `PGBOUNCER_HOST`/`PGBOUNCER_PORT` with a normal app user.
- `11` cannot reproduce pinning unless the target PgBouncer database is already configured `pool_mode = session` — that's a `pgbouncer.ini` change, not something a script sets (see runbook parity note in the root `connection-exhaustion/` README).
- Every `.sh` drill tags sessions with a unique `application_name` (`drill_idle_txn`, `drill_pool_saturation`, `drill_role_limit`, `drill_idle_conn_storm`, `drill_session_pinning`), fires with no confirmation gate, and self-expires after its hold duration (60s by default via `run_all.sh --fast`/`--full` and in every script's own standalone default, sized for a ~1 minute local drill window — still well under the connection-exhaustion hunter's 300s poll interval, so pass a larger `hold_seconds` explicitly if you need a hunter to reliably catch it) — there is no mitigation/cleanup script to end a drill early.
