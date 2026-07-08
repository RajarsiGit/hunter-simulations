# Slow Queries — Drill Scripts

Reproducible simulation/detection scripts for the **Slow Queries / Performance
Optimization** runbook topic. Source material: `gpt-docs/ChatGPT-RDS PostgreSQL
Performance Optimization.md` (scenarios 1-12) and `gpt-docs/ChatGPT-RDS Postgres
Issue Guide.md` (§5.2/§5.3 CPU investigation + simulation scenarios).

⚠️ **NON-PRODUCTION USE ONLY.** Run only against a disposable/drill database —
these scripts create real schema objects, real data, and real query load.

## Conventions

- Credentials come from a `.env` file in the current working directory (see
  `simulations/.env.example`) via the shared `simulations/_lib/env.sh`.
- Every mutating script fires immediately — `confirm_drill` prints a banner
  only, no typed-`yes` gate (`--yes`/`DRILL_YES=1` still accepted, no longer
  required) — see `SKILL.md` for details.
- Drill sessions tag themselves with a `drill_*` `application_name` so they're
  identifiable in `pg_stat_activity`.
- No fix/remediation or cleanup scripts are included — every drill only
  demonstrates the problem and leaves it in place (missing indexes, stale
  statistics, etc.), holding load for at least 180s (02/03/05) so the hunters
  have a real window to detect it. `run_all.sh` launches all 6 drills
  concurrently by default to stack simultaneous load.

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
| `02_simulate_missing_index_scan.sh` | Seq scan on `slowq_orders.status` (no index) | `Seq Scan`, `Rows Removed by Filter: many` in EXPLAIN — left unindexed |
| `03_simulate_function_wrapped_predicate.sh` | `lower(email) = ...` ignores a plain index on `email` | Plain index present but unused (still `Seq Scan`) — no expression index added |
| `04_simulate_offset_pagination.sh` | Deep `OFFSET N LIMIT 50` cost grows with `N` | Execution time scales with offset depth; keyset pagination (`WHERE created_at < cursor`) stays flat |
| `05_simulate_json_processing_spike.sh` | `data->>'status' LIKE 'a%'` on unindexed jsonb | High-CPU seq scan across all rows — left unindexed |
| `06_simulate_stale_statistics.sh` | Bulk insert without `ANALYZE`, autovacuum disabled, skews the planner's row estimate | `EXPLAIN` `rows=` estimate far off from actual — statistics left stale |
| `07_simulate_retry_storm.sh` | Concurrent app retries multiply load on an already-slow query | `pg_stat_activity` shows N sessions all running the same query under one `application_name` |
| `08_diagnostic_query_sweep.sql` | — (detection) | Full sweep: active queries, wait events, `pg_stat_statements` top/N+1 candidates, missing-index candidates, stale-stats candidates, session fan-out, index bloat |

## Automated full run

`run_all.sh` runs setup once, then launches all 6 drills CONCURRENTLY (not
one at a time) against the shared `slowq_*` tables to stack simultaneous
load, then runs the diagnostic sweep once every drill has finished — one
command instead of stepping through 01-08 by hand. No fix/remediation or
cleanup step.

```bash
# Preview the manifest without touching the DB
./run_all.sh --list

# Fast, non-interactive, full manifest
DRILL_YES=1 ./run_all.sh

# Doc-example scale
./run_all.sh --full --yes
```

## Quick-start examples

```bash
set -a; source .env; set +a

# Drill A — missing index
./02_simulate_missing_index_scan.sh --yes

# Drill B — function-wrapped predicate
./03_simulate_function_wrapped_predicate.sh --yes

# Drill C — offset vs. keyset pagination (read-only)
./04_simulate_offset_pagination.sh 250000

# Drill D — JSONB CPU spike
./05_simulate_json_processing_spike.sh --yes

# Drill E — stale statistics
./06_simulate_stale_statistics.sh --yes

# Drill F — retry storm
./07_simulate_retry_storm.sh 30 15 --yes

# Detection sweep
psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -f 08_diagnostic_query_sweep.sql
```

## Not scripted (needs manual/config action)

- **Stale statistics via `CREATE STATISTICS`** for correlated columns —
  mentioned in `06`'s output but not auto-applied.
- **Bad join plan (Scenario 8 in the source doc)** and **generic prepared-plan
  problem (Scenario 11)** — covered narratively in the source doc but not
  scripted here since they need multi-table join setup / `PREPARE` session
  state beyond this folder's shared tables; add a dedicated setup if needed.
- **`pg_trgm` / GIN index for arbitrary substring `LIKE '%x%'` matches** on
  the JSON status field — mentioned in `05`'s output but not scripted.
