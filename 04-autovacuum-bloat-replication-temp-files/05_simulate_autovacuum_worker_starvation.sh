#!/usr/bin/env bash
# =============================================================================
# 05_simulate_autovacuum_worker_starvation.sh
# Autovacuum/Bloat DRILL — Autovacuum Worker Starvation
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §3.7 (Scenario A3).
#
# Reproduces (approximates): several large tables become eligible for vacuum
# at once, and RDS PostgreSQL has a limited autovacuum_max_workers pool, so
# some tables wait. This drill creates N large bloated tables and fires
# manual VACUUM (ANALYZE) against all of them concurrently to demonstrate
# what worker contention looks like in pg_stat_progress_vacuum — a true
# autovacuum-triggered starvation additionally depends on autovacuum_naptime/
# thresholds and instance load, which this script cannot force deterministically,
# so treat this as a contention *approximation*, not a byte-for-byte reproduction.
#
# Detectability — IMPORTANT correction verified against queries/slow-queries/
# slow-queries.sql: this script's own worker-contention scenario has no
# dedicated hunter check (autovacuum_stuck / Q-3 in actions/slow-queries.jsonc
# requires row.query_type == 'autovacuum', which the classifier derives from
# `query ILIKE 'autovacuum:%'` — a MANUAL `VACUUM (ANALYZE) ...` statement,
# which is what this script runs, never matches that pattern and is
# classified query_type == 'user' instead). The practical consequence: if
# ROWS_PER_TABLE is large enough that a manual VACUUM genuinely takes a
# while, it instead trips the ordinary slow-query checks —
#   Q-1 query_slow     warning  — user query active >= 30s
#   Q-2 query_critical critical — user query active >= 1800s (30 min)
# — on the VACUUM statement itself, not autovacuum_stuck. Sized up so the
# concurrent manual VACUUMs plausibly clear Q-1's 30s floor on a small
# instance; hitting Q-2's 1800s floor would need considerably more data or a
# much slower disk than a typical drill box, so treat Q-1 as the realistic
# target here, not Q-2.
#
# Usage:
#   ./05_simulate_autovacuum_worker_starvation.sh [table_count] [rows_per_table] [--yes]
#
# Defaults: table_count=5, rows_per_table=100000 — sized so the whole drill
# finishes in well under 20s. This is small enough that the concurrent
# VACUUMs likely won't cross query_slow's 30s floor (Q-1) on their own — pass
# a larger rows_per_table for a slower drill with a realistic shot at that.
#
# Example: 5 tables, 100k rows each
#   ./05_simulate_autovacuum_worker_starvation.sh 5 100000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

TABLE_COUNT="${1:-5}"
ROWS_PER_TABLE="${2:-100000}"

confirm_drill "This creates ${TABLE_COUNT} large tables (${ROWS_PER_TABLE} rows each, av_starvation_drill_N), churns each with updates, then fires concurrent VACUUM (ANALYZE) against all of them to show worker contention in pg_stat_progress_vacuum." "$@"

echo ""
echo "=== DRILL: Autovacuum Worker Starvation (Investigation Guide §3.7 / Scenario A3) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | tables=${TABLE_COUNT} | rows_each=${ROWS_PER_TABLE}"

echo ""
echo "--- Current autovacuum worker capacity ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SHOW autovacuum_max_workers; SHOW autovacuum_naptime;
         SHOW autovacuum_vacuum_cost_delay; SHOW autovacuum_vacuum_cost_limit;"

for i in $(seq 1 "${TABLE_COUNT}"); do
    echo ""
    echo "--- Creating + seeding av_starvation_drill_${i} (${ROWS_PER_TABLE} rows) then churning ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
         -c "SET application_name = 'drill_av_starvation_seed_${i}';
             CREATE TABLE IF NOT EXISTS av_starvation_drill_${i} (
                 id bigserial PRIMARY KEY, payload text
             );
             INSERT INTO av_starvation_drill_${i} (payload)
             SELECT repeat(md5(random()::text), 20) FROM generate_series(1, ${ROWS_PER_TABLE})
             WHERE NOT EXISTS (SELECT 1 FROM av_starvation_drill_${i} LIMIT 1);
             UPDATE av_starvation_drill_${i} SET payload = repeat(md5(random()::text), 20)
             WHERE id % 3 = 0;" &
done
wait
echo "All ${TABLE_COUNT} tables seeded and churned."

echo ""
echo "--- Tables now eligible for vacuum (dead tuple counts) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT relname, n_dead_tup, last_autovacuum, autovacuum_count
         FROM pg_stat_user_tables
         WHERE relname LIKE 'av_starvation_drill_%'
         ORDER BY n_dead_tup DESC;"

echo ""
echo "--- Firing concurrent manual VACUUM (ANALYZE) against all ${TABLE_COUNT} tables ---"
echo "    (watch pg_stat_progress_vacuum in another terminal while this runs)"
for i in $(seq 1 "${TABLE_COUNT}"); do
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_av_starvation_vacuum_${i}';
             VACUUM (ANALYZE) av_starvation_drill_${i};" 2>&1 | sed "s/^/  [vacuum ${i}] /" &
done

echo ""
echo "--- pg_stat_progress_vacuum snapshot while vacuums are in flight ---"
sleep 1
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT pid, relid::regclass, phase, heap_blks_total, heap_blks_scanned, heap_blks_vacuumed
         FROM pg_stat_progress_vacuum;"

wait
echo ""
echo "Remediation levers (tune cautiously via parameter group, not blind global bumps):"
echo "  autovacuum_max_workers, autovacuum_vacuum_cost_limit, autovacuum_vacuum_cost_delay,"
echo "  maintenance_work_mem. For emergency single-table relief: VACUUM (ANALYZE) <table>;"
echo ""
ensure_min_duration 10
echo "Drill complete."
