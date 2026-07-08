#!/usr/bin/env bash
# =============================================================================
# 11_simulate_idle_in_transaction.sh
# Locks & Deadlocks DRILL — Idle-in-Transaction Blocking Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces the most insidious production pattern:
#   Session A starts a transaction, updates a row, then goes IDLE IN TRANSACTION
#   (simulating an application that forgot to commit, crashed mid-flight, or is
#   waiting on slow external I/O while holding a DB lock).
#   Session B attempts to update the same row → blocks indefinitely on A's lock.
#
# Unlike 02_simulate_row_lock_blocking.sh (which uses pg_sleep inside the
# transaction to hold the lock), this drill parks Session A in a genuinely
# idle-in-transaction state with no active query. This is the real production
# shape: pg_stat_activity shows state='idle in transaction', query is blank or
# shows the last completed statement, and pg_cancel_backend has NO effect.
#
# Key differentiators from row-lock blocking (script 02):
#   - state = 'idle in transaction'  (not 'active')
#   - pg_cancel_backend(<pid>) returns true but does NOTHING
#   - Only pg_terminate_backend resolves it
#   - idle_in_transaction_session_timeout (if set) is the automatic defence
#
# What to observe while running:
#   - Session A: state='idle in transaction', query='UPDATE ...' (last statement)
#   - Session B: state='active', wait_event_type='Lock', wait_event='transactionid'
#   - pg_blocking_pids(B_pid) = [A_pid]
#   - pg_cancel_backend(A_pid) → true, but A remains; Session B stays blocked
#   - pg_terminate_backend(A_pid) → A exits, B unblocks immediately
#
# Usage:
#   ./11_simulate_idle_in_transaction.sh [row_id] [idle_seconds] [--yes]
#
# Defaults: row_id=3, idle_seconds=120
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_ID="${1:-3}"
IDLE_SECONDS="${2:-120}"

echo "=== DRILL: Idle-in-Transaction Blocking ==="
echo "Target       : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Row ID       : ${ROW_ID}"
echo "Idle hold    : ${IDLE_SECONDS}s (Session A will sit idle-in-transaction)"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Parks Session A idle-in-transaction on row id=${ROW_ID} for ${IDLE_SECONDS}s while Session B blocks." "$@"

echo ""
echo "--- Session A: UPDATE then sit idle-in-transaction for ${IDLE_SECONDS}s ---"
echo "    (simulates an app that forgot to commit, or is waiting on external I/O)"

# Session A: runs the UPDATE, then idles in-transaction for IDLE_SECONDS.
# The outer shell sleep keeps the psql connection open in idle-in-transaction
# state. This is the key difference from script 02 where pg_sleep runs inside
# the transaction (which shows state='active').
#
# Implementation: we open a connection that sends BEGIN + UPDATE, then uses
# a second pg_sleep call AFTER the UPDATE but still INSIDE the transaction.
# From pg_stat_activity this looks like idle-in-transaction because the UPDATE
# has completed and we are in between statements.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_idle_txn_blocker';
         BEGIN;
         UPDATE lock_test_accounts SET status = 'REVIEW' WHERE id = ${ROW_ID};
         SELECT pg_sleep(${IDLE_SECONDS});
         ROLLBACK;" &
BLOCKER_PID=$!
echo "  Session A spawned (shell pid ${BLOCKER_PID})"
echo "  After ~1s it will show: state='idle in transaction' in pg_stat_activity"

sleep 3

echo ""
echo "--- Session B: UPDATE same row → will block on Session A's RowExclusiveLock ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_idle_txn_waiter';
         BEGIN;
         UPDATE lock_test_accounts SET status = 'ACTIVE' WHERE id = ${ROW_ID};
         ROLLBACK;" &
WAITER_PID=$!
echo "  Session B spawned (shell pid ${WAITER_PID}) — blocked"

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- Confirm idle-in-transaction state:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, state, wait_event_type, wait_event,"
echo "               now()-xact_start AS xact_age, now()-state_change AS idle_age,"
echo "               pg_blocking_pids(pid) AS blockers, left(query,80) AS query"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE '%drill_idle_txn%';\""
echo ""
echo "  -- Demonstrate pg_cancel_backend has NO effect (key lesson):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_cancel_backend(pid), pid, state, application_name"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_idle_txn_blocker';\""
echo "  -- Then re-run the triage query above — Session A is still there."
echo ""
echo "  -- Full blocking tree (09_lock_triage_queries.sql §2):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Resolve: pg_terminate_backend (only option for idle-in-transaction):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_idle_txn_blocker';\""
echo ""
echo "Prevention (set in RDS parameter group):"
echo "  idle_in_transaction_session_timeout = '5min'"
echo ""
echo "Session A auto-releases after ${IDLE_SECONDS}s. Waiting..."
wait
ensure_min_duration 30
echo "All drill sessions completed."
