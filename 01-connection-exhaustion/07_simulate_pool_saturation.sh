#!/usr/bin/env bash
# =============================================================================
# 07_simulate_pool_saturation.sh
# Connection Exhaustion DRILL — PgBouncer Pool / Connection Saturation Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test environment.
#     Opens many concurrent connections THROUGH PgBouncer to saturate
#     default_pool_size / max_client_conn (transaction-pool exhaustion).
#
# All sessions are tagged with application_name='drill_pool_saturation'.
#
# Usage:
#   ./07_simulate_pool_saturation.sh [num_connections] [hold_seconds] [--yes]
#
# Defaults: num_connections=500, hold_seconds=60 — sized for a ~1 minute
# local drill window. What this saturates is PgBouncer's per-pool
# default_pool_size (server-side slots), NOT max_client_conn: once
# num_connections exceeds default_pool_size, every excess client queues,
# driving PB-ps-1 (maxwait>=30s OR cl_waiting>=20) and PB-ps-2
# (maxwait>=120s CRITICAL) in connection-summary's pgbouncer_saturation
# source. A 60s hold is still well under the hunter's 300s poll interval, so
# hunter-detection reliability is NOT guaranteed at the default; pass a
# larger hold_seconds explicitly (e.g. 2400, ~8 poll ticks of overlap) if you
# need PB-ps-1/PB-ps-2 to be reliably observed. NOTE: PB-cc-1/PB-cc-2
# (max_client_conn, default_pool_size aside — that ceiling is typically
# huge: the production baseline is 200000, precedent-widened to 150000
# during Box onboarding per the jsonc header) are NOT realistically
# reachable by a client-count drill at this scale and aren't the target here
# — cl_waiting/maxwait are.
#
# Example: open 200 concurrent connections through PgBouncer, hold for 2 minutes
#   ./07_simulate_pool_saturation.sh 200 120 --yes
#
# Watch impact live with (from a separate shell):
#   psql -h <pgbouncer-host> -p <port> -U postgres pgbouncer -c "SHOW POOLS;"
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

mapfile -t ARGS < <(strip_flags "$@")
NUM_CONNECTIONS="${ARGS[0]:-500}"
HOLD_SECONDS="${ARGS[1]:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-150}"   # batch size to avoid overwhelming the local shell

echo "=== DRILL: PgBouncer Pool Saturation Simulator ==="
echo "Target (via PgBouncer): ${PGBOUNCER_HOST}:${PGBOUNCER_PORT}/${PGDATABASE}"
echo "Connections: ${NUM_CONNECTIONS} | Hold duration: ${HOLD_SECONDS}s | Batch size: ${MAX_PARALLEL}"

confirm_drill "This opens ${NUM_CONNECTIONS} concurrent connections through PgBouncer for ${HOLD_SECONDS}s." "$@"

echo ""
echo "NOTE: ${NUM_CONNECTIONS} concurrent PgBouncer client connections may exceed"
echo "max_client_conn on a small drill pooler, or the OS's open-files/process"
echo "ulimits on this machine. If psql starts failing partway through, check"
echo "\`SHOW CONFIG;\` on the PgBouncer admin console for max_client_conn (and"
echo "\`ulimit -n\`/\`ulimit -u\` here) rather than assuming the drill needs more."

run_one() {
    psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name='drill_pool_saturation'; SELECT pg_sleep(${HOLD_SECONDS});" \
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
echo "${NUM_CONNECTIONS} connections in flight (application_name='drill_pool_saturation')."
echo "Check PgBouncer state with:"
echo "  psql -h ${PGBOUNCER_HOST} -p ${PGBOUNCER_PORT} -U ${PGBOUNCER_ADMIN_USER} pgbouncer -c 'SHOW POOLS;'"
echo "  psql -h ${PGBOUNCER_HOST} -p ${PGBOUNCER_PORT} -U ${PGBOUNCER_ADMIN_USER} pgbouncer -c 'SHOW STATS;'"
echo ""
echo "Waiting for connections to self-expire after ${HOLD_SECONDS}s..."
wait
echo "Drill complete."
