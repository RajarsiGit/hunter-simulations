#!/usr/bin/env bash
# =============================================================================
# 07_simulate_temp_file_spill.sh
# Temp Files DRILL — Sort / Hash-Join / Hash-Aggregate Disk Spill
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §5.5-5.7
#         (Scenarios C1 ORDER BY sort spill, C2 hash join spill, C3 hash
#         aggregate explosion) and "RDS Postgres Issue Guide" §3.3 Scenario 4.
#
# Reproduces: with work_mem set artificially low for the session, a big
# sort / hash join / hash aggregate can't fit in memory and spills to disk
# as temp files. Shows detection via pg_stat_database.temp_bytes and
# pg_stat_statements.temp_blks_written, then the fix (index or raised
# work_mem for that session/role only — never a blind global bump).
#
# Usage:
#   ./07_simulate_temp_file_spill.sh <sort|hash_join|group_by> [row_count] [--yes]
#
# Examples:
#   ./07_simulate_temp_file_spill.sh sort 5000000
#   ./07_simulate_temp_file_spill.sh hash_join 2000000
#   ./07_simulate_temp_file_spill.sh group_by 5000000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-sort}"
ROW_COUNT="${2:-5000000}"

case "${MODE}" in
    sort|hash_join|group_by) ;;
    *) echo "Usage: $0 <sort|hash_join|group_by> [row_count] [--yes]"; exit 1 ;;
esac

confirm_drill "This creates temp-spill test table(s) (mode=${MODE}, ~${ROW_COUNT} rows), sets work_mem='1MB' for the drill session, and runs a query designed to spill to disk temp files." "$@"

echo ""
echo "=== DRILL: Temp File Spill — mode=${MODE} (Investigation Guide §5.5-5.7) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT}"

echo ""
echo "--- Baseline temp usage (pg_stat_database) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
         FROM pg_stat_database ORDER BY temp_bytes DESC;"

case "${MODE}" in
  sort)
    echo ""
    echo "--- Setting up temp_spill_sort_drill (${ROW_COUNT} rows) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
         -c "SET application_name = 'drill_temp_spill_sort';
             CREATE TABLE IF NOT EXISTS temp_spill_sort_drill AS
             SELECT generate_series(1, ${ROW_COUNT}) AS id,
                    md5(random()::text) AS name,
                    repeat(md5(random()::text), 10) AS payload;
             ANALYZE temp_spill_sort_drill;"
    echo ""
    echo "--- Forcing an external sort with work_mem='1MB' ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_temp_spill_sort';
             SET work_mem = '1MB';
             EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM temp_spill_sort_drill ORDER BY payload;" \
         2>&1 | sed 's/^/  [sort plan] /'
    ;;
  hash_join)
    echo ""
    echo "--- Setting up temp_spill_join_a / temp_spill_join_b (${ROW_COUNT} rows each) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
         -c "SET application_name = 'drill_temp_spill_hash_join';
             CREATE TABLE IF NOT EXISTS temp_spill_join_a AS
             SELECT generate_series(1, ${ROW_COUNT}) AS id, (random()*1000000)::int AS join_key,
                    repeat(md5(random()::text), 5) AS payload;
             CREATE TABLE IF NOT EXISTS temp_spill_join_b AS
             SELECT generate_series(1, ${ROW_COUNT}) AS id, (random()*1000000)::int AS join_key,
                    repeat(md5(random()::text), 5) AS payload;
             ANALYZE temp_spill_join_a; ANALYZE temp_spill_join_b;"
    echo ""
    echo "--- Forcing a hash join spill with work_mem='1MB' (no join-key index yet) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_temp_spill_hash_join';
             SET work_mem = '1MB';
             EXPLAIN (ANALYZE, BUFFERS)
             SELECT count(*) FROM temp_spill_join_a a JOIN temp_spill_join_b b ON a.join_key = b.join_key;" \
         2>&1 | sed 's/^/  [hash join plan] /'
    ;;
  group_by)
    echo ""
    echo "--- Setting up temp_spill_group_drill (${ROW_COUNT} rows, high-cardinality payload) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
         -c "SET application_name = 'drill_temp_spill_group_by';
             CREATE TABLE IF NOT EXISTS temp_spill_group_drill AS
             SELECT generate_series(1, ${ROW_COUNT}) AS id, md5(random()::text) AS payload;
             ANALYZE temp_spill_group_drill;"
    echo ""
    echo "--- Forcing a hash aggregate spill with work_mem='1MB' ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_temp_spill_group_by';
             SET work_mem = '1MB';
             EXPLAIN (ANALYZE, BUFFERS) SELECT payload, count(*) FROM temp_spill_group_drill GROUP BY payload;" \
         2>&1 | sed 's/^/  [hash agg plan] /'
    ;;
esac

echo ""
echo "--- Detect: temp usage AFTER the spill ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
         FROM pg_stat_database ORDER BY temp_bytes DESC;"

echo ""
echo "--- Top SQL by temp blocks written (requires pg_stat_statements) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT calls, temp_blks_read, temp_blks_written, mean_exec_time, left(query, 200) AS query
         FROM pg_stat_statements ORDER BY temp_blks_written DESC LIMIT 10;"

echo ""
echo "Remediation depends on mode:"
echo "  sort/group_by : add a supporting index if the access pattern is stable, or"
echo "                  raise work_mem for the specific session/role only, e.g."
echo "                    SET work_mem = '128MB';  -- session-scoped, not global"
echo "  hash_join     : CREATE INDEX CONCURRENTLY idx_temp_spill_join_a_key ON temp_spill_join_a(join_key);"
echo "                  CREATE INDEX CONCURRENTLY idx_temp_spill_join_b_key ON temp_spill_join_b(join_key);"
echo ""
echo "Memory risk formula before raising work_mem globally:"
echo "  worst_case_memory ≈ active_connections × work_mem × sort/hash_nodes_per_query"
echo ""
ensure_min_duration 90
echo "Drill complete (mode=${MODE})."
