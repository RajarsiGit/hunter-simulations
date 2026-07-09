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
# Defaults: row_id=1, hold_seconds=900 — clears TWO real thresholds from
# actions/locks-deadlocks-blocking-queries.jsonc with wide margin: the 300s
# poll interval (so a poll tick is guaranteed to land mid-hold regardless of
# phase — 900s gives 3 full ticks of overlap) AND LB-3 idle_in_transaction_critical's
# blocker_idle_age_seconds >= 300s threshold (600s margin).
#
# CEILING WARNING: SysCloud baseline session settings (jsonc verdict text,
# runbook §7.3) are deadlock_timeout=15s, lock_timeout=10s,
# idle_in_transaction_session_timeout=60s, statement_timeout=5min. If those
# are live on the target role, Session A (idle-in-txn) is killed by the
# server at 60s and Session B (waiter) errors out with a lock_timeout abort
# at 10s — BOTH well before any hold_seconds value or the 300s LB-3
# threshold is ever reached, regardless of how large hold_seconds is set.
# Both sessions below explicitly SET these to 0 (disabled) for their own
# connection only — this does not touch the role/database default, just
# this drill's two sessions — so the intensity bump above is not silently
# neutralized by the server's own safety timeouts.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_ID="${1:-1}"
HOLD_SECONDS="${2:-900}"

echo "=== DRILL: Row-Level Lock Blocking ==="
echo "Target  : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Row ID  : ${ROW_ID}"
echo "Hold    : ${HOLD_SECONDS}s (Session A idle-in-transaction duration)"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Opens two sessions: Session A updates row id=${ROW_ID} and holds it; Session B updates the same row and blocks." "$@"

echo ""
echo "--- Session A: acquiring RowExclusiveLock on id=${ROW_ID}, then genuinely idle-in-transaction ---"
echo "    (uses a client-side \\! sleep between statements, NOT pg_sleep inside one"
echo "     statement — pg_sleep-in-one--c-string never actually leaves state='active',"
echo "     it just changes wait_event, so it would never satisfy LB-3/idle_txn checks)"

# Session A: BEGIN + UPDATE as one round trip, THEN a client-side sleep via
# the psql \! meta-command (shells out locally; sends nothing to the server)
# BEFORE the next statement (ROLLBACK). Because the server genuinely has no
# next command to process during that gap, pg_stat_activity reports
# state='idle in transaction' for the whole IDLE_SECONDS window — the real
# production shape LB-3/idle_txn_accumulation are written to detect.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<SQL_A &
SET application_name = 'drill_row_lock_blocker';
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
BEGIN;
UPDATE lock_test_accounts SET balance = balance - 100 WHERE id = ${ROW_ID};
\! sleep ${HOLD_SECONDS}
ROLLBACK;
SQL_A
BLOCKER_PID=$!
echo "  Session A spawned (shell pid ${BLOCKER_PID}) — holding RowExclusiveLock on id=${ROW_ID}"

# Allow Session A to acquire the lock before Session B attempts the same row.
sleep 2

echo ""
echo "--- Session B: attempting UPDATE on same row id=${ROW_ID} — will block on Session A ---"

# Session B: tries the same row — will wait for A's RowExclusiveLock.
# Shows wait_event_type='Lock', wait_event='transactionid' in pg_stat_activity.
# lock_timeout=0 is essential here: at the SysCloud baseline (lock_timeout=10s)
# this session would abort after 10s of waiting, well before the poller's 300s
# tick or LB-3's 300s idle-age threshold could ever observe the block.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_row_lock_waiter';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
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
