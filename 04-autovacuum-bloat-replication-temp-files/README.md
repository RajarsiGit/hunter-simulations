# Autovacuum / Bloat / Replication / Temp Files — Drill Scripts

Simulation/reproduction scripts for the fourth `simulations/` topic. Derived from
`gpt-docs/ChatGPT-RDS PostgreSQL Investigation Guide.md` (§3 Autovacuum & Bloat,
§4 Replication, §5 Temp Files), `gpt-docs/ChatGPT-RDS Postgres Issue Guide.md`
(storage/WAL investigation + scenarios), and
`gpt-docs/ChatGPT-RDS PostgreSQL Infra Monitoring.md` (simulation scenarios 3-5).

No prior top-level script folder existed for this topic — everything here is new,
following the same conventions as `../01-connection-exhaustion` and
`../02-locks-deadlocks-blocking-queries`: `.env`-based credentials via
`../_lib/env.sh`, `confirm_drill` printing a banner and firing immediately
(no confirmation gate — `--yes`/`-y`/`DRILL_YES=1` still accepted but no
longer required), `application_name` tagging per drill session,
non-production only.

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

No fix/remediation or cleanup scripts are included in this folder — every
drill fires immediately and leaves its condition in place (bloat
un-vacuumed, indexes un-reindexed, statistics stale, the replication slot
un-dropped), guaranteeing at least a 90s observation window, so the hunters
have a real window to detect them. `run_all.sh` also launches all 9 drills
concurrently by default to stack simultaneous IO/CPU load.

## Detectability by the live hunters

Every mutating drill was checked against the actual hunter definitions
(`C:\SysCloud\Production\AI-Hunters\actions\slow-queries.jsonc` and
`actions\autovacuum-bloat-replication-temp-files.jsonc`, plus their
`queries\*.sql` files) rather than assumed — table/index bloat, autovacuum-
disabled, and stale-stats checks all live in the **slow-queries** hunter, not
this topic's own hunter, which only owns temp-file-spill + config-hygiene:

| Script | Check(s) | Threshold |
|---|---|---|
| `03`, `04` | T-3/T-4 `table_critical_bloat`/`table_high_bloat` | dead_tup_ratio > 0.60 crit / 0.30 warn, total_tuples > 10000 |
| `03`, `04` | AV-1/AV-2 `autovacuum_disabled`(_bloated) | autovacuum_enabled=false (+ dead_tup_ratio > 0.20 for AV-2) |
| `06` | ST-1/ST-2 `stats_never_analyzed`/`stats_stale` | n_live_tup > 100000, ANALYZE never run or > 7 days stale |
| `07`, `08` | TF-1/TF-2 `temp_spill_warning`/`_critical` (this topic's hunter) | temp_bytes_per_hour >= 1 GiB warn / >= 25 GiB crit |
| `09` | RS-1/RS-2 `slot_lag_warning`/`_critical` | inactive slot retaining >= 1 GiB / >= 10 GiB WAL |
| `10` | R-1/R-2 `replica_lag_warning`/`_critical` | replay lag >= 100 MiB / >= 1 GiB — **needs a real attached replica; cannot fire otherwise, at any row count** |
| `05` | none directly — see script header | manual VACUUM is query_type='user', not 'autovacuum', so a big enough one trips Q-1/Q-2 (`query_slow`/`query_critical`, >=30s/>=1800s) instead of `autovacuum_stuck` |

Gaps — real checks this folder's scripts do **not** exercise (noted here so
nobody assumes coverage that isn't there): **QC-1** `temp_concurrency_storm`
(>=20 concurrent sessions running the identical spill-prone query) has no
script targeting it — 07/08 each run one query per invocation, not a fan-out
of concurrent identical ones. **CH-1..CH-5** (config-hygiene: `log_temp_files`,
`temp_file_limit`, `pg_stat_statements` presence, activity-snapshot mechanism,
role-level `temp_file_limit`) are static RDS-parameter-group/extension checks,
not something a load-generating drill can toggle.

`07`/`08` exploit a specific mechanic in the temp-spill rate calculation: it's
`temp_bytes` (cumulative since `stats_reset`) divided by hours-since-reset,
floored at 1h — so resetting stats immediately before spilling pins the
denominator at 1.0 for the first hour, making the rate equal the raw bytes
spilled. `run_all.sh` resets once, shared across all four temp-spill
sub-drills, so their spills stack toward the 25 GiB/h critical floor instead
of each resetting away what its siblings already contributed.

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

`run_all.sh` runs setup once, then launches all 9 drills (including all 3
temp-file-spill sub-modes) CONCURRENTLY (not one at a time) to stack
simultaneous IO/CPU load, then runs the diagnostic sweep once every drill
has finished — one command instead of stepping through 01-10 by hand. No
cleanup step.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest
DRILL_YES=1 ./run_all.sh

# Skip the two slower temp-spill sub-modes
./run_all.sh --skip 07-hash,07-group --yes

# Even more extreme scale (tens-of-millions-row inserts, closer to or past a real incident)
./run_all.sh --full --yes
```

## Quick-start examples

```bash
# Detection first — always safe, no confirmation needed
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
     -f 02_bloat_vacuum_diagnostic_sweep.sql

# Drill A — table bloat from update churn (agent-friendly non-interactive run)
./03_simulate_table_bloat_update_churn.sh 1000000 80 --yes

# Drill B — index bloat
DRILL_YES=1 ./04_simulate_index_bloat.sh 1000000

# Drill C — autovacuum worker starvation across 5 tables
./05_simulate_autovacuum_worker_starvation.sh 5 3000000 --yes

# Drill D — stale statistics causing a bad plan
./06_simulate_stale_statistics_bad_plan.sh 1000000 --yes

# Drill E — temp file spill, three modes (each resets stats itself when run
# standalone like this — see script header; set SKIP_STATS_RESET=1 if you
# want their spills to stack instead)
./07_simulate_temp_file_spill.sh sort 8000000 --yes
./07_simulate_temp_file_spill.sh hash_join 4000000 --yes
./07_simulate_temp_file_spill.sh group_by 8000000 --yes

# Drill F — CREATE INDEX temp spike
./08_simulate_create_index_temp_spike.sh 8000000 --yes

# Drill G — inactive replication slot retains WAL (check disk headroom first — see script header)
./09_simulate_replication_slot_wal_retention.sh 6000000 --yes

# Drill H — write-surge replica lag (primary-only, or full with a real replica —
# R-1/R-2 CANNOT fire without REPLICA_PGHOST pointed at a real attached replica)
./10_simulate_replica_lag_write_surge.sh 8000000 --yes
REPLICA_PGHOST=<read-replica-endpoint> ./10_simulate_replica_lag_write_surge.sh 8000000 --yes
```

## Conventions

- All scripts source `../_lib/env.sh`, which loads `.env` from the current working
  directory and exports `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`.
- Mutating scripts call `confirm_drill "<message>" "$@"`, which now only
  prints a banner and fires immediately — no confirmation gate to bypass.
  Read-only `.sql` diagnostic files skip it entirely (they never called it).
- Every drill session is tagged via `application_name` (`drill_av_*`,
  `drill_index_bloat*`, `drill_temp_spill_*`, `drill_repl_slot_wal*`,
  `drill_replica_lag_writer*`) so it's trivially identifiable in
  `pg_stat_activity`. There is no cleanup script — drill tables, the
  replication slot, and any sessions are left in place after the run.
- Never point `PGHOST`/`REPLICA_PGHOST` at a production endpoint.
