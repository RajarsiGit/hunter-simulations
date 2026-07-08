#!/usr/bin/env bash
# =============================================================================
# 17_simulate_workflow_blockage.sh
# Locks & Deadlocks DRILL — Application Workflow Blockage Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces business workflow blockage where a database row represents a
# job/workflow state and one worker holds the lock.
#
# SysCloud context: backup, restore, and export workers claim job rows with
# SELECT ... FOR UPDATE. If a worker crashes or hangs while holding a row lock,
# all other workers attempting the same job_key spin-wait indefinitely.
#
# Two modes:
#
# Mode A: stuck_worker  (default)
#   Session A: claims a workflow row with FOR UPDATE (simulates crashed worker).
#   Session B: tries SELECT ... FOR UPDATE on same row → blocked.
#   Session C: uses FOR UPDATE SKIP LOCKED → succeeds immediately on a different
#              row (demonstrates the correct production pattern).
#   Resolution: terminate Session A, reset job status idempotently.
#
# Mode B: skip_locked_demo
#   Three worker sessions each claim a different job using SKIP LOCKED.
#   Shows how SKIP LOCKED prevents any session from blocking another.
#   Each worker picks the next available PENDING job without contention.
#
# Usage:
#   ./17_simulate_workflow_blockage.sh [mode] [hold_seconds] [--yes]
#
# mode: stuck_worker (default) | skip_locked_demo
# Default: hold_seconds=90
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-stuck_worker}"
HOLD_SECONDS="${2:-90}"

if [[ "${MODE}" != "stuck_worker" && "${MODE}" != "skip_locked_demo" ]]; then
    echo "Usage: $0 [stuck_worker|skip_locked_demo] [hold_seconds] [--yes]"
    exit 1
fi

echo "=== DRILL: Application Workflow Blockage ==="
echo "Target : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Mode   : ${MODE}"
echo ""
echo "⚠️  Requires lock_test_workflow_jobs (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs workflow blockage mode='${MODE}' against lock_test_workflow_jobs." "$@"

echo ""
echo "--- Current workflow jobs ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT id, job_key, status, updated_at FROM lock_test_workflow_jobs ORDER BY id;"

echo ""

if [[ "${MODE}" == "stuck_worker" ]]; then
    # -------------------------------------------------------------------------
    # Mode A: crashed/stuck worker holds FOR UPDATE row lock
    # -------------------------------------------------------------------------
    echo "--- Mode A: Stuck worker blocking subsequent workers ---"
    echo ""
    echo "--- Session A: worker claims 'backup-user-1001' with FOR UPDATE (then hangs) ---"

    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_workflow_stuck_worker';
             BEGIN;
             UPDATE lock_test_workflow_jobs
             SET status = 'RUNNING', updated_at = now()
             WHERE job_key = 'backup-user-1001'
               AND status IN ('PENDING','RUNNING')
             RETURNING id, job_key, status;
             SELECT pg_sleep(${HOLD_SECONDS});
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session A / stuck worker] #' &
    SESS_A_PID=$!
    echo "  Session A spawned (shell pid ${SESS_A_PID}) — holding FOR UPDATE on backup-user-1001"

    sleep 2

    echo ""
    echo "--- Session B: second worker tries same job → blocked ---"

    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_workflow_blocked_worker';
             BEGIN;
             SELECT id, job_key, status
             FROM   lock_test_workflow_jobs
             WHERE  job_key = 'backup-user-1001'
             FOR UPDATE;
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session B / blocked worker] #' &
    SESS_B_PID=$!
    echo "  Session B spawned (shell pid ${SESS_B_PID}) — BLOCKED"

    sleep 1

    echo ""
    echo "--- Session C: worker uses SKIP LOCKED → claims a different available job ---"

    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_workflow_skip_locked_worker';
             BEGIN;
             UPDATE lock_test_workflow_jobs j
             SET status = 'RUNNING', updated_at = now()
             FROM (
                 SELECT id FROM lock_test_workflow_jobs
                 WHERE  status = 'PENDING'
                 ORDER  BY id
                 FOR UPDATE SKIP LOCKED
                 LIMIT  1
             ) next
             WHERE  j.id = next.id
             RETURNING j.id, j.job_key, j.status;
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session C / SKIP LOCKED worker] #'
    echo "  Session C completed immediately — SKIP LOCKED bypassed the stuck worker's job"

    echo ""
    echo "Drill is LIVE. Observe in another terminal:"
    echo ""
    echo "  -- Who is blocking whom on workflow_jobs?"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT a.pid, a.application_name, a.state,"
    echo "               a.wait_event_type, a.wait_event,"
    echo "               now()-a.query_start AS query_age,"
    echo "               pg_blocking_pids(a.pid) AS blockers,"
    echo "               left(a.query, 100) AS query"
    echo "         FROM  pg_stat_activity a"
    echo "         WHERE a.application_name LIKE '%drill_workflow%'"
    echo "         ORDER BY query_age DESC;\""
    echo ""
    echo "  -- Confirm: is the stuck worker still alive in application logs?"
    echo "  -- Terminate stuck worker + reset job status idempotently:"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT pg_terminate_backend(pid)"
    echo "         FROM  pg_stat_activity"
    echo "         WHERE application_name = 'drill_workflow_stuck_worker';\""
    echo ""
    echo "  -- After termination, reset stuck job (idempotent — only resets old RUNNING rows):"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"UPDATE lock_test_workflow_jobs"
    echo "         SET status = 'PENDING', updated_at = now()"
    echo "         WHERE job_key = 'backup-user-1001'"
    echo "           AND status = 'RUNNING'"
    echo "           AND updated_at < now() - interval '30 minutes';\""
    echo ""
    echo "Session A releases after ${HOLD_SECONDS}s. Waiting..."
    wait
    ensure_min_duration 30
    echo "All drill sessions completed."

else
    # -------------------------------------------------------------------------
    # Mode B: SKIP LOCKED demonstration — no blocking between workers
    # -------------------------------------------------------------------------
    echo "--- Mode B: SKIP LOCKED — three workers claim jobs concurrently with no blocking ---"
    echo ""

    # Reset all jobs to PENDING for a clean demo
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "UPDATE lock_test_workflow_jobs SET status = 'PENDING', updated_at = now();" > /dev/null
    echo "  All jobs reset to PENDING."
    echo ""

    for worker_num in 1 2 3; do
        echo "--- Worker ${worker_num}: claiming next PENDING job with FOR UPDATE SKIP LOCKED ---"
        psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
             -c "SET application_name = 'drill_skip_locked_worker_${worker_num}';
                 WITH next_job AS (
                     SELECT id
                     FROM   lock_test_workflow_jobs
                     WHERE  status = 'PENDING'
                     ORDER  BY id
                     FOR UPDATE SKIP LOCKED
                     LIMIT  1
                 )
                 UPDATE lock_test_workflow_jobs j
                 SET    status = 'RUNNING', updated_at = now()
                 FROM   next_job
                 WHERE  j.id = next_job.id
                 RETURNING j.id, j.job_key, j.status;" \
             2>&1 | sed "s/^/  [Worker ${worker_num}] /"
        sleep 0.5
    done

    echo ""
    echo "--- Final job status (3 jobs claimed, none blocked each other) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SELECT id, job_key, status, updated_at FROM lock_test_workflow_jobs ORDER BY id;"
    ensure_min_duration 30
    echo ""
    echo "SKIP LOCKED demo complete — workers never wait for each other."
fi
