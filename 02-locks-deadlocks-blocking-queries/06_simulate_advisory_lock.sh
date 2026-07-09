#!/usr/bin/env bash
# =============================================================================
# 06_simulate_advisory_lock.sh
# Locks & Deadlocks DRILL — Advisory Lock Contention Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#
# Reproduces pg_advisory_lock contention:
#   Session A acquires pg_advisory_lock(LOCK_KEY) and holds it for HOLD_SECONDS.
#   Session B tries pg_advisory_lock(LOCK_KEY) → blocks until A releases.
#   Session C tries pg_try_advisory_lock(LOCK_KEY) → returns false immediately
#             (non-blocking; demonstrates the recommended application pattern).
#
# Real-world SysCloud context: advisory locks are used to serialise certain
# job-processing paths. If the holding session crashes without calling
# pg_advisory_unlock, all callers queue indefinitely — terminating the holding
# session is the only resolution.
#
# Detection query:
#   SELECT pid, usename, application_name, state,
#          now() - xact_start AS age, left(query, 100) AS query
#   FROM   pg_stat_activity
#   WHERE  query ILIKE '%pg_advisory_lock%';
#
# Usage:
#   ./06_simulate_advisory_lock.sh [lock_key] [hold_seconds] [--yes]
#
# Defaults: lock_key=99999, hold_seconds=900 — clears the hunter's 300s poll
# interval (actions/locks-deadlocks-blocking-queries.jsonc) with 3 ticks of
# overlap so AL-1 advisory_lock_blocking (waiter_count>=1) is reliably
# sampled. CEILING WARNING: SysCloud baseline lock_timeout=10s/statement_timeout=5min
# (runbook §7.3) would otherwise abort Session B's blocking pg_advisory_lock()
# call almost immediately — disabled below for these sessions only.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

LOCK_KEY="${1:-99999}"
HOLD_SECONDS="${2:-900}"

echo "=== DRILL: Advisory Lock Contention ==="
echo "Target    : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Lock key  : ${LOCK_KEY}"
echo "Hold      : ${HOLD_SECONDS}s"
confirm_drill "Holds pg_advisory_lock(${LOCK_KEY}) for ${HOLD_SECONDS}s while a second session blocks waiting for it." "$@"

echo ""
echo "--- Session A: acquiring pg_advisory_lock(${LOCK_KEY}) for ${HOLD_SECONDS}s ---"

# Session A: acquires the advisory lock, sleeps, then releases.
# pg_advisory_lock is session-level — it persists across transaction boundaries
# and must be explicitly released with pg_advisory_unlock.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_advisory_holder';
         SET statement_timeout = 0;
         SET idle_in_transaction_session_timeout = 0;
         SELECT pg_advisory_lock(${LOCK_KEY});
         SELECT pg_sleep(${HOLD_SECONDS});
         SELECT pg_advisory_unlock(${LOCK_KEY});" \
     2>&1 | sed 's#^#  [Session A / holder] #' &
HOLDER_PID=$!
echo "  Session A spawned (shell pid ${HOLDER_PID}) — holds pg_advisory_lock(${LOCK_KEY})"

sleep 2

echo ""
echo "--- Session B: pg_advisory_lock(${LOCK_KEY}) — will block on Session A ---"

# Session B: blocking call — waits until A releases or is terminated.
# This is the common production anti-pattern: blocking callers accumulate.
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_advisory_waiter';
         SET statement_timeout = 0;
         SET lock_timeout = 0;
         SELECT pg_advisory_lock(${LOCK_KEY});
         SELECT pg_advisory_unlock(${LOCK_KEY});" \
     2>&1 | sed 's#^#  [Session B / waiter] #' &
WAITER_PID=$!
echo "  Session B spawned (shell pid ${WAITER_PID}) — BLOCKED waiting for lock ${LOCK_KEY}"

sleep 1

echo ""
echo "--- Session C: pg_try_advisory_lock(${LOCK_KEY}) — non-blocking, returns false ---"

# Session C: demonstrates the preferred pattern — non-blocking try.
# Returns false immediately when the lock is unavailable instead of queuing.
RESULT=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
              -t -A \
              -c "SET application_name = 'drill_advisory_nonblocking';
                  SELECT pg_try_advisory_lock(${LOCK_KEY});")
echo "  pg_try_advisory_lock(${LOCK_KEY}) returned: ${RESULT}"
echo "  (false = lock unavailable; non-blocking — this is the correct application pattern)"

echo ""
echo "Drill is LIVE."
echo ""
echo "  Detect advisory lock holder:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, state, now()-xact_start AS age,"
echo "               left(query,100)"
echo "         FROM  pg_stat_activity"
echo "         WHERE query ILIKE '%pg_advisory_lock%';\""
echo ""
echo "Session A releases after ${HOLD_SECONDS}s. Waiting..."
wait
ensure_min_duration 30
echo "All drill sessions have completed."
