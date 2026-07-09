#!/usr/bin/env bash
# =============================================================================
# 13_simulate_fk_contention.sh
# Locks & Deadlocks DRILL — Foreign Key Contention Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces two FK contention patterns:
#
# Mode A: child_blocks_parent
#   Session A inserts a child row referencing parent_id=1 → holds shared lock.
#   Session B tries to DELETE the parent row (id=1) → blocked by Session A.
#   Real-world: deleting a backup account/org that still has in-flight jobs.
#
# Mode B: parent_blocks_child
#   Session A deletes parent row (id=2) but does not commit.
#   Session B inserts a child row referencing parent_id=2 → blocked (FK check).
#   Real-world: concurrent parent delete + child insert race in backup workflows.
#
# FK contention is often confused with row-lock blocking. The tell is:
#   - lock_test_parent shows a SIReadLock or RowShareLock held by the child INSERT
#   - The blocked session query is on a different table than the blocker's query
#
# Usage:
#   ./13_simulate_fk_contention.sh [mode] [hold_seconds] [--yes]
#
# mode: child_blocks_parent (default) | parent_blocks_child
# Default: hold_seconds=900 — clears the hunter's 300s poll interval
# (actions/locks-deadlocks-blocking-queries.jsonc) with 3 ticks of overlap so
# FK-1 fk_contention_detected (waiter_count>=1 on a ShareRowExclusiveLock,
# queries/locks-deadlocks-blocking-queries/fk-contention.sql) is reliably
# sampled while Session B is queued.
#
# CEILING WARNING: SysCloud baseline (runbook §7.3) lock_timeout=10s and
# statement_timeout=5min would otherwise abort Session B almost immediately
# and cut Session A's hold at 300s — both disabled below for these sessions.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-child_blocks_parent}"
HOLD_SECONDS="${2:-900}"

if [[ "${MODE}" != "child_blocks_parent" && "${MODE}" != "parent_blocks_child" ]]; then
    echo "Usage: $0 [child_blocks_parent|parent_blocks_child] [hold_seconds] [--yes]"
    exit 1
fi

echo "=== DRILL: Foreign Key Contention ==="
echo "Target : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Mode   : ${MODE}"
echo "Hold   : ${HOLD_SECONDS}s"
echo ""
echo "⚠️  Requires lock_test_parent/child (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs FK contention mode='${MODE}' between lock_test_parent and lock_test_child." "$@"

echo ""
echo "--- Baseline FK data ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT p.id AS parent_id, p.name, c.id AS child_id, c.payload
         FROM   lock_test_parent p
         LEFT   JOIN lock_test_child c ON c.parent_id = p.id
         ORDER  BY p.id, c.id;"

echo ""

if [[ "${MODE}" == "child_blocks_parent" ]]; then
    # -------------------------------------------------------------------------
    # Mode A: child INSERT holds RowShareLock on parent, blocking parent DELETE
    # -------------------------------------------------------------------------
    echo "--- Mode A: child_blocks_parent ---"
    echo "    Session A: INSERT child referencing parent_id=1 (holds transaction open)"
    echo "    Session B: DELETE FROM lock_test_parent WHERE id=1 → blocked"
    echo ""

    echo "--- Session A: insert child row + hold transaction ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_fk_child_inserter';
             SET statement_timeout = 0;
             SET idle_in_transaction_session_timeout = 0;
             BEGIN;
             INSERT INTO lock_test_child (id, parent_id, payload)
             VALUES (100, 1, 'drill-child-hold');
             SELECT pg_sleep(${HOLD_SECONDS});
             ROLLBACK;" &
    SESS_A_PID=$!
    echo "  Session A spawned (shell pid ${SESS_A_PID}) — child insert held open"

    sleep 2

    echo ""
    echo "--- Session B: DELETE parent row (id=1) — blocked by Session A's FK share lock ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_fk_parent_deleter';
             SET statement_timeout = 0;
             SET lock_timeout = 0;
             BEGIN;
             DELETE FROM lock_test_parent WHERE id = 1;
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session B / parent DELETE] #' &
    SESS_B_PID=$!
    echo "  Session B spawned (shell pid ${SESS_B_PID}) — BLOCKED"

else
    # -------------------------------------------------------------------------
    # Mode B: parent DELETE held open, blocking child INSERT (FK check)
    # -------------------------------------------------------------------------
    echo "--- Mode B: parent_blocks_child ---"
    echo "    Session A: DELETE parent row (id=2) — does not commit"
    echo "    Session B: INSERT child row referencing parent_id=2 → blocked"
    echo "    (FK check on insert must verify parent row is committed)"
    echo ""

    echo "--- Session A: DELETE parent (id=2) + hold transaction ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_fk_parent_deleter_hold';
             SET statement_timeout = 0;
             SET idle_in_transaction_session_timeout = 0;
             BEGIN;
             DELETE FROM lock_test_parent WHERE id = 2;
             SELECT pg_sleep(${HOLD_SECONDS});
             ROLLBACK;" &
    SESS_A_PID=$!
    echo "  Session A spawned (shell pid ${SESS_A_PID}) — parent DELETE held open"

    sleep 2

    echo ""
    echo "--- Session B: INSERT child referencing parent_id=2 → blocked on FK check ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_fk_child_inserter_blocked';
             SET statement_timeout = 0;
             SET lock_timeout = 0;
             BEGIN;
             INSERT INTO lock_test_child (id, parent_id, payload)
             VALUES (101, 2, 'drill-child-blocked');
             ROLLBACK;" \
         2>&1 | sed 's#^#  [Session B / child INSERT] #' &
    SESS_B_PID=$!
    echo "  Session B spawned (shell pid ${SESS_B_PID}) — BLOCKED on FK validation"
fi

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- FK contention detection (both tables visible in lock list):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT a.pid, a.application_name, a.state,"
echo "               l.locktype, l.mode, l.granted,"
echo "               l.relation::regclass AS relation_name, a.query"
echo "         FROM  pg_stat_activity a"
echo "         JOIN  pg_locks l ON l.pid = a.pid"
echo "         WHERE a.application_name LIKE '%drill_fk%'"
echo "         ORDER BY l.granted DESC, a.query_start;\""
echo ""
echo "  -- Blocker/blocked pair:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Resolve: let Session A commit/rollback, or terminate:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE '%drill_fk%'"
echo "           AND state = 'idle in transaction';\""
echo ""
echo "Prevention: index FK columns on child tables to avoid full scans."
echo "  CREATE INDEX CONCURRENTLY idx_lock_test_child_parent_id"
echo "  ON lock_test_child(parent_id); -- already in drill setup"
echo ""
echo "Session A releases after ${HOLD_SECONDS}s. Waiting..."
wait
ensure_min_duration 30
echo "All drill sessions completed."
