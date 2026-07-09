#!/usr/bin/env bash
# =============================================================================
# 07_simulate_retry_storm.sh
# Slow Queries DRILL — Application Retry Storm
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_slow_query_tables.sql first.
# Opens many concurrent connections and hammers the same query with no
# backoff — mirrors an application retrying an already-slow query, which
# multiplies load instead of recovering from it.
#
# Usage:
#   ./07_simulate_retry_storm.sh [session_count] [retries_per_session] [--yes]
#
# Defaults: session_count=1500, retries_per_session=300 (extreme — 450x the
# original baseline call volume; can itself trigger connection-exhaustion
# symptoms alongside the slow-query signal — that's expected here).
#
# NOTE: 1500 concurrent connections may exceed max_connections on a small
# drill instance (RDS default formula is roughly DBInstanceClassMemory /
# 9531392, often a few hundred to ~1-2k on small/medium classes) and/or the
# OS's open-files/process ulimits on the machine running this script. If
# psql starts failing with "FATAL: too many connections" or "FATAL: sorry,
# too many clients already" partway through, that's max_connections capping
# actual concurrency below SESSION_COUNT — check `SHOW max_connections;` on
# the target and raise it (or lower SESSION_COUNT) rather than assuming the
# drill isn't generating enough load.
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

POSARGS=()
while IFS= read -r line; do POSARGS+=("${line}"); done < <(strip_flags "$@")
SESSION_COUNT="${POSARGS[0]:-1500}"
RETRIES="${POSARGS[1]:-300}"

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")

echo "=== DRILL: Application Retry Storm ==="
echo "Sessions: ${SESSION_COUNT} | Retries per session: ${RETRIES}"

confirm_drill "This opens ${SESSION_COUNT} concurrent connections, each re-running a query ${RETRIES} times back-to-back with no backoff — real load against ${PGDATABASE}." "$@"

echo ""
echo "--- Launching ${SESSION_COUNT} retry-storm sessions ---"
pids=()
for i in $(seq 1 "${SESSION_COUNT}"); do
    (
        for _ in $(seq 1 "${RETRIES}"); do
            "${PSQL[@]}" -c "SET application_name = 'drill_retry_storm';
                              SELECT count(*) FROM slowq_orders WHERE status = 'failed';" >/dev/null
        done
    ) &
    pids+=("$!")
done
echo "Spawned ${#pids[@]} background sessions (pids: ${pids[*]})"

sleep 1
echo ""
echo "--- Session count grouped by application_name/client_addr (storm in progress) ---"
"${PSQL[@]}" -c "SELECT application_name, client_addr, count(*) AS sessions
                  FROM pg_stat_activity
                  WHERE application_name = 'drill_retry_storm'
                  GROUP BY application_name, client_addr
                  ORDER BY sessions DESC;"

echo ""
echo "Waiting for all retry-storm sessions to finish..."
wait "${pids[@]}" 2>/dev/null || true

echo ""
echo "--- pg_stat_statements for the storm query (if extension installed) ---"
"${PSQL[@]}" -c "SELECT calls, mean_exec_time, total_exec_time, left(query, 120) AS query
                  FROM pg_stat_statements
                  WHERE query ILIKE '%slowq_orders%status%'
                  ORDER BY calls DESC LIMIT 5;" 2>/dev/null \
    || echo "(pg_stat_statements not available/installed — skipped)"

echo ""
ensure_min_duration 2400
echo "Drill complete. Real fixes: disable aggressive client-side retry, add backoff+jitter,"
echo "add a circuit breaker, rate-limit the failing endpoint, and fix the root slow query."
