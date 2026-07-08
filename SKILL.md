---
name: simulations
description: Run the full DBA drill suite (all four simulations/ topics — connection exhaustion, locks/deadlocks/blocking, slow queries, autovacuum/bloat/replication/temp files) or a single topic end-to-end with one command, instead of invoking individual drill/detection/cleanup scripts by hand. Use when asked to run/automate/drill "the whole set", "everything", "all the drills", "the full suite", or to run one topic's complete setup→drill→detect→cleanup cycle in a single shot, on a non-production Postgres/RDS instance.
---

# DBA Drill Suite — Automated Orchestration

Every topic under `simulations/` (`01-connection-exhaustion`,
`02-locks-deadlocks-blocking-queries`, `03-slow-queries`,
`04-autovacuum-bloat-replication-temp-files`) has its own `run_all.sh` that
sequences that topic's full manifest — setup → every drill → detection →
cleanup — behind one command with a pass/fail summary. `simulations/run_all.sh`
runs all four topics' `run_all.sh` in sequence (never in parallel — they
share one instance, and interleaved drills would make the resulting
`pg_stat_activity`/log signal unreadable). Reach for this skill instead of
invoking each topic's individual `NN_simulate_*`/diagnostic/cleanup scripts
one at a time when the ask is "run everything" or "run this whole topic".

The per-topic skills (`01-connection-exhaustion`,
`02-locks-deadlocks-blocking-queries`, `03-slow-queries`,
`04-autovacuum-bloat-replication-temp-files`) still own the detailed script
catalogs — use those when the ask is about one specific drill.

## Setup

Copy `simulations/.env.example` to `simulations/.env` (run from the repo
root) and fill in `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` at minimum —
plus `PGBOUNCER_HOST`, `DRILL_ROLE`/`DRILL_ROLE_PASSWORD` if those topics are
in scope. The top-level `run_all.sh` exports these once and every topic
subprocess inherits them — no per-topic `.env` needed.

## Non-interactive / agent use

`DRILL_YES=1` (set once in `simulations/.env`) or a per-invocation `--yes`
is the user's standing authorization to run any script in this catalog
against the configured target — the same convention as every individual
drill script. When it's set, invoke `run_all.sh` scripts directly; no need
to separately pause and ask before each run. Omitting it falls back to the
interactive typed-`yes` prompt inside each drill, which will hang an
unattended agent run — always pass `--yes` or rely on `DRILL_YES=1`.

## Usage

```bash
# Preview what a full-suite run would do — no DB changes
simulations/run_all.sh --list

# Run the whole suite, fast scale, non-interactive
DRILL_YES=1 simulations/run_all.sh

# Run the whole suite at doc-example scale (slower, closer to a real incident)
simulations/run_all.sh --full --yes

# Only specific topics (1=connection-exhaustion, 2=locks, 3=slow-queries, 4=bloat/replication)
simulations/run_all.sh --topics 3,4 --yes

# One topic only, run directly (equivalent to --topics N from the top level)
simulations/03-slow-queries/run_all.sh --yes
simulations/04-autovacuum-bloat-replication-temp-files/run_all.sh --skip 07-hash,07-group --yes
```

Every `run_all.sh` (top-level and per-topic) supports:

| Flag | Meaning |
|---|---|
| `--list` | Print the resolved manifest (with actual args) and exit — runs nothing. Always safe to use for a preview before committing to `--yes`. |
| `--fast` (default) | Small scale/duration — a full run finishes in minutes. |
| `--full` | Doc-example scale (matches each topic README's quick-start numbers) — slower, closer to a real incident's shape. |
| `--only <ids>` / `--skip <ids>` | Narrow a topic's manifest to specific script ids (comma list). Detection and cleanup steps always run regardless — they're never silently skipped by `--only`. Top-level only: `--topics <1-4 list>` selects which topics run at all. |
| `--no-cleanup` | Leave drill objects/sessions in place after the run (for manual follow-up poking). Default is to clean up. |
| `--yes` / `-y` | Non-interactive — same meaning as in every individual drill script (or set `DRILL_YES=1`). |

Topic 02's script 16 (`simulate_connection_exhaustion.sh`) overlaps topic
01's whole purpose — the top-level `run_all.sh` automatically passes
`--skip 16` to topic 02 when both topics 1 and 2 are in scope (disable with
`--no-dedupe-overlaps`).

## Output

Every step's full output is captured under
`run_all_logs/<timestamp>/<topic>/NNN_<step>.log` at whichever level you
invoked from (top-level runs nest each topic's logs under its own
subdirectory). A pass/fail summary table with per-step timing prints at the
end of every run.

## Typical flow for an agent

1. `simulations/run_all.sh --list` (or a specific topic's `--list`) to
   confirm the manifest matches what was asked for.
2. Run it for real with `--yes` (fast scale unless the user asked for
   realistic/doc-example scale, in which case add `--full`).
3. Read the summary table — any non-zero exit needs a look at that step's
   log file before declaring the drill run complete.
4. Cleanup runs automatically at the end of every topic; only skip it
   (`--no-cleanup`) if the user explicitly wants to keep poking at the
   drill state afterward.

See `simulations/README.md` for the full topic index and per-topic
`README.md`/`SKILL.md` for each topic's individual script catalog.
