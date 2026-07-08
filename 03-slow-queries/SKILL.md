---
name: 03-slow-queries
description: Reproduce and resolve RDS PostgreSQL slow-query scenarios — missing-index sequential scans, function-wrapped predicates that defeat an index, deep OFFSET pagination, JSONB field-extraction CPU spikes, stale planner statistics, application retry storms, and N+1 query patterns. Use when asked to simulate, drill, reproduce, or investigate slow/high-CPU queries, bad execution plans, or pg_stat_statements analysis.
---

# Slow Queries Drills

Reproducible, agent-runnable simulations for the "Slow Queries / Performance
Optimization" runbook topic, derived from `gpt-docs/ChatGPT-RDS PostgreSQL
Performance Optimization.md` and `gpt-docs/ChatGPT-RDS Postgres Issue Guide.md`.

⚠️ **NON-PRODUCTION USE ONLY.** These scripts create real load and real schema
changes (indexes) against whatever `PGDATABASE` you point them at. Always run
against a disposable/drill database.

## Setup

1. Copy `simulations/.env.example` to `.env` in the directory you'll run
   scripts from (repo root works) and fill in `PGHOST`/`PGPORT`/`PGUSER`/
   `PGPASSWORD`/`PGDATABASE`.
2. Run the shared setup once: `psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 01_setup_slow_query_tables.sql`
   (or `set -a; source .env; set +a` first if you don't want to pass `-h`/`-U` by hand).
3. Run any drill script directly, e.g. `./02_simulate_missing_index_scan.sh`.

## Detectability by the live slow-queries hunter

`simulate` mode in scripts `02`, `03`, `04`, and `05` now does two extra things
after the demonstration `EXPLAIN (ANALYZE, BUFFERS)` (which alone finishes in
well under a second and is invisible to a poll-based hunter):

1. Holds one session `state='active'` for ~35s (`hold_session_active` in
   `_lib/env.sh`) — crosses the `query_slow` / `query_critical` >=30s
   threshold in `AI-Hunters/actions/slow-queries.jsonc`.
2. Bursts ~1500 repeated scans in a single PL/pgSQL `DO` block
   (`run_seq_scan_burst`) — crosses the `seq_scan_tables` >1000-scan /
   >80%-ratio threshold in `AI-Hunters/queries/slow-queries/slow-queries-seq-scans.sql`.

So `simulate` now takes ~35-40s to complete instead of returning instantly —
that's expected, not a hang. `06` (stale statistics) additionally disables
per-table autovacuum and resets `slowq_orders`' stat counters before the bulk
insert, so `last_analyze`/`last_autoanalyze` reliably read NULL instead of
racing autovacuum's autoanalyze — do not run `06` back-to-back with `02`'s
seq-scan burst, since the stat reset also zeroes `seq_scan`/`idx_scan`.

Without this, a single one-shot drill query never crosses any real hunter
threshold — those are tuned for sustained/production-scale load, not a lone
manual `EXPLAIN`.

## Non-interactive / agent mode

Every script that mutates schema or data (creates an index, bulk-inserts, or
opens many connections) calls a shared `confirm_drill` guard that normally
blocks on a typed `yes`. For agent-driven runs (no TTY), pass `--yes` as an
argument or set `DRILL_YES=1` in `.env`/the environment — this is opt-in only,
never automatic, so an agent can never trigger a drill by accident just
because stdin isn't a terminal. Pure read-only `EXPLAIN`-only scripts (04)
skip the guard entirely.

## Automated full run

`run_all.sh` runs setup, all 6 drills (simulate mode by default), the
diagnostic sweep, and cleanup — one command for the whole topic. `--list`
previews the manifest; `--with-fix` also runs `fix` mode for 02/03/05/06;
`--fast` (default) / `--full` control offset depth / retry-storm size.

```bash
./run_all.sh --list                # preview
DRILL_YES=1 ./run_all.sh           # fast, simulate-only
./run_all.sh --with-fix --yes      # also demonstrate the remediation
```

## Script catalog

| Script | Reproduces | Mode arg |
|---|---|---|
| `01_setup_slow_query_tables.sql` | — (setup) | Creates `slowq_orders` (300k rows), `slowq_customers` (50k), `slowq_json_events` (300k), no non-PK indexes |
| `02_simulate_missing_index_scan.sh` | Seq scan from an unindexed filter column | `simulate` (default) \| `fix` |
| `03_simulate_function_wrapped_predicate.sh` | `lower(email) = ...` defeating a plain index | `simulate` (default) \| `fix` |
| `04_simulate_offset_pagination.sh` | Deep `OFFSET` pagination vs. keyset pagination | read-only, no confirm needed |
| `05_simulate_json_processing_spike.sh` | CPU spike from unindexed `jsonb ->> field` filtering | `simulate` (default) \| `fix` |
| `06_simulate_stale_statistics.sh` | Bad plan from stale `pg_stat_user_tables` statistics after bulk insert | `simulate` (default) \| `fix` (runs `ANALYZE`) |
| `07_simulate_retry_storm.sh` | Application retry storm multiplying load on an already-slow query | `[session_count] [retries_per_session]` |
| `08_diagnostic_query_sweep.sql` | — (detection) | Full first-response sweep: active queries, wait events, `pg_stat_statements` top/N+1 candidates, missing-index candidates, stale-stats candidates, session fan-out, index bloat |
| `09_cleanup_slow_query_drill.sql` | — (cleanup) | Terminates `drill_*` sessions, drops all `slowq_*` tables |

## Quick start

```bash
set -a; source .env; set +a

psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 01_setup_slow_query_tables.sql
./02_simulate_missing_index_scan.sh simulate
./02_simulate_missing_index_scan.sh fix --yes
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 08_diagnostic_query_sweep.sql
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 09_cleanup_slow_query_drill.sql
```

See `README.md` in this folder for the full script catalog and worked examples.
