#!/usr/bin/env bash
# =============================================================================
# 08_simulate_mvw_refresh_lock.sh
# Locks & Deadlocks DRILL — Materialized View Refresh Locking Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces MVW refresh locking behaviour:
#
# Mode A: blocking  — REFRESH MATERIALIZED VIEW (no CONCURRENTLY)
#   Holds AccessExclusiveLock on the MVW during the full refresh.
#   Any SELECT on the MVW blocks until refresh completes.
#   Does NOT require a unique index.
#
# Mode B: concurrent — REFRESH MATERIALIZED VIEW CONCURRENTLY
#   Allows stale reads during refresh (no AccessExclusiveLock held).
#   Requires a unique index on the MVW. Errors if the index is missing
#   or if the unique constraint is violated (duplicate rows in base table).
#   Reproduces the production incident: duplicate in base → unique
#   violation → concurrent refresh fails.
#
# After the refresh completes (or fails), the drill shows the reader
# unblocking (mode A) or reading stale data through the refresh (mode B).
#
# Usage:
#   ./08_simulate_mvw_refresh_lock.sh [mode] [inject_duplicate] [--yes]
#
# mode           : blocking (default) | concurrent
# inject_duplicate: yes | no (default)
#   Set to "yes" in concurrent mode to reproduce the production incident.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-blocking}"
INJECT_DUP="${2:-no}"

if [[ "${MODE}" != "blocking" && "${MODE}" != "concurrent" ]]; then
    echo "Usage: $0 [blocking|concurrent] [inject_duplicate yes|no] [--yes]"
    exit 1
fi

echo "=== DRILL: MVW Refresh Locking ==="
echo "Target           : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Refresh mode     : ${MODE}"
echo "Inject duplicate : ${INJECT_DUP}"
echo ""
if [[ "${MODE}" == "blocking" ]]; then
    echo "  BLOCKING mode: REFRESH MVW holds AccessExclusiveLock."
    echo "  Session B (SELECT on MVW) will block until refresh finishes."
else
    echo "  CONCURRENT mode: REFRESH CONCURRENTLY — allows stale reads."
    if [[ "${INJECT_DUP}" == "yes" ]]; then
        echo "  DUPLICATE INJECT: base table will have a duplicate category row,"
        echo "  causing the unique index violation from the production incident."
    fi
fi
echo ""
echo "⚠️  Requires lock_test_mvw_base and lock_test_mvw (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Refreshes lock_test_mvw in mode='${MODE}' (inject_duplicate=${INJECT_DUP})." "$@"

# ---------------------------------------------------------------------------
# Optional: inject a duplicate to reproduce the production incident
# ---------------------------------------------------------------------------
if [[ "${INJECT_DUP}" == "yes" && "${MODE}" == "concurrent" ]]; then
    echo ""
    echo "Injecting duplicate row (id=999, category='cat-1') into base table..."
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "INSERT INTO lock_test_mvw_base (id, category, amount)
             VALUES (999, 'cat-1', 100.00);"
    echo "  Duplicate injected. REFRESH CONCURRENTLY should now fail with unique violation."
fi

echo ""
echo "--- Session A: REFRESH MATERIALIZED VIEW${MODE:+ }${MODE/blocking/}${MODE/concurrent/ CONCURRENTLY} ---"

if [[ "${MODE}" == "blocking" ]]; then
    # Blocking refresh: holds AccessExclusiveLock for 600 s via pg_sleep before COMMIT
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_mvw_refresh';
             BEGIN;
             REFRESH MATERIALIZED VIEW lock_test_mvw;
             SELECT pg_sleep(600);
             COMMIT;" \
         2>&1 | sed 's#^#  [Session A / refresh] #' &
else
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_mvw_refresh_concurrent';
             REFRESH MATERIALIZED VIEW CONCURRENTLY lock_test_mvw;" \
         2>&1 | sed 's#^#  [Session A / refresh concurrent] #' &
fi
REFRESH_PID=$!
echo "  Session A spawned (shell pid ${REFRESH_PID})"

sleep 1

echo ""
echo "--- Session B: SELECT on lock_test_mvw ---"
echo "    Blocking mode  : will block until refresh completes"
echo "    Concurrent mode: will return stale data immediately (no AccessExclusiveLock)"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_mvw_reader';
         SELECT category, total_amount, row_count FROM lock_test_mvw ORDER BY category;" \
     2>&1 | sed 's#^#  [Session B / reader] #' &
READER_PID=$!
echo "  Session B spawned (shell pid ${READER_PID})"

echo ""
if [[ "${MODE}" == "blocking" ]]; then
    echo "  Detect the AccessExclusiveLock held by Session A:"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT a.pid, a.application_name, a.state,"
    echo "               l.locktype, l.mode, l.granted"
    echo "         FROM  pg_locks l"
    echo "         JOIN  pg_stat_activity a ON a.pid = l.pid"
    echo "         WHERE l.relation = 'lock_test_mvw'::regclass"
    echo "         ORDER BY l.granted DESC;\""
else
    echo "  In concurrent mode Session B should return stale (pre-refresh) data immediately."
    if [[ "${INJECT_DUP}" == "yes" ]]; then
        echo "  CONCURRENT refresh should fail with:"
        echo "    ERROR: could not create unique index ... DETAIL: Key (category)=(cat-1) is duplicated."
        echo "  Fix: delete the duplicate from lock_test_mvw_base, then re-run concurrent refresh."
    fi
fi

wait "${REFRESH_PID}" "${READER_PID}" || true

# ---------------------------------------------------------------------------
# Clean up any injected duplicate
# ---------------------------------------------------------------------------
if [[ "${INJECT_DUP}" == "yes" ]]; then
    echo ""
    echo "Cleaning up injected duplicate row (id=999)..."
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "DELETE FROM lock_test_mvw_base WHERE id = 999;" 2>/dev/null || true
    echo "  Duplicate removed. REFRESH CONCURRENTLY should now succeed."
fi

ensure_min_duration 30
echo ""
echo "Drill complete."
