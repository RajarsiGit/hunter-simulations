#!/usr/bin/env bash
# =============================================================================
# 04_simulate_table_access_exclusive.sh
# Locks & Deadlocks DRILL — Table-Level AccessExclusiveLock Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces an explicit LOCK TABLE IN ACCESS EXCLUSIVE MODE that blocks ALL
# concurrent reads and writes on the table for HOLD_SECONDS.
#
# Real-world triggers in SysCloud production:
#   TRUNCATE, VACUUM FULL, REINDEX, explicit LOCK TABLE statements in
#   deployment scripts or maintenance operations.
#
# What to observe:
#   - Session A: state='idle in transaction', holds AccessExclusiveLock (granted=true)
#   - Session B (SELECT): wait_event_type='Lock', mode='AccessShareLock' (granted=false)
#   - Session C (UPDATE): wait_event_type='Lock', mode='RowExclusiveLock' (granted=false)
#   - pg_cancel_backend has NO effect on idle-in-transaction sessions
#
# Usage:
#   ./04_simulate_table_access_exclusive.sh [hold_seconds] [--yes]
#
# Default: hold_seconds=900 — clears the hunter's 300s poll interval
# (actions/locks-deadlocks-blocking-queries.jsonc) with 3 ticks of overlap,
# so DC-1 ddl_blocking_detected (waiter_count>=1, no duration threshold)
# reliably gets sampled instead of finishing between two polls unobserved.
#
# CEILING WARNING: SysCloud baseline (runbook §7.3) is
# idle_in_transaction_session_timeout=60s and statement_timeout=5min. Session
# A's pg_sleep runs inside one statement, so statement_timeout (not the idle
# timeout) is what would kill it early at those settings — both timeouts are
# disabled below for this session only. Sessions B/C (waiters) similarly
# disable lock_timeout (baseline 10s) so they keep waiting for the full hold
# instead of erroring out almost immediately.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

HOLD_SECONDS="${1:-900}"

echo "=== DRILL: Table-Level AccessExclusiveLock ==="
echo "Target : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Table  : lock_test_accounts"
echo "Hold   : ${HOLD_SECONDS}s"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Locks lock_test_accounts IN ACCESS EXCLUSIVE MODE for ${HOLD_SECONDS}s, blocking all reads and writes." "$@"

echo ""
echo "--- Session A: acquiring AccessExclusiveLock on lock_test_accounts ---"

# Session A: LOCK TABLE holds AccessExclusiveLock, then sleeps (idle in transaction).
# This blocks all concurrent reads (SELECT) and writes (INSERT/UPDATE/DELETE).
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_access_exclusive_holder';
         SET statement_timeout = 0;
         SET idle_in_transaction_session_timeout = 0;
         BEGIN;
         LOCK TABLE lock_test_accounts IN ACCESS EXCLUSIVE MODE;
         SELECT pg_sleep(${HOLD_SECONDS});
         ROLLBACK;" &
HOLDER_PID=$!
echo "  Session A spawned (shell pid ${HOLDER_PID}) — holding AccessExclusiveLock"

sleep 2

echo ""
echo "--- Session B: SELECT on lock_test_accounts — will block (needs AccessShareLock) ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_access_exclusive_reader';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
         SELECT count(*) FROM lock_test_accounts;" \
     2>&1 | sed 's#^#  [Session B / reader] #' &
READER_PID=$!
echo "  Session B spawned (shell pid ${READER_PID}) — blocked on AccessShareLock"

sleep 1

echo ""
echo "--- Session C: UPDATE on lock_test_accounts — will also block ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_access_exclusive_writer';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 1;
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session C / writer] #' &
WRITER_PID=$!
echo "  Session C spawned (shell pid ${WRITER_PID}) — blocked on RowExclusiveLock"

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- Who holds the AccessExclusiveLock?"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT a.pid, a.application_name, a.state,"
echo "               l.locktype, l.mode, l.granted"
echo "         FROM  pg_locks l"
echo "         JOIN  pg_stat_activity a ON a.pid = l.pid"
echo "         WHERE l.relation = 'lock_test_accounts'::regclass"
echo "         ORDER BY l.granted DESC;\""
echo ""
echo "  -- Blocking tree:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "⚠️  NOTE: pg_cancel_backend has NO effect on idle-in-transaction sessions."
echo "   Only pg_terminate_backend works."
echo ""
echo "Session A releases after ${HOLD_SECONDS}s. Waiting..."
wait
ensure_min_duration 30
echo "All drill sessions have completed."
