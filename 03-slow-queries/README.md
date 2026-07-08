# Slow Queries — Drill Scripts

Reproducible simulation/detection/fix scripts for the **Slow Queries / Performance
Optimization** runbook topic. Source material: `gpt-docs/ChatGPT-RDS PostgreSQL
Performance Optimization.md` (scenarios 1-12) and `gpt-docs/ChatGPT-RDS Postgres
Issue Guide.md` (§5.2/§5.3 CPU investigation + simulation scenarios).

⚠️ **NON-PRODUCTION USE ONLY.** Run only against a disposable/drill database —
these scripts create real schema objects, real data, and real query load.

## Conventions

- Credentials come from a `.env` file in the current working directory (see
  `simulations/.env.example`) via the shared `simulations/_lib/env.sh`.
- Every mutating script requires a typed `yes`, unless bypassed with `--yes`
  or `DRILL_YES=1` (agent/non-interactive mode) — see `SKILL.md` for details.
- Drill sessions tag themselves with a `drill_*` `application_name` so they're
  identifiable in `pg_stat_activity` and easy to clean up.
- Scripts with a `simulate`/`fix` mode default to `simulate` (safe, shows the
  problem) — pass `fix` to also apply and verify the real-world remediation.

## Setup (run once)

```bash
set -a; source .env; set +a
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 01_setup_slow_query_tables.sql
```

Creates `slowq_orders` (300k rows, skewed `status` distribution), `slowq_customers`
(50k rows), and `slowq_json_events` (300k rows) — none with indexes beyond their
primary key, by design.

## Drill scripts

| File | Reproduces | Key observation |
|---|---|---|
| `02_simulate_missing_index_scan.sh` | Seq scan on `slowq_orders.status` (no index) | `Seq Scan`, `Rows Removed by Filter: many` in EXPLAIN; `fix` mode flips it to `Index Scan` |
| `03_simulate_function_wrapped_predicate.sh` | `lower(email) = ...` ignores a plain index on `email` | Plain index present but unused (still `Seq Scan`); `fix` adds an expression index on `lower(email)` |
| `04_simulate_offset_pagination.sh` | Deep `OFFSET N LIMIT 50` cost grows with `N` | Execution time scales with offset depth; keyset pagination (`WHERE created_at < cursor`) stays flat |
| `05_simulate_json_processing_spike.sh` | `data->>'status' LIKE 'a%'` on unindexed jsonb | High-CPU seq scan across all rows; `fix` adds an expression index on `(data->>'status')` |
| `06_simulate_stale_statistics.sh` | Bulk insert without `ANALYZE` skews the planner's row estimate | `EXPLAIN` `rows=` estimate far off from actual; `fix` runs `ANALYZE` and the estimate corrects |
| `07_simulate_retry_storm.sh` | Concurrent app retries multiply load on an already-slow query | `pg_stat_activity` shows N sessions all running the same query under one `application_name` |
| `08_diagnostic_query_sweep.sql` | — (detection) | Full sweep: active queries, wait events, `pg_stat_statements` top/N+1 candidates, missing-index candidates, stale-stats candidates, session fan-out, index bloat |
| `09_cleanup_slow_query_drill.sql` | — (cleanup) | Terminates `drill_*` sessions, drops `slowq_orders`/`slowq_customers`/`slowq_json_events` |

## Automated full run

`run_all.sh` runs setup, all 6 drills, the diagnostic sweep, then cleanup —
one command instead of stepping through 01-09 by hand.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest (simulate mode only)
DRILL_YES=1 ./run_all.sh

# Also run `fix` mode for the scripts that support it (02/03/05/06)
./run_all.sh --with-fix --yes

# Doc-example scale
./run_all.sh --full --yes
```

## Quick-start examples

```bash
set -a; source .env; set +a

# Drill A — missing index
./02_simulate_missing_index_scan.sh simulate
./02_simulate_missing_index_scan.sh fix --yes

# Drill B — function-wrapped predicate
./03_simulate_function_wrapped_predicate.sh simulate --yes
./03_simulate_function_wrapped_predicate.sh fix --yes

# Drill C — offset vs. keyset pagination (read-only)
./04_simulate_offset_pagination.sh 250000

# Drill D — JSONB CPU spike
./05_simulate_json_processing_spike.sh fix --yes

# Drill E — stale statistics
./06_simulate_stale_statistics.sh fix --yes

# Drill F — retry storm
./07_simulate_retry_storm.sh 30 15 --yes

# Detection sweep
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 08_diagnostic_query_sweep.sql

# Cleanup
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 09_cleanup_slow_query_drill.sql
```

## Not scripted (needs manual/config action)

- **Stale statistics via `CREATE STATISTICS`** for correlated columns —
  `06`'s `fix` mode covers the basic `ANALYZE` case; multi-column statistics
  objects are mentioned in script output but not auto-applied.
- **Bad join plan (Scenario 8 in the source doc)** and **generic prepared-plan
  problem (Scenario 11)** — covered narratively in the source doc but not
  scripted here since they need multi-table join setup / `PREPARE` session
  state beyond this folder's shared tables; add a dedicated setup if needed.
- **`pg_trgm` / GIN index for arbitrary substring `LIKE '%x%'` matches** on
  the JSON status field — `05`'s expression index only accelerates prefix
  matches (`LIKE 'a%'`).
