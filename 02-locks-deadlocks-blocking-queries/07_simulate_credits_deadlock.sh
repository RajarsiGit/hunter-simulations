#!/usr/bin/env bash
# =============================================================================
# 07_simulate_credits_deadlock.sh
# Locks & Deadlocks DRILL — Multi-Module User Credits Deadlock Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces the real SysCloud user-credits deadlock production incident:
#
#   Multiple modules (backup start, deletion, inactive deletion) all update the
#   same user's credit balance. Each module had a different row acquisition
#   order, which could form a cyclic wait when two modules ran concurrently
#   against the same set of users.
#
# Simulation:
#   Module 1 (backup start):  UPDATE user 1 first, then user 2
#   Module 2 (deletion):      UPDATE user 2 first, then user 1
#
#   This creates the same cyclic dependency that caused production deadlocks.
#   The fix: standardise lock acquisition order across all modules
#   (always update user with lower id first). This script also demonstrates
#   that fixed approach in DRY_RUN=fixed mode.
#
# Usage:
#   ./07_simulate_credits_deadlock.sh [mode] [--yes]
#
# mode:
#   buggy  (default) — reproduces the deadlock as it occurred in production
#   fixed            — demonstrates the correct ordered-lock approach (no deadlock)
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-buggy}"

if [[ "${MODE}" != "buggy" && "${MODE}" != "fixed" ]]; then
    echo "Usage: $0 [buggy|fixed] [--yes]"
    exit 1
fi

echo "=== DRILL: Multi-Module User Credits Deadlock ==="
echo "Target : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Mode   : ${MODE}"
echo ""
if [[ "${MODE}" == "buggy" ]]; then
    echo "  BUGGY mode: Module 1 updates user 1→2; Module 2 updates user 2→1."
    echo "  Expected: deadlock detected by PostgreSQL after deadlock_timeout."
else
    echo "  FIXED mode: Both modules update in the same order (lower user_id first)."
    echo "  Expected: no deadlock — one module serialises behind the other."
fi
echo ""
echo "⚠️  Requires lock_test_credits (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Runs two concurrent credit-update modules in mode='${MODE}'." "$@"

# Reset credits before each run
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "UPDATE lock_test_credits SET credits = 500 WHERE user_id = 1;
         UPDATE lock_test_credits SET credits = 750 WHERE user_id = 2;" > /dev/null

BEFORE=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
              -t -A -c "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database();")
echo "Deadlock counter before drill: ${BEFORE}"
echo ""

if [[ "${MODE}" == "buggy" ]]; then
    # -----------------------------------------------------------------------
    # BUGGY — different update order between modules → deadlock cycle
    # -----------------------------------------------------------------------
    echo "--- Module 1 (backup start): user 1 first, then user 2 ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_credits_module1';
             SET deadlock_timeout = '2s';
             BEGIN;
             UPDATE lock_test_credits SET credits = credits - 50 WHERE user_id = 1;
             SELECT pg_sleep(2);
             UPDATE lock_test_credits SET credits = credits + 10 WHERE user_id = 2;
             COMMIT;" \
         2>&1 | sed 's/^/  [Module 1] /' &
    PID1=$!
    echo "  Module 1 spawned (shell pid ${PID1})"

    sleep 1

    echo ""
    echo "--- Module 2 (deletion): user 2 first, then user 1 (reverse order = deadlock) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_credits_module2';
             SET deadlock_timeout = '2s';
             BEGIN;
             UPDATE lock_test_credits SET credits = credits - 20 WHERE user_id = 2;
             SELECT pg_sleep(2);
             UPDATE lock_test_credits SET credits = credits - 5  WHERE user_id = 1;
             COMMIT;" \
         2>&1 | sed 's/^/  [Module 2] /' &
    PID2=$!
    echo "  Module 2 spawned (shell pid ${PID2})"

    echo ""
    echo "Deadlock cycle forming (same pattern as the production incident)."
    echo "Both sessions SET deadlock_timeout='2s' (production baseline is 15s,"
    echo "runbook §7.3) so PostgreSQL aborts one module in a few seconds instead"
    echo "of up to 15s — keeps this drill under the 20s ceiling."
    echo ""
    echo "Observe:"
    echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
    echo "    -c \"SELECT pid, application_name, state, wait_event_type,"
    echo "               pg_blocking_pids(pid) AS blockers"
    echo "         FROM  pg_stat_activity"
    echo "         WHERE application_name LIKE '%drill_credits%';\""
    echo ""

    wait "${PID1}" "${PID2}" || true

else
    # -----------------------------------------------------------------------
    # FIXED — consistent update order (lower user_id first) → no deadlock
    # -----------------------------------------------------------------------
    echo "--- Module 1 (backup start): user 1 first, then user 2 (ordered) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_credits_fixed_m1';
             BEGIN;
             UPDATE lock_test_credits SET credits = credits - 50 WHERE user_id = 1;
             SELECT pg_sleep(2);
             UPDATE lock_test_credits SET credits = credits + 10 WHERE user_id = 2;
             COMMIT;" \
         2>&1 | sed 's/^/  [Module 1 fixed] /' &
    PID1=$!
    echo "  Module 1 spawned (shell pid ${PID1})"

    sleep 1

    echo ""
    echo "--- Module 2 (deletion): ALSO user 1 first, then user 2 (same order = safe) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name = 'drill_credits_fixed_m2';
             BEGIN;
             UPDATE lock_test_credits SET credits = credits - 5  WHERE user_id = 1;
             SELECT pg_sleep(1);
             UPDATE lock_test_credits SET credits = credits - 20 WHERE user_id = 2;
             COMMIT;" \
         2>&1 | sed 's/^/  [Module 2 fixed] /' &
    PID2=$!
    echo "  Module 2 spawned (shell pid ${PID2}) — will serialise behind Module 1, not deadlock"

    echo ""
    echo "Module 2 waits for Module 1 to commit user 1, then proceeds."
    echo "No cycle forms — one module serialises behind the other."
    echo ""

    wait "${PID1}" "${PID2}"
fi

sleep 1

AFTER=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
             -t -A -c "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database();")
DELTA=$(( AFTER - BEFORE ))

echo ""
echo "=== Result (mode: ${MODE}) ==="
echo "Deadlock counter: ${BEFORE} → ${AFTER} (delta: +${DELTA})"

if [[ "${MODE}" == "buggy" ]]; then
    if [[ "${DELTA}" -ge 1 ]]; then
        echo "✓ Deadlock reproduced successfully. SQLSTATE 40P01 received by one module."
    else
        echo "⚠️  No deadlock counted — check timing or table setup."
    fi
else
    if [[ "${DELTA}" -eq 0 ]]; then
        echo "✓ No deadlock — consistent lock ordering prevented the cycle."
        echo "  This is the fix applied in production after the incident."
    else
        echo "⚠️  Unexpected deadlock in fixed mode — investigate timing."
    fi
fi

echo ""
echo "Final credit balances:"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT user_id, credits FROM lock_test_credits ORDER BY user_id;"

ensure_min_duration 12
