---
name: 04-autovacuum-bloat-replication-temp-files
description: Reproduce/simulate Postgres autovacuum lag, table/index bloat, stale-statistics bad plans, temp-file disk spill (sort/hash-join/hash-aggregate), replication-slot WAL retention, and replica lag on a non-production RDS/Postgres instance. Use when asked to demonstrate, drill, or test detection/remediation for autovacuum falling behind, dead tuples not being reclaimed, index bloat, work_mem-starved queries spilling to disk, an inactive/stalled replication slot growing WAL, or write-surge replica lag.
---

# Autovacuum / Bloat / Replication / Temp Files — Drill Scripts

Runnable reproductions of the failure modes described in the SysCloud Postgres/RDS
investigation docs (`gpt-docs/`), covering four related categories that tend to
show up together on an incident: autovacuum & bloat, replication, and temp files.

## Setup

1. Copy `../.env.example` to `.env` in the directory you'll run scripts from (repo
   root works fine) and fill in `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`.
   Point it at a **disposable, non-production** instance — every drill here creates
   real bloat, real temp files, or a real (if harmless) replication slot.
2. Run `01_setup_bloat_drill_tables.sql` once to create the shared table shells.
3. Run any drill script below from that same directory (so it can find `.env`).

## Non-interactive / agent mode

Every mutating script calls the shared `confirm_drill` helper (from
`../_lib/env.sh`), which now just prints a banner and fires immediately —
no typed-`yes` gate to get past. `--yes`/`-y`/`DRILL_YES=1` are still
accepted (harmlessly) for backward compatibility.

Read-only diagnostic scripts (`02_bloat_vacuum_diagnostic_sweep.sql`) never
called `confirm_drill` — they only query, never mutate.

## Automated full run

`run_all.sh` runs setup once, then launches all 9 drills (03-06, 08-10, plus
all 3 temp-spill sub-modes as 07-sort/07-hash/07-group) CONCURRENTLY (not
one at a time) to stack simultaneous IO/CPU load, then runs the diagnostic
sweep once every drill has finished — one command for the whole topic. No
fix/remediation or cleanup step: every drill leaves its condition in place.
Row counts are sized so each drill finishes in well under 20s. `--list`
previews the manifest; `--fast` (default) / `--full` (~2x the row counts,
still under 20s per drill) control drill size.

```bash
./run_all.sh --list                          # preview
DRILL_YES=1 ./run_all.sh                     # fast, full manifest
./run_all.sh --skip 07-hash,07-group --yes   # skip the two slower spill modes
```

`run_sequential.sh` is the one-drill-at-a-time counterpart: setup (01) runs
once, then the same 9 drills run in order and each finishes before the
next starts, then the script pauses on a manual Enter-to-continue prompt
before the next drill (not skipped by `--yes` — that gate is the point).
The shared stats reset before the temp-spill drills still happens once, up
front, since it's a one-time reset regardless of concurrency.

```bash
./run_sequential.sh --list             # preview
DRILL_YES=1 ./run_sequential.sh        # manual gate between drills
```

## Script catalog

| Script | Category | Reproduces |
|---|---|---|
| `01_setup_bloat_drill_tables.sql` | setup | Shared empty table shells + `pg_stat_statements` extension |
| `02_bloat_vacuum_diagnostic_sweep.sql` | detection | Full read-only sweep: dead tuples, wraparound risk, autovacuum workers, table/index sizes, stale stats, temp usage, replication slots/lag, long transactions |
| `03_simulate_table_bloat_update_churn.sh` | bloat | Heavy UPDATE/DELETE churn outpaces (auto)vacuum |
| `04_simulate_index_bloat.sh` | bloat | Indexes bloat faster than their table after repeated updates |
| `05_simulate_autovacuum_worker_starvation.sh` | autovacuum | Multiple large tables eligible for vacuum at once → worker contention (approximation) |
| `06_simulate_stale_statistics_bad_plan.sh` | autovacuum | Disabled autoanalyze + data-shape change → bad query plan until `ANALYZE` |
| `07_simulate_temp_file_spill.sh` | temp files | `work_mem`-starved sort / hash-join / hash-aggregate spills to disk (`sort\|hash_join\|group_by` modes) |
| `08_simulate_create_index_temp_spike.sh` | temp files | `CREATE INDEX` itself spills / consumes `maintenance_work_mem` |
| `09_simulate_replication_slot_wal_retention.sh` | replication | Inactive logical replication slot retains WAL, storage shrinks with no obvious cause |
| `10_simulate_replica_lag_write_surge.sh` | replication | Primary write surge causes replica lag (full replica-side observation needs `REPLICA_PGHOST` set to a real read replica) |

See `README.md` in this folder for full usage examples and source-doc references.

## Safety

- Non-production instances only.
- Bloat/temp-file/WAL drills consume real disk and are left in place — there
  is no cleanup script — so hunters have a real window to detect them.
- `09` creates a real logical replication slot that is never dropped. Confirm
  it won't collide with a legitimate consumer (DMS/Debezium/etc.) on a shared
  non-prod instance before running.
- Never point `PGHOST`/`REPLICA_PGHOST` at a production endpoint.
