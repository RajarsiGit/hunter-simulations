#!/usr/bin/env bash
# =============================================================================
# 02_simulate_row_lock_blocking.sh
# Locks & Deadlocks DRILL — Row-Level Lock Blocking Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces the most common SysCloud production lock pattern:
#   Session A  updates a row and holds the transaction open (idle in transaction).
#   Session B  attempts to update the same row → blocks on A's RowExclusiveLock.
#
# Both sessions are tagged with a drill application_name so they are
# trivially visible in pg_stat_activity.
#
# What to observe while running:
#   - Session B shows wait_event_type='Lock', wait_event='transactionid'
#   - pg_blocking_pids(Session B pid) returns Session A's pid
#   - Session A shows state='idle in transaction'
#
# Usage:
#   ./02_simulate_row_lock_blocking.sh [row_id] [hold_seconds] [--yes]
#
# Defaults: row_id=1, hold_seconds=120
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_ID="${1:-1}"
HOLD_SECONDS="${2:-120}"

echo "=== DRILL: Row-Level Lock Blocking ==="
echo "Target  : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Row ID  : ${ROW_ID}"
echo "Hold    : ${HOLD_SECONDS}s (Session A idle-in-transaction duration)"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Opens two sessions: Session A updates row id=${ROW_ID} and holds it; Session B updates the same row and blocks." "$@"

echo ""
echo "--- Session A: acquiring RowExclusiveLock on id=${ROW_ID} (will idle-in-transaction) ---"

# Session A: opens BEGIN, updates the row, then sleeps without committing.
# This reproduces the "idle in transaction holding a RowExclusiveLock" pattern.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_row_lock_blocker';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance - 100 WHERE id = ${ROW_ID};
         SELECT pg_sleep(${HOLD_SECONDS});
         ROLLBACK;" &
BLOCKER_PID=$!
echo "  Session A spawned (shell pid ${BLOCKER_PID}) — holding RowExclusiveLock on id=${ROW_ID}"

# Allow Session A to acquire the lock before Session B attempts the same row.
sleep 2

echo ""
echo "--- Session B: attempting UPDATE on same row id=${ROW_ID} — will block on Session A ---"

# Session B: tries the same row — will wait for A's RowExclusiveLock.
# Shows wait_event_type='Lock', wait_event='transactionid' in pg_stat_activity.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_row_lock_waiter';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 50 WHERE id = ${ROW_ID};
         ROLLBACK;" &
WAITER_PID=$!
echo "  Session B spawned (shell pid ${WAITER_PID}) — blocked waiting for Session A"

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- First-response triage:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, state, wait_event_type, wait_event,"
echo "               pg_blocking_pids(pid) AS blockers,"
echo "               now()-query_start AS query_age"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE '%drill_row_lock%';\""
echo ""
echo "  -- Blocking tree:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "Session A will auto-release after ${HOLD_SECONDS}s. Waiting for drill to complete..."
wait
ensure_min_duration 30
echo "All drill sessions have completed."
