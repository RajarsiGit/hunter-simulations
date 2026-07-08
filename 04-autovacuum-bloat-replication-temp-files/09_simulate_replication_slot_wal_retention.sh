#!/usr/bin/env bash
# =============================================================================
# 09_simulate_replication_slot_wal_retention.sh
# Replication DRILL — Inactive Logical Replication Slot Retains WAL
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_bloat_drill_tables.sql.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §4.7 (Scenario B3)
#         and "RDS Postgres Issue Guide" §4.3 WAL Scenario 1 (inactive
#         logical replication slot) and Scenario 2 (DMS/CDC consumer lag —
#         same underlying signal: an unconsumed slot retaining WAL,
#         regardless of whether the stalled consumer is a manual test slot
#         or a broken AWS DMS/CDC task).
#
# Reproduces: a logical replication slot is created but never consumed.
# PostgreSQL must retain all WAL since the slot's restart_lsn, so
# `retained_wal` grows as writes continue — even though FreeStorageSpace
# on the primary keeps shrinking with no runaway table in sight.
#
# Usage:
#   ./09_simulate_replication_slot_wal_retention.sh [row_count] [--yes]
#
# Note: this creates a REAL logical replication slot. If your instance
# already tracks replication slots for legitimate consumers (DMS, Debezium,
# etc.), make sure `drill_inactive_slot` doesn't collide with anything and
# confirm cleanup (drop) is safe before running in shared non-prod.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-2000000}"
SLOT_NAME="drill_inactive_slot"

confirm_drill "This creates a logical replication slot named '${SLOT_NAME}' (never consumed) and generates ${ROW_COUNT} rows of WAL-producing writes to show retained_wal growing." "$@"

echo ""
echo "=== DRILL: Inactive Replication Slot Retains WAL (Investigation Guide §4.7 / Scenario B3) ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE} | slot=${SLOT_NAME} | rows=${ROW_COUNT}"

echo ""
echo "--- Creating the (intentionally unconsumed) logical replication slot ---"
SLOT_EXISTS=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -tAc \
     "SELECT 1 FROM pg_replication_slots WHERE slot_name = '${SLOT_NAME}';")
if [[ "${SLOT_EXISTS}" == "1" ]]; then
    echo "  Slot '${SLOT_NAME}' already exists — reusing it."
else
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SELECT pg_create_logical_replication_slot('${SLOT_NAME}', 'test_decoding');" \
         2>&1 | sed 's/^/  /'
fi

echo ""
echo "--- Baseline retained WAL for the slot ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT slot_name, active, restart_lsn,
                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
         FROM pg_replication_slots WHERE slot_name = '${SLOT_NAME}';"

echo ""
echo "--- Generating WAL: bulk insert into wal_drill_records (nobody is consuming the slot) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_repl_slot_wal';
         INSERT INTO wal_drill_records (payload)
         SELECT repeat(md5(random()::text), 100) FROM generate_series(1, ${ROW_COUNT});"

echo ""
echo "--- Retained WAL AFTER the write burst (should have grown vs. baseline) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn,
                pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
         FROM pg_replication_slots
         ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;"

echo ""
echo "This is the same signal AWS flags for a stalled DMS/CDC task (Issue Guide WAL"
echo "Scenario 2) — check the consumer's health before assuming the slot itself is at fault:"
echo "  - Native logical replication / Debezium: check the subscriber's replication status."
echo "  - AWS DMS: check the replication task status/errors in the DMS console."
echo ""
echo "--- Remediation: drop the slot ONLY after confirming no consumer needs it ---"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_drop_replication_slot('${SLOT_NAME}');\""
echo ""
ensure_min_duration 90
echo "Drill leaves the slot in place (never dropped) so the hunter has a real window"
echo "to detect the retained WAL."
