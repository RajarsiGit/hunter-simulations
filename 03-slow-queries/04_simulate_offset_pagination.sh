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
# Defaults: deep_offset=200000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

DEEP_OFFSET="200000"
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
echo "Note: requires idx_slowq_orders_created_at_desc from 02/README fix step for a true Index Scan;"
echo "      without it this still seq-scans, but touches the WHERE clause instead of walking OFFSET rows."
"${PSQL[@]}" -c "SET application_name = 'drill_offset_pagination';
                  EXPLAIN (ANALYZE, BUFFERS)
                  SELECT * FROM slowq_orders
                  WHERE created_at < '${CUTOFF}'
                  ORDER BY created_at DESC LIMIT 50;"

echo ""
echo "--- Sustaining load so the slow-queries hunter can actually observe it ---"
echo "    A single EXPLAIN above finishes in well under a second and only bumps"
echo "    seq_scan by 1 — nowhere near what the live hunter needs. duration_seconds"
echo "    is measured from this statement's query_start, so it only crosses the"
echo "    hunter's >=30s threshold near the END of the hold — a 90s hold keeps it"
echo "    over threshold for a full 60s, comfortably wider than the poller's ~27s"
echo "    tick cadence (vs. only ~5s of margin at the old 35s hold). Also bursts"
echo "    1500 seq scans (seq_scan_tables, >1000 threshold) so that check fires too."
hold_session_active "drill_offset_pagination" \
    "SELECT * FROM slowq_orders ORDER BY created_at DESC OFFSET ${DEEP_OFFSET} LIMIT 50" 90
run_seq_scan_burst "drill_offset_pagination" \
    "1 FROM slowq_orders ORDER BY created_at DESC OFFSET ${DEEP_OFFSET} LIMIT 50" 1500
wait "${HOLD_PID}" 2>/dev/null || true

echo ""
echo "Fix (not applied automatically — run manually if you want to see the full effect):"
echo "  CREATE INDEX CONCURRENTLY idx_slowq_orders_created_at_desc ON slowq_orders(created_at DESC);"
echo ""
echo "Drill complete. Compare 'Execution Time' between the two EXPLAIN blocks above —"
echo "the gap widens as deep_offset grows, while keyset pagination stays roughly constant."
