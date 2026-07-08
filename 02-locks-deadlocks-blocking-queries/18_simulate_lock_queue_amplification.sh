#!/usr/bin/env bash
# =============================================================================
# 18_simulate_lock_queue_amplification.sh
# Locks & Deadlocks DRILL — Lock Queue Amplification Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces lock queue amplification, one of the most dangerous production
# patterns because it causes sudden, broad impact from a single old transaction.
#
# How it works:
#   An old transaction (Session A) holds a weak lock (RowExclusiveLock from
#   a long-running UPDATE). A DDL statement (Session B: ALTER TABLE) needs
#   ACCESS EXCLUSIVE and queues behind A. PostgreSQL's lock queue is FIFO:
#   any new DML that would normally be COMPATIBLE with Session A cannot
#   proceed because the pending DDL holds the queue position. The result:
#   Sessions C, D, E (all unrelated DML) pile up behind the DDL waiter,
#   not behind Session A's original DML lock.
#
# Blast radius: 1 old DML + 1 queuing DDL = ALL new application DML blocked.
#
# Drill sequence:
#   t=0s   Session A: BEGIN; UPDATE (holds lock for DML_HOLD seconds)
#   t=5s   Session B: ALTER TABLE ... ADD COLUMN → queues behind A
#   t=8s   Sessions C/D/E: simple UPDATEs → queue behind B (NOT behind A)
#          These would succeed normally if B were not in the queue.
#
# Resolution options:
#   Option 1: Cancel Session B (DDL) — C/D/E unblock immediately; A continues
#   Option 2: Terminate Session A (old DML) — B proceeds then C/D/E proceed
#
# Key diagnostic: use the recursive blocking tree (09_lock_triage_queries.sql
# §3) to show the full A → B → C → D → E chain.
#
# Usage:
#   ./18_simulate_lock_queue_amplification.sh [dml_hold_seconds] [--yes]
#
# Default: dml_hold_seconds=60
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

DML_HOLD="${1:-60}"

echo "=== DRILL: Lock Queue Amplification ==="
echo "Target          : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Session A (DML) : UPDATE held for ${DML_HOLD}s"
echo "Session B (DDL) : ALTER TABLE — starts t=5s, queues behind A"
echo "Sessions C/D/E  : independent DML — start t=8s, queue behind B"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs 1 old DML + 1 queuing ALTER TABLE that ends up blocking 3 unrelated DML sessions." "$@"

# Clean up any leftover column from a previous drill run
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER TABLE lock_test_accounts DROP COLUMN IF EXISTS queue_amplification_drill;" \
     2>/dev/null || true

echo ""
echo "--- Session A (t=0): long UPDATE — holds RowExclusiveLock for ${DML_HOLD}s ---"
echo "    This is the 'innocent' transaction that starts the chain."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_lqa_session_a';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 1;
         SELECT pg_sleep(${DML_HOLD});
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session A / long DML] #' &
PID_A=$!
echo "  Session A spawned (shell pid ${PID_A})"

sleep 5

echo ""
echo "--- Session B (t=5s): ALTER TABLE — needs ACCESS EXCLUSIVE, queues behind A ---"
echo "    Once A finishes, B will hold ACCESS EXCLUSIVE and block ALL subsequent DML."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_lqa_session_b';
         ALTER TABLE lock_test_accounts ADD COLUMN queue_amplification_drill TEXT;" \
     2>&1 | sed 's#^#  [Session B / ALTER TABLE] #' &
PID_B=$!
echo "  Session B spawned (shell pid ${PID_B}) — queuing behind Session A"

sleep 3

echo ""
echo "--- Sessions C, D, E (t=8s): independent DML — queue behind Session B's DDL ---"
echo "    None of these conflict with Session A's lock directly."
echo "    They are blocked solely because Session B is ahead in the lock queue."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_lqa_session_c';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 2;
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session C / DML] #' &
PID_C=$!

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_lqa_session_d';
         BEGIN;
         UPDATE lock_test_accounts SET balance = balance + 1 WHERE id = 3;
         ROLLBACK;" \
     2>&1 | sed 's#^#  [Session D / DML] #' &
PID_D=$!

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_lqa_session_e';
         SELECT count(*) FROM lock_test_accounts;" \
     2>&1 | sed 's#^#  [Session E / SELECT] #' &
PID_E=$!

echo "  Sessions C, D, E spawned — all queuing behind Session B"

echo ""
echo "Drill is LIVE. Full amplification chain: A → B → C → D → E"
echo ""
echo "  -- See the full blocking chain (recursive tree):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Quick view — all drill sessions:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, state, wait_event_type,"
echo "               pg_blocking_pids(pid) AS blockers,"
echo "               now()-query_start AS query_age, left(query,60) AS query"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE '%drill_lqa%'"
echo "         ORDER BY query_age DESC NULLS LAST;\""
echo ""
echo "  -- RESOLUTION OPTION 1: Cancel Session B (DDL) — C/D/E unblock immediately."
echo "  -- Session A continues its DML normally. DDL must be rescheduled."
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_cancel_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_lqa_session_b';\""
echo ""
echo "  -- RESOLUTION OPTION 2: Terminate Session A (old DML)."
echo "  -- B proceeds with ALTER, then C/D/E execute. Only do this after validating"
echo "  -- that Session A's rollback has no business impact."
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_lqa_session_a';\""
echo ""
echo "Prevention: all DDL in production must use SET lock_timeout = '5s'"
echo "so it fails fast instead of queuing and amplifying the blast radius."
echo ""
echo "Session A releases after ${DML_HOLD}s. Waiting for all sessions..."
wait
echo ""

# Drop the drill column if Session B completed before being cancelled
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER TABLE lock_test_accounts DROP COLUMN IF EXISTS queue_amplification_drill;" \
     2>/dev/null || true
ensure_min_duration 30
echo "Drill column cleaned up. Drill complete."
