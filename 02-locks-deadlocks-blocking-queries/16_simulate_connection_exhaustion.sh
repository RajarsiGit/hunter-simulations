#!/usr/bin/env bash
# =============================================================================
# 16_simulate_connection_exhaustion.sh
# Locks & Deadlocks DRILL — Connection Pool / PgBouncer Exhaustion Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#
# Reproduces connection exhaustion and pool saturation. This scenario can look
# like database blocking even when no row/table lock exists: application
# requests time out waiting for a connection slot rather than for a row lock.
# (See also 01-connection-exhaustion/ for the dedicated connection-exhaustion
# drill set, including a PgBouncer-specific pool saturation drill.)
#
# Two modes:
#
# Mode A: idle_connection_flood  (default)
#   Spawns CONN_COUNT psql connections, each holding pg_sleep(HOLD_SECONDS).
#   All connections appear as 'active' or 'idle in transaction', consuming
#   connection slots. The drill shows DatabaseConnections approaching max_connections.
#   Resolution: pg_terminate_backend for idle/old connections.
#
# Mode B: idle_in_txn_flood
#   Spawns connections that each BEGIN a transaction and sleep — simulating
#   application pool leaks where connections hold transactions open.
#   More severe: these hold locks in addition to connection slots.
#
# Detection queries shown:
#   - Connection count vs max_connections
#   - Connection distribution by user/app/state
#   - Identifying leak candidates (oldest idle sessions)
#
# Usage:
#   ./16_simulate_connection_exhaustion.sh [mode] [conn_count] [hold_seconds] [--yes]
#
# mode: idle_connection_flood (default) | idle_in_txn_flood
# Defaults: conn_count=20, hold_seconds=900
#
# This script isn't gated by any check in THIS hunter
# (actions/locks-deadlocks-blocking-queries.jsonc has no connections source —
# that lives in connection-exhaustion.jsonc, see hunter-simulations/01-connection-exhaustion/
# for the dedicated, much more aggressive drill set). hold_seconds is bumped
# to 900 only for consistency with this folder's other drills and to survive
# the SysCloud baseline statement_timeout=5min (runbook §7.3, disabled below).
# conn_count is left at 20 (not re-tuned here) — keep it well below
# max_connections on the drill instance; use topic 01's drills for a real
# connection-exhaustion intensity pass.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

MODE="${1:-idle_connection_flood}"
CONN_COUNT="${2:-20}"
HOLD_SECONDS="${3:-900}"

if [[ "${MODE}" != "idle_connection_flood" && "${MODE}" != "idle_in_txn_flood" ]]; then
    echo "Usage: $0 [idle_connection_flood|idle_in_txn_flood] [conn_count] [hold_seconds] [--yes]"
    exit 1
fi

echo "=== DRILL: Connection Exhaustion ==="
echo "Target       : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Mode         : ${MODE}"
echo "Connections  : ${CONN_COUNT}"
echo "Hold         : ${HOLD_SECONDS}s per connection"
echo ""
echo "⚠️  Keep conn_count well below the instance's max_connections."
confirm_drill "Opens ${CONN_COUNT} connections in mode='${MODE}' held for ${HOLD_SECONDS}s each." "$@"

echo ""
echo "--- Baseline: current connection usage ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT (SELECT count(*) FROM pg_stat_activity) AS used,
                current_setting('max_connections')::int  AS max,
                round(100.0 * (SELECT count(*) FROM pg_stat_activity)
                    / current_setting('max_connections')::int, 1) AS pct_used;"

echo ""
echo "--- Spawning ${CONN_COUNT} connections (mode: ${MODE}) ---"

PIDS=()

for i in $(seq 1 "${CONN_COUNT}"); do
    if [[ "${MODE}" == "idle_connection_flood" ]]; then
        psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
             -c "SET application_name = 'drill_conn_flood_${i}';
                 SET statement_timeout = 0;
                 SELECT pg_sleep(${HOLD_SECONDS});" &>/dev/null &
    else
        # idle_in_txn_flood: BEGIN + sleep inside transaction
        psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
             -c "SET application_name = 'drill_conn_flood_${i}';
                 SET statement_timeout = 0;
                 SET idle_in_transaction_session_timeout = 0;
                 BEGIN;
                 SELECT pg_sleep(${HOLD_SECONDS});
                 ROLLBACK;" &>/dev/null &
    fi
    PIDS+=($!)
done

echo "  Spawned ${CONN_COUNT} connections (shell pids: ${PIDS[0]} … ${PIDS[-1]})"
echo ""

# Give connections time to register in pg_stat_activity
sleep 3

echo "--- Connection count after flood ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT (SELECT count(*) FROM pg_stat_activity) AS used,
                current_setting('max_connections')::int  AS max,
                round(100.0 * (SELECT count(*) FROM pg_stat_activity)
                    / current_setting('max_connections')::int, 1) AS pct_used;"

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- Connection usage snapshot:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT state, wait_event_type, count(*) AS cnt"
echo "         FROM  pg_stat_activity"
echo "         GROUP BY state, wait_event_type"
echo "         ORDER BY cnt DESC;\""
echo ""
echo "  -- Connection distribution by app/user:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT usename, application_name, client_addr, state, count(*)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE 'drill_conn_flood%'"
echo "         GROUP BY usename, application_name, client_addr, state"
echo "         ORDER BY count DESC;\""
echo ""
echo "  -- Connection headroom (09_lock_triage_queries.sql §9):"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -f 09_lock_triage_queries.sql"
echo ""
echo "  -- Emergency: terminate drill connections older than 30s:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name LIKE 'drill_conn_flood%'"
echo "           AND now() - state_change > interval '30 seconds';\""
echo ""
echo "Prevention:"
echo "  idle_session_timeout = '30min'           -- kills leaked idle sessions"
echo "  idle_in_transaction_session_timeout = '5min'  -- kills idle-in-txn"
echo "  Use PgBouncer transaction pooling; right-size app pool size."
echo ""
echo "Waiting for all ${CONN_COUNT} connections to release (${HOLD_SECONDS}s)..."
wait "${PIDS[@]}" || true

echo ""
echo "--- Final connection count (should be back to baseline) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT (SELECT count(*) FROM pg_stat_activity) AS used,
                current_setting('max_connections')::int  AS max,
                round(100.0 * (SELECT count(*) FROM pg_stat_activity)
                    / current_setting('max_connections')::int, 1) AS pct_used;"
ensure_min_duration 30
echo "Drill complete."
