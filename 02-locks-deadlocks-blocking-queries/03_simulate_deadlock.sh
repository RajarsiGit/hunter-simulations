#!/usr/bin/env bash
# =============================================================================
# 03_simulate_deadlock.sh
# Locks & Deadlocks DRILL — Classic 2-Session Deadlock Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces the exact deadlock sequence used in the DBA drill:
#
#   t=0s  Session A: BEGIN; UPDATE id=ROW_A  (locks ROW_A)
#   t=1s  Session B: BEGIN; UPDATE id=ROW_B  (locks ROW_B)
#   t=2s  Session A: UPDATE id=ROW_B         (waits for B — B holds ROW_B)
#   t=3s  Session B: UPDATE id=ROW_A         (cycle closed — deadlock!)
#
# PostgreSQL detects the cycle after deadlock_timeout. Production baseline is
# 15,000 ms (runbook §7.3), but both sessions below SET deadlock_timeout='2s'
# for their own connection so the drill resolves in a few seconds instead of
# up to 15s — needed to keep the whole script under the 20s drill ceiling.
#
# Expected output: one [SessionX] line shows "ERROR: deadlock detected".
# pg_stat_database.deadlocks increments by 1.
#
# Usage:
#   ./03_simulate_deadlock.sh [row_a] [row_b] [--yes]
#
# Defaults: row_a=1, row_b=2
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_A="${1:-1}"   # Session A locks this row first, then tries ROW_B
ROW_B="${2:-2}"   # Session B locks this row first, then tries ROW_A

echo "=== DRILL: Classic 2-Session Deadlock ==="
echo "Target     : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Session A  : locks id=${ROW_A} first, then id=${ROW_B}"
echo "Session B  : locks id=${ROW_B} first, then id=${ROW_A}"
echo ""
echo "Expected   : PostgreSQL aborts one session with SQLSTATE 40P01 after"
echo "             deadlock_timeout (15,000 ms in production)."
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Opens two sessions that update id=${ROW_A}/${ROW_B} in reverse order, forcing a deadlock." "$@"

# Capture baseline deadlock count before the drill
BEFORE=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
              -t -A -c "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database();")
echo ""
echo "Deadlock counter before drill: ${BEFORE}"
echo ""

# ---------------------------------------------------------------------------
# Session A timeline:
#   [t=0]  BEGIN; UPDATE ROW_A  (acquires RowExclusiveLock on ROW_A)
#   [t=4]  UPDATE ROW_B         (waits: B holds RowExclusiveLock on ROW_B)
# ---------------------------------------------------------------------------
echo "--- Spawning Session A (locks id=${ROW_A} first) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_deadlock_A';
         SET deadlock_timeout = '2s';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 10 WHERE id = ${ROW_A};
         SELECT pg_sleep(2);
         UPDATE lock_test_accounts SET balance = balance + 10 WHERE id = ${ROW_B};
         COMMIT;" \
     2>&1 | sed 's/^/  [Session A] /' &
PID_A=$!
echo "  Session A spawned (shell pid ${PID_A})"

# Wait 1s so Session A has acquired its lock on ROW_A before Session B starts.
sleep 1

# ---------------------------------------------------------------------------
# Session B timeline:
#   [t=2]  BEGIN; UPDATE ROW_B  (acquires RowExclusiveLock on ROW_B)
#   [t=6]  UPDATE ROW_A         (cycle closed — both sessions now waiting)
# ---------------------------------------------------------------------------
echo "--- Spawning Session B (locks id=${ROW_B} first) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_deadlock_B';
         SET deadlock_timeout = '2s';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 20 WHERE id = ${ROW_B};
         SELECT pg_sleep(2);
         UPDATE lock_test_accounts SET balance = balance + 20 WHERE id = ${ROW_A};
         COMMIT;" \
     2>&1 | sed 's/^/  [Session B] /' &
PID_B=$!
echo "  Session B spawned (shell pid ${PID_B})"

echo ""
echo "Deadlock cycle forming. Observe in another terminal while waiting:"
echo ""
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, state,"
echo "               wait_event_type, wait_event,"
echo "               pg_blocking_pids(pid) AS blockers"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE '%drill_deadlock%';\""
echo ""
echo "Waiting for PostgreSQL to auto-resolve the deadlock (up to ~5s)..."

# One session will exit non-zero (deadlock abort) — that is expected and correct.
wait "${PID_A}" "${PID_B}" || true

sleep 1

# ---------------------------------------------------------------------------
# Verify the deadlock counter incremented
# ---------------------------------------------------------------------------
AFTER=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
             -t -A -c "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database();")
DELTA=$(( AFTER - BEFORE ))

echo ""
echo "=== Result ==="
echo "Deadlock counter: ${BEFORE} → ${AFTER} (delta: +${DELTA})"

if [[ "${DELTA}" -ge 1 ]]; then
    echo "✓ Deadlock detected and auto-resolved by PostgreSQL — SQLSTATE 40P01 received by one session."
else
    echo "⚠️  Counter unchanged. Possible causes:"
    echo "     • Tables not set up (run 01_setup_lock_drill_tables.sql first)"
    echo "     • Timing too short for deadlock cycle to close (unlikely with default 2s sleep)"
    echo "     • lock_timeout fired before deadlock_timeout (check SET lock_timeout at role level)"
fi

echo ""
echo "Final balances (check which session's UPDATE survived):"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT id, name, balance FROM lock_test_accounts WHERE id IN (${ROW_A}, ${ROW_B});"

echo ""
echo "See CloudWatch Logs for the 'ERROR: deadlock detected' entry with full query detail."

ensure_min_duration 12
