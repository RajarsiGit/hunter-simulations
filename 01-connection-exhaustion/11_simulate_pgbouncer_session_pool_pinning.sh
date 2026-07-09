#!/usr/bin/env bash
# =============================================================================
# 11_simulate_pgbouncer_session_pool_pinning.sh
# Connection Exhaustion DRILL — PgBouncer Session-Mode Pool Pinning Simulator
# SysCloud DAL Team
#
# Source: gpt-docs "PgBouncer Connection Exhaustion" Scenario S5 (PgBouncer
# Session Pool Exhaustion) and "ChatGPT - Senthil" §10.8 Scenario G.
#
# ⚠️  NON-PRODUCTION USE ONLY.
#     Requires the target PgBouncer database to already be configured with
#     `pool_mode = session` (this is a config fact, not something this
#     script can set — session-mode pinning cannot be reproduced under
#     transaction/statement pooling). Opens exactly `default_pool_size`
#     long-lived client sessions through PgBouncer (each pins one server
#     connection for its whole lifetime), then attempts one more connection
#     to demonstrate it queues behind the pinned pool — distinct from both
#     06 (DB-side idle-in-txn) and 07 (transaction-pool saturation): here
#     the extra client may never even reach Postgres, it queues inside
#     PgBouncer itself.
#
# All sessions are tagged with application_name='drill_session_pinning'.
#
# Usage:
#   ./11_simulate_pgbouncer_session_pool_pinning.sh [pool_size] [hold_seconds] [--yes]
#
# Defaults: pool_size=20, hold_seconds=2400 (extreme — see actions/
# connection-exhaustion.jsonc PB-ps-1/PB-ps-2: maxwait>=30s warning /
# >=120s critical for a client queued behind a pinned session-mode pool.
# 2400s holds the pool pinned 20x past the critical threshold and gives ~8
# ticks of overlap with the hunter's 300s poll interval, vs. the previous
# 180s default which barely cleared the 120s critical mark at all.
#
# IMPORTANT: pool_size here should match (or exceed) the TARGET's actual
# configured default_pool_size for pool_mode=session — pinning fewer
# sessions than the real pool size leaves headroom and won't reproduce
# anything; pinning far more than it doesn't make the demonstration more
# "extreme", it just opens extra clients that queue behind the real ceiling
# for no added signal. Confirm the real value first via trans-db-router
# query_pgbouncer(host, "SHOW CONFIG") or pgbouncer.ini before overriding
# this default with arg 1.
#
# Example: pin a pool of 5, hold for 3 minutes, then probe the 6th client
#   ./11_simulate_pgbouncer_session_pool_pinning.sh 5 180 --yes
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

mapfile -t ARGS < <(strip_flags "$@")
POOL_SIZE="${ARGS[0]:-20}"
HOLD_SECONDS="${ARGS[1]:-2400}"

echo "=== DRILL: PgBouncer Session-Mode Pool Pinning Simulator ==="
echo "Target (via PgBouncer): ${PGBOUNCER_HOST}:${PGBOUNCER_PORT}/${PGDATABASE}"
echo "Pinned sessions: ${POOL_SIZE} | Hold duration: ${HOLD_SECONDS}s"

echo ""
echo "--- Checking PgBouncer pool_mode for ${PGDATABASE} ---"
PSQL_ADMIN=(psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${PGBOUNCER_ADMIN_USER}" -d pgbouncer -t -A -F ',')
PGPASSWORD="${PGBOUNCER_ADMIN_PASSWORD}" "${PSQL_ADMIN[@]}" -c "SHOW DATABASES;" 2>&1 | grep -i "^${PGDATABASE}," || \
    echo "(could not confirm pool_mode automatically — verify manually with 'SHOW DATABASES;' / 'SHOW CONFIG;')"
echo "This drill only reproduces pinning if pool_mode=session for this database/pgbouncer.ini."

confirm_drill "This opens ${POOL_SIZE} long-lived sessions through PgBouncer to pin its entire session-mode server pool for ${HOLD_SECONDS}s." "$@"

PIDS=()
for i in $(seq 1 "${POOL_SIZE}"); do
    psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
         -c "SET application_name='drill_session_pinning'; SELECT pg_sleep(${HOLD_SECONDS});" \
         >/dev/null 2>&1 &
    PIDS+=($!)
    echo "Pinned session ${i}/${POOL_SIZE} (shell pid $!)"
done

sleep 1
echo ""
echo "--- Probing one extra client connection (expected to wait/queue in PgBouncer) ---"
start_ts=$(date +%s)
if timeout 10 psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name='drill_session_pinning_probe'; SELECT 1;" >/tmp/drill_probe.log 2>&1; then
    elapsed=$(( $(date +%s) - start_ts ))
    echo "Probe connection succeeded after ${elapsed}s (pool had headroom, or pool_mode isn't 'session' — check config)."
else
    echo "Probe connection timed out/waited — this is the expected pinning signature."
fi
cat /tmp/drill_probe.log 2>/dev/null || true
rm -f /tmp/drill_probe.log

echo ""
echo "Check PgBouncer waiters directly with:"
echo "  psql -h ${PGBOUNCER_HOST} -p ${PGBOUNCER_PORT} -U ${PGBOUNCER_ADMIN_USER} pgbouncer -c 'SHOW POOLS;'"
echo "Note: pg_blocking_pids()/pg_stat_activity on RDS will NOT show this contention —"
echo "it never reaches Postgres. That distinction is the key diagnostic signal for this failure mode."
echo ""
echo "Waiting for pinned sessions to self-expire after ${HOLD_SECONDS}s..."
wait
echo "Drill complete."
