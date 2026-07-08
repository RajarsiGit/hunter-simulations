#!/usr/bin/env bash
# =============================================================================
# 06_simulate_idle_in_transaction.sh
# Connection Exhaustion DRILL — Idle-in-Transaction Blocker Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     This script opens transactions and deliberately does NOT commit them.
#
# All sessions are tagged with application_name='drill_idle_txn' so they
# can be found with 01_diagnostic_queries.sql and cleaned up with
# 08_cleanup_drill_sessions.sql (-v app_pattern='%drill_idle_txn%').
#
# Usage:
#   ./06_simulate_idle_in_transaction.sh [num_sessions] [hold_seconds] [target_table] [--yes]
#
# Example: 5 sessions, each holding a row lock for 10 minutes, non-interactive
#   ./06_simulate_idle_in_transaction.sh 5 600 my_test_table --yes
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

mapfile -t ARGS < <(strip_flags "$@")
NUM_SESSIONS="${ARGS[0]:-3}"
HOLD_SECONDS="${ARGS[1]:-300}"
TARGET_TABLE="${ARGS[2]:-}"

echo "=== DRILL: Idle-in-Transaction Simulator ==="
echo "Target: ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Sessions: ${NUM_SESSIONS} | Hold duration: ${HOLD_SECONDS}s"
[[ -n "${TARGET_TABLE}" ]] && echo "Target table: ${TARGET_TABLE} (will acquire row lock via SELECT ... FOR UPDATE)"

confirm_drill "This opens ${NUM_SESSIONS} idle-in-transaction session(s) that will not commit for ${HOLD_SECONDS}s." "$@"

# Note: output from the ${NUM_SESSIONS} background psql processes will
# interleave/garble on screen since they print to the same terminal
# concurrently — that's cosmetic only and does not affect the drill.
# Pass TARGET_TABLE schema-qualified if it isn't in your default search_path
# (e.g. "myschema.mytable").
PIDS=()
for i in $(seq 1 "${NUM_SESSIONS}"); do
    if [[ -n "${TARGET_TABLE}" ]]; then
        # Acquires a real row lock via SELECT ... FOR UPDATE, then idles —
        # reproduces a genuine blocking tree without needing to know any
        # real column names (ctid is a system column and cannot be assigned to).
        SQL="SET application_name='drill_idle_txn'; BEGIN; SELECT * FROM ${TARGET_TABLE} WHERE ctid = (SELECT ctid FROM ${TARGET_TABLE} LIMIT 1 OFFSET ${i}) FOR UPDATE; SELECT pg_sleep(${HOLD_SECONDS});"
    else
        # No lock, just an open transaction consuming a backend slot
        SQL="SET application_name='drill_idle_txn'; BEGIN; SELECT 1; SELECT pg_sleep(${HOLD_SECONDS});"
    fi
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c "${SQL}" &
    PIDS+=($!)
    echo "Spawned session $i (shell pid $!)"
done

echo ""
echo "${NUM_SESSIONS} idle-in-transaction sessions running (application_name='drill_idle_txn')."
echo "Verify with:"
echo "  psql ... -c \"SELECT pid, state, now()-state_change FROM pg_stat_activity WHERE application_name='drill_idle_txn';\""
echo ""
echo "Clean up early (before natural expiry) with:"
echo "  psql -v app_pattern='%drill_idle_txn%' -f 08_cleanup_drill_sessions.sql"
echo ""
echo "Waiting for sessions to self-expire after ${HOLD_SECONDS}s..."
wait
echo "All drill sessions have completed/expired."
