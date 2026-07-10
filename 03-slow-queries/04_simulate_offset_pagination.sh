#!/usr/bin/env bash
# =============================================================================
# 04_simulate_offset_pagination.sh
# Slow Queries DRILL — Deep OFFSET Pagination vs. Keyset Pagination
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
# Read-only drill (EXPLAIN ANALYZE only) — no confirmation required.
#
#   Bad:  SELECT * FROM slowq_orders ORDER BY created_at DESC
#         OFFSET <deep_offset> LIMIT 50;   -- must walk & discard <deep_offset> rows
#   Good: SELECT * FROM slowq_orders WHERE created_at < <cutoff>
#         ORDER BY created_at DESC LIMIT 50;   -- keyset pagination, O(limit)
#
# Usage:
#   ./04_simulate_offset_pagination.sh [deep_offset]
#
# Defaults: deep_offset=100000 (walks/discards a hundred thousand rows on
# every EXPLAIN; slowq_orders is seeded at 200k rows in 01_setup so this
# stays within range with margin). Sized for a <=20s drill run, not to
# maximize the cost gap between OFFSET and keyset pagination.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

DEEP_OFFSET="100000"
for arg in "$@"; do
    [[ "${arg}" =~ ^[0-9]+$ ]] && DEEP_OFFSET="${arg}"
done

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")

echo "=== DRILL: Offset Pagination vs. Keyset Pagination (offset=${DEEP_OFFSET}) ==="

echo ""
echo "--- Bad: deep OFFSET pagination (walks & discards ${DEEP_OFFSET} rows every page) ---"
"${PSQL[@]}" -c "SET application_name = 'drill_offset_pagination';
                  EXPLAIN (ANALYZE, BUFFERS)
                  SELECT * FROM slowq_orders
                  ORDER BY created_at DESC
                  OFFSET ${DEEP_OFFSET} LIMIT 50;"

echo ""
echo "--- Determining a keyset cursor value at the equivalent depth ---"
CUTOFF=$("${PSQL[@]}" -t -A -c "SELECT created_at FROM slowq_orders
                                 ORDER BY created_at DESC
                                 OFFSET ${DEEP_OFFSET} LIMIT 1;")
echo "Cursor (created_at at offset ${DEEP_OFFSET}): ${CUTOFF}"

echo ""
echo "--- Good: keyset pagination using that cursor (index-friendly, O(limit)) ---"
echo "Note: requires a idx_slowq_orders_created_at_desc index (not created by any drill"
echo "      here) for a true Index Scan; without it this still seq-scans, but touches"
echo "      the WHERE clause instead of walking OFFSET rows."
"${PSQL[@]}" -c "SET application_name = 'drill_offset_pagination';
                  EXPLAIN (ANALYZE, BUFFERS)
                  SELECT * FROM slowq_orders
                  WHERE created_at < '${CUTOFF}'
                  ORDER BY created_at DESC LIMIT 50;"

echo ""
echo "--- Sustaining load briefly so pg_stat_activity/seq_scan show a signal ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1. This holds the session active for a few seconds and"
echo "    bursts a few hundred repeats of the OFFSET query (each one itself"
echo "    walks/discards ${DEEP_OFFSET} rows, so the iteration count is kept low"
echo "    to stay within a <=20s drill run) so a quick poll can catch it."
hold_session_active "drill_offset_pagination" \
    "SELECT * FROM slowq_orders ORDER BY created_at DESC OFFSET ${DEEP_OFFSET} LIMIT 50" 5
run_seq_scan_burst "drill_offset_pagination" \
    "1 FROM slowq_orders ORDER BY created_at DESC OFFSET ${DEEP_OFFSET} LIMIT 50" 200
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Not applied automatically — run manually if you want to see the full effect:"
echo "  CREATE INDEX CONCURRENTLY idx_slowq_orders_created_at_desc ON slowq_orders(created_at DESC);"
echo ""
echo "Drill complete. Compare 'Execution Time' between the two EXPLAIN blocks above —"
echo "the gap widens as deep_offset grows, while keyset pagination stays roughly constant."
