#!/usr/bin/env bash
# =============================================================================
# 10_simulate_idle_connection_storm.sh
# Connection Exhaustion DRILL — Plain Idle Connection Storm / Leak Simulator
# SysCloud DAL Team
#
# Source: gpt-docs "RDS Postgres Issue Guide" §8.3 Scenario 1 (Direct
# connection storm) / Scenario 2 (Connection leak) / Scenario 5 (deploy
# creates session storm), and "ChatGPT - Senthil" §11.6 Rule 1
# (APPLICATION_CONNECTION_LEAK classifier).
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Distinct from 06 (idle-in-transaction): these connections open, run
#     one statement, then go plain 'idle' (no open transaction) and stay
#     connected — reproducing a leaked-connection-pool / deploy-scale-out
#     storm rather than a lock-holding blocker.
#
# All sessions are tagged with application_name='drill_idle_conn_storm'.
#
# Usage:
#   ./10_simulate_idle_connection_storm.sh [num_connections] [hold_seconds] [--yes]
#
# Defaults: num_connections=500, hold_seconds=8 — capped for fast local
# drilling (total run stays under ~20s). These connections still count
# toward connections_pct_used in connection-summary.sql (actions/
# connection-exhaustion.jsonc C-1/C-2: >=80% warning / >=95% critical of
# max_connections), but 8s is well under the hunter's 300s poll interval, so
# hunter-detection reliability is NOT guaranteed at the default; pass a
# larger hold_seconds explicitly (e.g. 2400, ~8 poll ticks of overlap) if you
# need this drill to be reliably observed.
#
# Example: open 150 plain idle connections directly against RDS for 10 minutes
#   ./10_simulate_idle_connection_storm.sh 150 600 --yes
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

mapfile -t ARGS < <(strip_flags "$@")
NUM_CONNECTIONS="${ARGS[0]:-500}"
HOLD_SECONDS="${ARGS[1]:-8}"
MAX_PARALLEL="${MAX_PARALLEL:-150}"

echo "=== DRILL: Idle Connection Storm / Leak Simulator ==="
echo "Target (direct, bypassing PgBouncer): ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Connections: ${NUM_CONNECTIONS} | Idle duration: ${HOLD_SECONDS}s | Batch size: ${MAX_PARALLEL}"

confirm_drill "This opens ${NUM_CONNECTIONS} plain idle (no transaction) connections directly against RDS for ${HOLD_SECONDS}s — simulates a leaked pool / deploy scale-out storm." "$@"

echo ""
echo "NOTE: ${NUM_CONNECTIONS} concurrent connections may exceed max_connections on a"
echo "small drill instance, or the OS's open-files/process ulimits on this machine."
echo "If psql starts failing with \"FATAL: too many connections\" partway through,"
echo "that's max_connections capping actual concurrency below NUM_CONNECTIONS — check"
echo "\`SHOW max_connections;\` on the target (and \`ulimit -n\`/\`ulimit -u\` here)"
echo "rather than assuming the drill needs to be bigger."

run_one() {
    # SELECT 1 completes immediately, then the backend sits at state='idle'
    # (not 'idle in transaction') for the remainder of pg_sleep — this is
    # the "leaked connection" signature, distinct from 06's held-open txn.
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name='drill_idle_conn_storm'; SELECT 1; SELECT pg_sleep(${HOLD_SECONDS});" \
         >/dev/null 2>&1 &
}

launched=0
while (( launched < NUM_CONNECTIONS )); do
    batch=$(( NUM_CONNECTIONS - launched < MAX_PARALLEL ? NUM_CONNECTIONS - launched : MAX_PARALLEL ))
    for _ in $(seq 1 "${batch}"); do
        run_one
    done
    launched=$(( launched + batch ))
    echo "Launched ${launched}/${NUM_CONNECTIONS} connections..."
    sleep 0.5
done

echo ""
echo "${NUM_CONNECTIONS} plain-idle connections in flight (application_name='drill_idle_conn_storm')."
echo "Verify with (note state='idle', NOT 'idle in transaction'):"
echo "  psql -c \"SELECT state, count(*) FROM pg_stat_activity WHERE application_name='drill_idle_conn_storm' GROUP BY state;\""
echo ""
echo "Waiting for connections to self-expire after ${HOLD_SECONDS}s..."
wait
echo "Drill complete."
