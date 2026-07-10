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
#   ./11_simulate_idle_in_transaction.sh [row_id] [idle_seconds] [blocker_count] [--yes]
#
# Defaults: row_id=3, idle_seconds=8, blocker_count=5
#
# idle_seconds=8 is sized so the whole drill completes in well under 20s for
# fast local/CI drilling. This is short of the hunter's 300s poll interval
# and LB-3 idle_in_transaction_critical's 300s threshold, so it is NOT
# reliable for hunter-detection runs — pass a larger idle_seconds (e.g. 900)
# for that.
#
# blocker_count=5 is new: this drill now opens FIVE independent idle-in-txn
# sessions (on rows id=1..5 of lock_test_accounts, which 01_setup seeds with
# exactly 5 rows) instead of one, so the cluster-wide lock_health source
# (queries/locks-deadlocks-blocking-queries/lock-health.sql) counts
# idle_txn_over_5min >= 3 — clearing LH-1 idle_txn_accumulation's >=3
# threshold with 2 sessions of margin. Only the FIRST blocker (row_id, the
# script's own arg) also gets a Session B waiter attached, so this single
# drill run exercises LB-3 (idle-in-txn blocker + waiter) and LH-1
# (idle-in-txn accumulation) simultaneously.
#
# MECHANISM FIX (was broken before this pass): the original implementation
# ran "BEGIN; UPDATE ...; SELECT pg_sleep(N); ROLLBACK;" as ONE psql -c
# string. PostgreSQL's simple-query protocol executes an entire multi-statement
# string as one continuous message — the backend never returns control to
# wait for the client in between, so state stays 'active' (wait_event=
# 'PgSleep') for the WHOLE duration, never 'idle in transaction', no matter
# how long IDLE_SECONDS is. This silently meant LB-3/LH-1 could never fire
# from this script despite its name and its own inline comments claiming
# otherwise. Fixed by splitting into two round trips: BEGIN+UPDATE first,
# THEN a genuine client-side pause via the psql \! meta-command (shells out
# locally, sends nothing to the server) before the final ROLLBACK — during
# that gap the server has no next command to run, so pg_stat_activity
# reports real state='idle in transaction' for the whole idle_seconds window.
#
# CEILING WARNING: SysCloud baseline (runbook §7.3) is
# idle_in_transaction_session_timeout=60s and lock_timeout=10s. Every
# session below explicitly disables both (plus statement_timeout) for its
# own connection — without that, the blockers get killed by the server at
# 60s and the waiter aborts at 10s, regardless of idle_seconds.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_ID="${1:-3}"
IDLE_SECONDS="${2:-8}"
BLOCKER_COUNT="${3:-5}"

echo "=== DRILL: Idle-in-Transaction Blocking ==="
echo "Target        : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Row ID        : ${ROW_ID} (gets the Session B waiter too)"
echo "Idle hold     : ${IDLE_SECONDS}s (all blockers sit genuinely idle-in-transaction)"
echo "Blocker count : ${BLOCKER_COUNT} (rows 1..${BLOCKER_COUNT} of lock_test_accounts) — feeds LH-1 idle_txn_accumulation (>=3)"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Parks ${BLOCKER_COUNT} sessions genuinely idle-in-transaction (one per row) for ${IDLE_SECONDS}s; row id=${ROW_ID}'s blocker also gets a Session B waiter." "$@"

echo ""
echo "--- Spawning ${BLOCKER_COUNT} idle-in-transaction blockers (rows 1..${BLOCKER_COUNT}) ---"
echo "    (simulates an app that forgot to commit, or is waiting on external I/O)"

BLOCKER_PIDS=()
for b in $(seq 1 "${BLOCKER_COUNT}"); do
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<SQL_BLOCKER &
SET application_name = 'drill_idle_txn_blocker_${b}';
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
BEGIN;
UPDATE lock_test_accounts SET status = 'REVIEW' WHERE id = ${b};
\! sleep ${IDLE_SECONDS}
ROLLBACK;
SQL_BLOCKER
    BLOCKER_PIDS+=($!)
done
echo "  Spawned ${#BLOCKER_PIDS[@]} blockers (shell pids: ${BLOCKER_PIDS[*]})"
echo "  Each will show genuine state='idle in transaction' in pg_stat_activity within ~1s"

sleep 3

echo ""
echo "--- Session B: UPDATE row id=${ROW_ID} → will block on that row's idle-in-txn blocker ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_idle_txn_waiter';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
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
echo "         WHERE application_name LIKE 'drill_idle_txn_blocker%';\""
echo "  -- Then re-run the triage query above — the blockers are still there."
echo ""
echo "  -- Full blocking tree (09_lock_triage_queries.sql §2):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Resolve: pg_terminate_backend (only option for idle-in-transaction):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE 'drill_idle_txn_blocker%';\""
echo ""
echo "Prevention (set in RDS parameter group):"
echo "  idle_in_transaction_session_timeout = '5min'"
echo ""
echo "Session A auto-releases after ${IDLE_SECONDS}s. Waiting..."
wait
ensure_min_duration 12
echo "All drill sessions completed."
