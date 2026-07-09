#!/usr/bin/env bash
# =============================================================================
# 14_simulate_vacuum_full_blocking.sh
# Locks & Deadlocks DRILL — Autovacuum / VACUUM FULL Blocking Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces two vacuum blocking patterns:
#
# Mode A: vacuum_full_blocks_dml  (default)
#   Session A runs VACUUM FULL lock_test_accounts.
#   VACUUM FULL acquires ACCESS EXCLUSIVE MODE — the strongest possible lock.
#   Session B (SELECT) and Session C (UPDATE) both block until VACUUM FULL
#   finishes, identical to TRUNCATE or REINDEX blocking behaviour.
#   The key lesson: never run VACUUM FULL during business hours on busy tables.
#
# Mode B: long_txn_blocks_vacuum
#   Session A opens a long transaction holding an old snapshot.
#   Session B runs VACUUM; vacuum cannot advance past Session A's horizon.
#   Autovacuum behaves the same way. The dead tuples accumulate.
#   Detection: check pg_stat_progress_vacuum for heap_blks_vacuumed stalling.
#
# What to observe (Mode A):
#   - VACUUM FULL: state='active', query='vacuum full ...',
#     l.mode='AccessExclusiveLock', l.granted=true
#   - Sessions B/C: wait_event_type='Lock', wait_event='relation',
#     l.granted=false
#   - pg_cancel_backend(<vacuum_pid>) cancels it; sessions B/C unblock
#
# Usage:
#   ./14_simulate_vacuum_full_blocking.sh [mode] [--yes]
#
# mode: vacuum_full_blocks_dml (default) | long_txn_blocks_vacuum
#
# COVERAGE GAP (left as-is, not fixed by this pass): mode A's AccessExclusiveLock
# is only held for as long as VACUUM FULL actually takes, and lock_test_accounts
# has only 5 rows (01_setup_lock_drill_tables.sql) — VACUUM FULL on a table
# that small completes in milliseconds regardless of the few dead tuples
# created below. That's nowhere near the hunter's 300s poll interval
# (actions/locks-deadlocks-blocking-queries.jsonc), so DC-1 ddl_blocking_detected
# will rarely if ever be sampled while this mode's lock is actually held.
# Making this reliably detectable needs a much larger/bloated table (the same
# fix slow-queries applied — seed millions of rows) — out of scope here since
# lock_test_accounts is shared by ~10 other quick drills in this folder that
# depend on it staying small and fast. If you need DC-1 coverage from VACUUM
# FULL specifically, point this at a large table instead. Timeout overrides
# below are still applied so waiters don't error out before observing it.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-vacuum_full_blocks_dml}"

if [[ "${MODE}" != "vacuum_full_blocks_dml" && "${MODE}" != "long_txn_blocks_vacuum" ]]; then
    echo "Usage: $0 [vacuum_full_blocks_dml|long_txn_blocks_vacuum] [--yes]"
    exit 1
fi

echo "=== DRILL: Vacuum/VACUUM FULL Blocking ==="
echo "Target : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Mode   : ${MODE}"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs vacuum blocking mode='${MODE}' against lock_test_accounts." "$@"

echo ""

