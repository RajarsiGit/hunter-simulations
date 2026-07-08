# Autovacuum / Bloat / Replication / Temp Files — Drill Scripts

Simulation/reproduction scripts for the fourth `simulations/` topic. Derived from
`gpt-docs/ChatGPT-RDS PostgreSQL Investigation Guide.md` (§3 Autovacuum & Bloat,
§4 Replication, §5 Temp Files), `gpt-docs/ChatGPT-RDS Postgres Issue Guide.md`
(storage/WAL investigation + scenarios), and
`gpt-docs/ChatGPT-RDS PostgreSQL Infra Monitoring.md` (simulation scenarios 3-5).

No prior top-level script folder existed for this topic — everything here is new,
following the same conventions as `../01-connection-exhaustion` and
`../02-locks-deadlocks-blocking-queries`: `.env`-based credentials via
`../_lib/env.sh`, `confirm_drill` safety confirmation (bypass with `--yes`/`-y`/
`DRILL_YES=1`), `application_name` tagging per drill session, non-production only.

## Setup

```bash
# 1. Copy and fill in credentials
cp ../.env.example .env

# 2. Create shared drill tables (idempotent)
set -a; source .env; set +a
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
     -f 01_setup_bloat_drill_tables.sql
```

## Script catalog

| File | Reproduces | Source |
|---|---|---|
| `01_setup_bloat_drill_tables.sql` | Shared setup — `bloat_drill_records`, `wal_drill_records`, `pg_stat_statements` | — |
| `02_bloat_vacuum_diagnostic_sweep.sql` | Full first-response detection sweep (14 sections) | Investigation Guide §3.3/§4.3/§5.3, Issue Guide storage/WAL checklists |
| `03_simulate_table_bloat_update_churn.sh` | Heavy UPDATE/DELETE churn outpaces autovacuum — `n_dead_tup` stays high even after `VACUUM` | Investigation Guide §3.5 (Scenario A1), Issue Guide §3.3 Scenario 3 |
| `04_simulate_index_bloat.sh` | Indexes on a churn table bloat faster than the table itself | Investigation Guide §3.8 (Scenario A4), Issue Guide §3.3 Scenario 2 |
| `05_simulate_autovacuum_worker_starvation.sh` | N large tables become vacuum-eligible together → worker contention in `pg_stat_progress_vacuum` (approximation — see script header) | Investigation Guide §3.7 (Scenario A3) |
| `06_simulate_stale_statistics_bad_plan.sh` | Autoanalyze disabled + data-shape skew → bad `EXPLAIN` estimate until manual `ANALYZE` | Investigation Guide §3.9 (Scenario A5) |
| `07_simulate_temp_file_spill.sh` | `work_mem`-starved sort / hash join / hash aggregate spills to disk (`sort\|hash_join\|group_by`) | Investigation Guide §5.5-5.7 (Scenarios C1-C3), Issue Guide §3.3 Scenario 4 |
| `08_simulate_create_index_temp_spike.sh` | `CREATE INDEX` build itself spends temp/`maintenance_work_mem` | Investigation Guide §5.8 (Scenario C4) |
| `09_simulate_replication_slot_wal_retention.sh` | Inactive logical replication slot retains WAL; storage shrinks with no obvious cause | Investigation Guide §4.7 (Scenario B3), Issue Guide §4.3 WAL Scenarios 1-2 |
| `10_simulate_replica_lag_write_surge.sh` | Primary write surge → replica lag (full replica-side check needs `REPLICA_PGHOST`) | Investigation Guide §4.5-4.6 (Scenarios B1-B2) |
| `11_cleanup_bloat_drill.sql` | Terminates drill sessions, drops the drill replication slot, drops all drill tables | — |

**Not independently scripted (diagnostic-only / needs infrastructure a single script
can't provision):**
- **Transaction ID wraparound** — forcing genuine wraparound needs billions of real
  transactions; `02`'s §3 query (`age(datfrozenxid)`) is the detection tool, there's
  no safe way to drill the failure itself.
- **DMS/CDC consumer lag** — `09` reproduces the WAL-retention *signal* an inactive
  slot produces; a real broken DMS task requires an actual DMS replication
  instance, which is out of scope for a single script.
- **Full replica lag observation** (`10`) needs a real RDS read replica attached to
  the drill instance (`REPLICA_PGHOST`) to see the replica-side `replay_delay`; without
  one you still get the primary-side write-surge + `pg_stat_replication` half.
- **Long-transaction-blocks-vacuum** is drilled in `../02-locks-deadlocks-blocking-queries/12_simulate_long_txn_vacuum_bloat.sh` (ported from the old `21_simulate_long_txn_vacuum_bloat.sh`) — not duplicated here since it's fundamentally a locking/snapshot scenario.

## Automated full run

`run_all.sh` runs setup, all 9 drills (including all 3 temp-file-spill
sub-modes), the diagnostic sweep, then cleanup — one command instead of
stepping through 01-11 by hand.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest
DRILL_YES=1 ./run_all.sh

# Skip the two slower temp-spill sub-modes
./run_all.sh --skip 07-hash,07-group --yes

# Doc-example scale (multi-million-row inserts, closer to a real incident)
./run_all.sh --full --yes
```

## Quick-start examples

```bash
# Detection first — always safe, no confirmation needed
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
     -f 02_bloat_vacuum_diagnostic_sweep.sql

# Drill A — table bloat from update churn (agent-friendly non-interactive run)
./03_simulate_table_bloat_update_churn.sh 500000 50 --yes

# Drill B — index bloat
DRILL_YES=1 ./04_simulate_index_bloat.sh 500000

# Drill C — autovacuum worker starvation across 3 tables
./05_simulate_autovacuum_worker_starvation.sh 3 1000000 --yes

# Drill D — stale statistics causing a bad plan
./06_simulate_stale_statistics_bad_plan.sh 500000 --yes

# Drill E — temp file spill, three modes
./07_simulate_temp_file_spill.sh sort 5000000 --yes
./07_simulate_temp_file_spill.sh hash_join 2000000 --yes
./07_simulate_temp_file_spill.sh group_by 5000000 --yes

# Drill F — CREATE INDEX temp spike
./08_simulate_create_index_temp_spike.sh 5000000 --yes

# Drill G — inactive replication slot retains WAL
./09_simulate_replication_slot_wal_retention.sh 2000000 --yes

# Drill H — write-surge replica lag (primary-only, or full with a real replica)
./10_simulate_replica_lag_write_surge.sh 3000000 --yes
REPLICA_PGHOST=<read-replica-endpoint> ./10_simulate_replica_lag_write_surge.sh 3000000 --yes

# Cleanup everything from this topic
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
     -f 11_cleanup_bloat_drill.sql
```

## Conventions

- All scripts source `../_lib/env.sh`, which loads `.env` from the current working
  directory and exports `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`.
- Mutating scripts call `confirm_drill "<message>" "$@"` — bypass with `--yes`/`-y`
  or `DRILL_YES=1` for non-interactive/agent runs. Read-only `.sql` diagnostic
  files skip confirmation entirely.
- Every drill session is tagged via `application_name` (`drill_av_*`,
  `drill_index_bloat*`, `drill_temp_spill_*`, `drill_repl_slot_wal*`,
  `drill_replica_lag_writer*`) so it's trivially identifiable in
  `pg_stat_activity` and cleanly removable via `11_cleanup_bloat_drill.sql`.
- Never point `PGHOST`/`REPLICA_PGHOST` at a production endpoint.
