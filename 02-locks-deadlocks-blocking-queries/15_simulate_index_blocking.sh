#!/usr/bin/env bash
# =============================================================================
# 15_simulate_index_blocking.sh
# Locks & Deadlocks DRILL — Index Operation Blocking Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces blocking caused by non-concurrent index creation. CREATE INDEX
# (without CONCURRENTLY) acquires ShareLock, which blocks all DML
# (INSERT/UPDATE/DELETE) for the duration of the build.
#
# Drill sequence:
#   t=0s  Session A: long UPDATE on lock_test_accounts (holds RowExclusiveLock)
#   t=5s  Session B: CREATE INDEX (non-concurrent) → waits for Session A
#   t=8s  Session C: INSERT into lock_test_accounts → also blocked by pending DDL
#   Resolution A: wait for A to finish → B builds index → C executes
#   Resolution B: pg_cancel_backend(B) → C unblocks immediately; reschedule index
#
# Key observation: once CREATE INDEX is queuing, even COMPATIBLE DML that would
# have proceeded normally is blocked because of lock queuing order.
#
# Also demonstrates:
#   - pg_stat_progress_create_index for monitoring build progress
#   - How to safely drop a failed/invalid CONCURRENTLY index
#   - CREATE INDEX CONCURRENTLY as the production-safe alternative
#
# Usage:
#   ./15_simulate_index_blocking.sh [dml_hold_seconds] [--yes]
#
# Default: dml_hold_seconds=60
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

DML_HOLD="${1:-60}"

echo "=== DRILL: Index Operation Blocking ==="
echo "Target          : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Session A (DML) : UPDATE held for ${DML_HOLD}s"
echo "Session B (DDL) : CREATE INDEX (non-concurrent) — starts at t=5s"
echo "Session C (DML) : INSERT — starts at t=8s, blocked behind pending index"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs a non-concurrent CREATE INDEX that queues behind a DML and then blocks a subsequent INSERT." "$@"

# Clean up any leftover index from a previous drill run
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "DROP INDEX IF EXISTS idx_drill_index_blocking_balance;" 2>/dev/null || true

echo ""
echo "--- Session A (t=0): long UPDATE — holds RowExclusiveLock for ${DML_HOLD}s ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_index_blocking_dml_a';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 1;
         SELECT pg_sleep(${DML_HOLD});
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session A / DML] #' &
PID_A=$!
echo "  Session A spawned (shell pid ${PID_A}) — holding RowExclusiveLock"

sleep 5

echo ""
echo "--- Session B (t=5s): CREATE INDEX (non-concurrent) — queues behind Session A ---"
echo "    ShareLock required. Once A finishes, B blocks ALL subsequent DML."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_index_blocking_ddl_b';
         CREATE INDEX idx_drill_index_blocking_balance
         ON lock_test_accounts(balance);" \
     2>&1 | sed 's#^#  [Session B / CREATE INDEX] #' &
PID_B=$!
echo "  Session B spawned (shell pid ${PID_B}) — waiting for Session A's lock"

sleep 3

echo ""
echo "--- Session C (t=8s): INSERT — blocks behind the queued CREATE INDEX ---"
echo "    Demonstrates: unrelated DML queues behind a pending DDL lock request."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_index_blocking_dml_c';
         BEGIN;
         INSERT INTO lock_test_accounts (id, name, balance)
         VALUES (99, 'Drill-Insert', 0.00)
         ON CONFLICT (id) DO NOTHING;
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session C / INSERT] #' &
PID_C=$!
echo "  Session C spawned (shell pid ${PID_C}) — blocked behind Session B"

echo ""
echo "Drill is LIVE. Full queue: A (DML) → B (CREATE INDEX) → C (INSERT)"
echo ""
echo "  -- Index creation progress (while B is building after A finishes):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, phase, blocks_total, blocks_done,"
echo "               tuples_total, tuples_done, current_locker_pid"
echo "         FROM  pg_stat_progress_create_index;\""
echo ""
echo "  -- Full blocking tree:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Cancel B (CREATE INDEX) to immediately unblock C:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_cancel_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_index_blocking_ddl_b';\""
echo ""
echo "  -- Check for invalid indexes after a failed CONCURRENTLY build:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT indexname, indexdef FROM pg_indexes"
echo "         WHERE tablename = 'lock_test_accounts';\""
echo "  -- Drop invalid index: DROP INDEX CONCURRENTLY IF EXISTS idx_drill_index_blocking_balance;"
echo ""
echo "Production best practice: always use CREATE INDEX CONCURRENTLY."
echo "  SET lock_timeout = '5s'; -- fail fast instead of queueing"
echo ""
echo "Session A releases after ${DML_HOLD}s. Waiting for all sessions..."
wait
echo ""

# Drop the drill index if Session B completed before it was cancelled
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "DROP INDEX IF EXISTS idx_drill_index_blocking_balance;" 2>/dev/null || true
ensure_min_duration 30
echo "Drill index cleaned up. Drill complete."
