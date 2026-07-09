#!/usr/bin/env bash
# =============================================================================
# 05_simulate_ddl_blocking_dml.sh
# Locks & Deadlocks DRILL — DDL Blocking DML Cascade Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces the cascading queue pattern:
#
#   t=0s  Session A: long-running UPDATE (holds RowExclusiveLock for DML_SECONDS)
#   t=5s  Session B: CREATE INDEX (non-concurrent) → waits behind A
#                    Once A completes, B acquires ShareLock (blocks all DML)
#   t=8s  Session C: simple UPDATE → queues behind B's DDL lock
#                    Even though B hasn't started yet — it queues behind the DDL
#                    intent, not A's DML
#
# This reproduces the real SysCloud pattern: index creation during peak hours
# causes cascading DML starvation. Session C is unrelated to Session A but
# is still blocked by the waiting DDL lock request.
#
# Resolution options demonstrated:
#   Option 1: Wait for A to complete (DML finishes → B proceeds → C proceeds)
#   Option 2: Cancel B's DDL (frees C immediately; reschedule off-peak)
#   Option 3: Use CREATE INDEX CONCURRENTLY instead (never blocks DML)
#
# Usage:
#   ./05_simulate_ddl_blocking_dml.sh [dml_hold_seconds] [--yes]
#
# Default: dml_hold_seconds=900 — clears the hunter's 300s poll interval
# (actions/locks-deadlocks-blocking-queries.jsonc) with 3 ticks of overlap so
# DC-1 ddl_blocking_detected is reliably sampled while Session B (the queued
# CREATE INDEX) is waiting.
#
# CEILING WARNING: at the SysCloud baseline (runbook §7.3: lock_timeout=10s,
# statement_timeout=5min) Session B/C below would abort while queued long
# before this hold matters — both disable lock_timeout/statement_timeout for
# their own connection.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

DML_HOLD="${1:-900}"   # How long Session A's UPDATE holds the lock

echo "=== DRILL: DDL Blocking DML Cascade ==="
echo "Target          : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Session A (DML) : UPDATE held for ${DML_HOLD}s"
echo "Session B (DDL) : CREATE INDEX (non-concurrent) — starts at t=5s"
echo "Session C (DML) : Second UPDATE — starts at t=8s, blocks behind B"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs a DML → CREATE INDEX → DML cascade that blocks unrelated writes behind a queued DDL." "$@"

# Drop the drill index if it exists from a previous run
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "DROP INDEX IF EXISTS idx_drill_balance;" 2>/dev/null || true

echo ""
echo "--- Session A (t=0): long-running UPDATE, holds RowExclusiveLock for ${DML_HOLD}s ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_ddl_dml_session_a';
         SET statement_timeout = 0;
         SET idle_in_transaction_session_timeout = 0;
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 1;
         SELECT pg_sleep(${DML_HOLD});
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session A / DML] #' &
PID_A=$!
echo "  Session A spawned (shell pid ${PID_A}) — holding RowExclusiveLock"

sleep 5

echo ""
echo "--- Session B (t=5s): CREATE INDEX (non-concurrent) — will queue behind A ---"
echo "    Once A releases, B acquires ShareLock and blocks ALL subsequent DML."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_ddl_dml_session_b';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
         CREATE INDEX idx_drill_balance ON lock_test_accounts(balance);" \
     2>&1 | sed 's#^#  [Session B / DDL] #' &
PID_B=$!
echo "  Session B spawned (shell pid ${PID_B}) — waiting to acquire lock for CREATE INDEX"

sleep 3

echo ""
echo "--- Session C (t=8s): simple UPDATE — queues behind B's DDL lock request ---"
echo "    Demonstrates: unrelated DML is blocked the moment DDL is queuing."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_ddl_dml_session_c';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 5 WHERE id = 2;
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session C / DML] #' &
PID_C=$!
echo "  Session C spawned (shell pid ${PID_C}) — blocked behind B"

echo ""
echo "Drill is LIVE. Full blocking queue: A → B → C"
echo ""
echo "  Observe the cascade:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  Check index creation progress (while B is running after A completes):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c 'SELECT * FROM pg_stat_progress_create_index;'"
echo ""
echo "Session A will release after ${DML_HOLD}s, allowing B to proceed (then C unblocks)."
echo "Waiting for all sessions to complete..."
wait
echo ""
echo "All drill sessions completed."

# Clean up the drill index if it was created
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "DROP INDEX IF EXISTS idx_drill_balance;" 2>/dev/null || true
echo "Drill index dropped (if it was created)."

ensure_min_duration 30
