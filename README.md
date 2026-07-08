# DBA Drill Simulations — Claude-Code / Agent Edition

A self-contained lab for practicing PostgreSQL/RDS incident response: point it at a
**non-production** instance, pick a topic, and it reproduces the failure mode on demand
(connection exhaustion, locks/deadlocks, slow queries, or autovacuum/bloat/replication/temp
files) so you can rehearse detection and recovery against a real, live symptom instead of a
transcript. Built for both humans (interactive drills, one script at a time) and agents
(non-interactive `--yes` runs, full-suite automation via `run_all.sh`).

Simulation and reproduction scripts for the four PostgreSQL/RDS incident
categories covered in `gpt-docs/`, generated from those ChatGPT transcripts
and (where a topic already had a script set) ported from the top-level
`connection-exhaustion/` and `locks-deadlocks-blocking-queries/` folders onto
a shared, agent-friendly convention:

- **Credentials via `.env`** — no exported env vars to remember, no
  hardcoded secrets. Copy `.env.example` to `.env` in whatever directory you
  run scripts from and fill it in.
- **Non-interactive-safe** — every destructive/mutating drill still asks
  `Type 'yes' to proceed`, but an agent (or CI) can pass `--yes` / set
  `DRILL_YES=1` to skip the prompt without ever risking an *accidental*
  auto-run (it's opt-in, not "skip because stdin isn't a TTY").
- **Claude Code skill-ready** — each topic folder has a `SKILL.md` with
  proper frontmatter (`name`, `description`) so it can be dropped into a
  skills directory (or referenced by an agent via the `Skill`/`Agent` tools)
  and picked up on the relevant trigger phrases.

```
simulations/
├── .env.example                                Credential template — copy to .env
├── _lib/env.sh                                  Shared: loads .env, confirm_drill(), strip_flags()
├── _lib/runner.sh                               Shared: step()/run_step() manifest runner for run_all.sh scripts
├── run_all.sh                                   Runs all 4 topics' run_all.sh in sequence
├── 01-connection-exhaustion/                    11 scripts + run_all.sh + SKILL.md + README.md
├── 02-locks-deadlocks-blocking-queries/         20 scripts + run_all.sh + SKILL.md + README.md
├── 03-slow-queries/                             9 scripts + run_all.sh + SKILL.md + README.md
├── 04-autovacuum-bloat-replication-temp-files/  11 scripts + run_all.sh + SKILL.md + README.md
└── README.md                                    This file
```

Each subfolder is self-contained: its own `README.md` catalogs every script
(what it reproduces, args, key observation), and its own `SKILL.md` is the
Claude-Code-facing summary — read that first if you're an agent deciding
which script to run.

## Quick start

```bash
cd simulations
cp .env.example .env
$EDITOR .env                      # PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE (+ PGBOUNCER_*/DRILL_ROLE* as needed)

# Human, interactive:
./01-connection-exhaustion/06_simulate_idle_in_transaction.sh 5 300 my_test_table

# Agent / non-interactive:
DRILL_YES=1 ./02-locks-deadlocks-blocking-queries/03_simulate_deadlock.sh
# or: ./03-slow-queries/02_simulate_missing_index_scan.sh simulate --yes
```

All scripts assume `.env` lives in the **current working directory** at
invocation time (per `_lib/env.sh`) — run them from `simulations/` itself, or
`cp .env` alongside wherever you invoke them from.

## Automated runs

Each topic folder has a `run_all.sh` that sequences that topic's full
manifest — setup → every drill → detection → cleanup — behind one command,
with a pass/fail summary at the end. There's also a top-level `run_all.sh`
that runs all four topics in sequence (never in parallel — they share the
same instance, and interleaved drills would make the resulting
`pg_stat_activity`/log signal unreadable).

```bash
cd simulations
cp .env.example .env && $EDITOR .env

# Preview the whole suite without touching the DB
./run_all.sh --list

# Run the whole suite, fast scale, non-interactive
DRILL_YES=1 ./run_all.sh

# Just one topic, doc-example scale
./03-slow-queries/run_all.sh --full --yes

# Just two topics from the top level
./run_all.sh --topics 1,4 --yes
```

Every `run_all.sh` supports `--list` (preview the resolved manifest, run
nothing), `--fast`/`--full` (scale), `--only`/`--skip` (narrow to specific
script ids), `--no-cleanup`, and `--yes`/`DRILL_YES=1`. See each script's
header comment (or its topic's `README.md`/`SKILL.md`) for the full flag
reference and topic-specific options. Full-run output is logged per-step
under `run_all_logs/<timestamp>/` at whichever level you invoked it from.

## Topic index

| Folder | Covers | Source docs |
|---|---|---|
| [`01-connection-exhaustion`](01-connection-exhaustion/README.md) | Idle-in-transaction floods, PgBouncer pool saturation (transaction & session mode), role/DB connection-limit breaches, plain idle-connection storms/leaks | `ChatGPT-ChatGPT - Senthil.md` (+ (1)), `ChatGPT-PgBouncer Connection Exhaustion.md`, `ChatGPT-RDS Postgres Issue Guide.md` §8 |
| [`02-locks-deadlocks-blocking-queries`](02-locks-deadlocks-blocking-queries/README.md) | Row/table locks, deadlocks, DDL-blocks-DML, advisory locks, FK contention, VACUUM FULL blocking, lock queue amplification, stuck-worker workflow blockage, automated incident RCA | `ChatGPT-RDS PostgreSQL Lock Investigation.md`, `ChatGPT-RDS PostgreSQL Lock Troubleshooting.md` |
| [`03-slow-queries`](03-slow-queries/README.md) | Missing-index scans, function-wrapped predicates, offset vs. keyset pagination, JSONB CPU spikes, stale planner statistics, retry storms | `ChatGPT-RDS PostgreSQL Performance Optimization.md`, `ChatGPT-RDS Postgres Issue Guide.md` §7 |
| [`04-autovacuum-bloat-replication-temp-files`](04-autovacuum-bloat-replication-temp-files/README.md) | Table/index bloat, autovacuum lag, stale-stats bad plans, temp-file disk spill, replication-slot WAL retention, replica lag | `ChatGPT-RDS PostgreSQL Investigation Guide.md`, `ChatGPT-RDS Postgres Issue Guide.md` §5–§6, `ChatGPT-RDS PostgreSQL Infra Monitoring.md` |

`ChatGPT-AWS RDS Cost Anomalies.md` was reviewed but is a cost/billing topic,
not an operational failure mode — out of scope for these four categories, no
scripts generated from it.

## Relationship to the original `connection-exhaustion/` and
`locks-deadlocks-blocking-queries/` folders

Those two folders are untouched and still valid — they're the original
runbook-mapped drill set (env-var-only, interactive-only confirmation). This
`simulations/` tree supersedes them for agent-driven use: topics 1 and 2 here
are a straight behavioral port (same scenarios, same args) onto the `.env` +
`--yes` convention, plus a handful of new scripts per topic where the
`gpt-docs` transcripts surfaced a scenario that wasn't already scripted.
Topics 3 and 4 are entirely new.

## Safety

Every drill script is **non-production only**: it tags its sessions with a
distinct `application_name` (`drill_*`) for easy identification and cleanup,
and gates anything that mutates state behind `confirm_drill()` (typed `yes`,
or explicit `--yes`/`DRILL_YES=1`). Never point `.env` at a production
endpoint when running a script from this tree. Each topic folder has its own
cleanup script to remove drill sessions/tables when you're done.
