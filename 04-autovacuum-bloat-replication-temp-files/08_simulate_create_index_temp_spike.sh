#!/usr/bin/env bash
# =============================================================================
# 08_simulate_create_index_temp_spike.sh
# Temp Files DRILL — CREATE INDEX Causes a Temp File / I-O Spike
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 07_simulate_temp_file_spill.sh (sort
#     mode) to have created temp_spill_sort_drill, OR run standalone —
#     this script creates the table itself if missing.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §5.8 (Scenario C4).
#
# Reproduces: building a non-trivial index (here, on a large text column)
# can itself spend temp files / maintenance_work_mem during the sort phase
# of the index build. Shows pg_stat_progress_create_index while it runs.
#
# Detectability — same TF-1/TF-2 signal as 07 (verified against queries/
# autovacuum-bloat-replication-temp-files/temp-usage.sql, thresholds in
# actions/autovacuum-bloat-replication-temp-files.jsonc): a low
# maintenance_work_mem relative to ROW_COUNT makes the index build's sort
# phase spill, adding to this database's cumulative pg_stat_database.
# temp_bytes just like 07's queries do. Same TF-1 (>=1 GiB/h) / TF-2
# (>=25 GiB/h) thresholds, same 1h-floor-since-reset mechanic — see 07's
# header for the full mechanic explanation. SKIP_STATS_RESET=1 applies here
# too, for the same reason (stacking with 07 under run_all.sh).
#
# Usage:
#   ./08_simulate_create_index_temp_spike.sh [row_count] [--yes]
#
# Default row_count=600000, matching 07's reduced sort/group_by scale —
# sized so the whole drill finishes in well under 20s.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-600000}"

confirm_drill "This creates temp_spill_sort_drill if missing (${ROW_COUNT} rows) and builds a non-concurrent index on its payload column, monitoring pg_stat_progress_create_index." "$@"

echo ""
echo "=== DRILL: CREATE INDEX Causes Temp Spike (Investigation Guide §5.8 / Scenario C4) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT}"

if [[ -z "${SKIP_STATS_RESET:-}" ]]; then
    echo ""
    echo "--- Resetting ${PGDATABASE}'s stats (see 07's header for the TF-1/TF-2"
    echo "    1h-floor-since-reset mechanic this exploits) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SELECT pg_stat_reset();"
else
    echo ""
    echo "--- Skipping stats reset (SKIP_STATS_RESET=1) — run_all.sh already reset once ---"
fi

echo ""
echo "--- Ensuring temp_spill_sort_drill exists ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_create_index_temp_spike';
         CREATE TABLE IF NOT EXISTS temp_spill_sort_drill AS
         SELECT generate_series(1, ${ROW_COUNT}) AS id, md5(random()::text) AS name,
                repeat(md5(random()::text), 10) AS payload;
         ANALYZE temp_spill_sort_drill;"

echo ""
echo "--- Building index (non-concurrent, so it also holds a ShareLock on writers) ---"
echo "    Monitor progress from another terminal:"
echo "      psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} -c \\"
echo "        \"SELECT pid, phase, blocks_total, blocks_done, tuples_total, tuples_done"
echo "                FROM pg_stat_progress_create_index;\""
echo ""

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_create_index_temp_spike';
         DROP INDEX IF EXISTS idx_temp_spill_sort_drill_payload_regular;
         CREATE INDEX idx_temp_spill_sort_drill_payload_regular
         ON temp_spill_sort_drill(payload);" 2>&1 | sed 's/^/  [create index] /'

echo ""
echo "--- Temp usage immediately after the build ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
         FROM pg_stat_database ORDER BY temp_bytes DESC;"

echo ""
echo "Note: whether this spills to temp depends on maintenance_work_mem vs. data size."
echo "Check with: SHOW maintenance_work_mem;  -- raise only for the maintenance session:"
echo "  SET maintenance_work_mem = '512MB';"
echo ""
echo "In production, prefer CREATE INDEX CONCURRENTLY to avoid blocking writers —"
echo "see ../02-locks-deadlocks-blocking-queries/05_simulate_ddl_blocking_dml.sh for the"
echo "DDL-blocks-DML angle of non-concurrent index builds."
echo ""
ensure_min_duration 10
echo "Drill complete."