if [[ "${MODE}" == "vacuum_full_blocks_dml" ]]; then
    # -------------------------------------------------------------------------
    # Mode A: VACUUM FULL acquires ACCESS EXCLUSIVE, blocks all reads and writes
    # -------------------------------------------------------------------------
    echo "--- Session A: VACUUM FULL lock_test_accounts (ACCESS EXCLUSIVE) ---"
    echo "    This blocks ALL reads and writes on the table."
    echo ""

    # First create enough bloat to make VACUUM FULL take some time
    echo "Creating dead tuples to give VACUUM FULL some work to do..."
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "UPDATE lock_test_accounts SET balance = balance + 1;
             UPDATE lock_test_accounts SET balance = balance + 1;
             UPDATE lock_test_accounts SET balance = balance + 1;" > /dev/null

    echo ""
    echo "--- Session A: VACUUM FULL ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_vacuum_full';
             SET statement_timeout = 0;
             VACUUM FULL lock_test_accounts;" \
         2>&1 | sed 's#^#  [Session A / VACUUM FULL] #' &
    VACUUM_PID=$!
    echo "  Session A spawned (shell pid ${VACUUM_PID})"

    sleep 1

    echo ""
    echo "--- Session B: SELECT on lock_test_accounts — will block ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_vacuum_full_reader';
             SET statement_timeout = 0;
             SET lock_timeout = 0;
             SELECT count(*) FROM lock_test_accounts;" \
         2>&1 | sed 's#^#  [Session B / reader] #' &
    READER_PID=$!
    echo "  Session B spawned (shell pid ${READER_PID}) — blocked on ACCESS EXCLUSIVE"

    sleep 1

    echo ""
    echo "--- Session C: UPDATE on lock_test_accounts — will also block ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_vacuum_full_writer';
             SET statement_timeout = 0;
             SET lock_timeout = 0;
             BEGIN;
             UPDATE lock_test_accounts SET balance = balance + 99 WHERE id = 1;
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session C / writer] #' &
    WRITER_PID=$!
    echo "  Session C spawned (shell pid ${WRITER_PID}) — blocked on ACCESS EXCLUSIVE"

    echo ""
    echo "Drill is LIVE. Observe in another terminal:"
    echo ""
    echo "  -- Who holds AccessExclusiveLock?"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT a.pid, a.application_name, a.state,"
    echo "               l.locktype, l.mode, l.granted,"
    echo "               pg_blocking_pids(a.pid) AS blockers, a.query"
    echo "         FROM  pg_locks l"
    echo "         JOIN  pg_stat_activity a ON a.pid = l.pid"
    echo "         WHERE l.relation = 'lock_test_accounts'::regclass"
    echo "         ORDER BY l.granted DESC;\""
    echo ""
    echo "  -- VACUUM progress:"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT pid, phase, heap_blks_total, heap_blks_vacuumed FROM pg_stat_progress_vacuum;\""
    echo ""
    echo "  -- Cancel VACUUM FULL to unblock Sessions B/C (if needed in emergency):"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT pg_cancel_backend(pid)"
    echo "         FROM  pg_stat_activity"
    echo "         WHERE application_name = 'drill_vacuum_full';\""
    echo ""
    echo "Prevention: never run VACUUM FULL during business hours."
    echo "  Use pg_repack instead (where approved), or schedule off-peak."
    echo ""

    wait
    ensure_min_duration 30
    echo "All drill sessions completed."

else
    # -------------------------------------------------------------------------
    # Mode B: long-running transaction prevents vacuum from reclaiming dead rows
    # -------------------------------------------------------------------------
    echo "--- Mode B: long transaction blocks vacuum cleanup ---"
    echo "    Session A opens a long snapshot; Session B creates dead tuples;"
    echo "    VACUUM cannot advance its cleanup horizon past Session A."
    echo ""

    echo "--- Session A: long-running transaction (holds old snapshot) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_vacuum_txn_blocker';
             SET statement_timeout = 0;
             SET idle_in_transaction_session_timeout = 0;
             BEGIN ISOLATION LEVEL REPEATABLE READ;
             SELECT count(*) FROM lock_test_accounts;
             SELECT pg_sleep(900);
             ROLLBACK;" &
    HOLDER_PID=$!
    echo "  Session A spawned (shell pid ${HOLDER_PID}) — holds old snapshot (900s — not gated by"
    echo "  a check in THIS hunter, bumped only for consistency with the folder's other drills)"

    sleep 2

    echo ""
    echo "--- Session B: generating dead tuples then running VACUUM ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_vacuum_workload';
             UPDATE lock_test_accounts SET balance = balance + 1;
             DELETE FROM lock_test_accounts WHERE id = 5;
             SELECT pg_sleep(10);
             VACUUM (VERBOSE, ANALYZE) lock_test_accounts;" \
         2>&1 | sed 's/^/  [Session B] /'

    echo ""
    echo "  -- Check n_dead_tup after VACUUM (expect > 0 while Session A holds snapshot):"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SELECT relname, n_live_tup, n_dead_tup, last_vacuum
             FROM   pg_stat_user_tables
             WHERE  relname = 'lock_test_accounts';"

    echo ""
    echo "  -- Find Session A by old backend_xmin:"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SELECT pid, application_name, backend_xmin,
                    now()-xact_start AS xact_age, state
             FROM   pg_stat_activity
             WHERE  application_name = 'drill_vacuum_txn_blocker';"

    echo ""
    echo "  -- Full long-transaction triage (09_lock_triage_queries.sql §7):"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -f 09_lock_triage_queries.sql"
    echo ""
    echo "Session A auto-releases after 900s. Waiting..."
    wait
    ensure_min_duration 30
    echo "Drill complete."
fi
