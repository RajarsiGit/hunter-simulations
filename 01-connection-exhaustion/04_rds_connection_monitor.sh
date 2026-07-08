#!/usr/bin/env bash
# =============================================================================
# 04_rds_connection_monitor.sh
# Connection Exhaustion - RDS max_connections Saturation Monitor
# SysCloud DAL Team
#
# Checks current pg_stat_activity usage against max_connections.
# Intended for cron / Grafana alert hook / on-call scripted checks.
#
# Usage (credentials from .env in the current directory, see .env.example):
#   ./04_rds_connection_monitor.sh
#
# Thresholds (override via env):
#   WARN_PCT=80   -> pre-emptive alert
#   CRIT_PCT=95   -> imminent exhaustion
#
# Exit codes: 0 = OK, 1 = WARN, 2 = CRITICAL, 3 = connection error
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

WARN_PCT="${WARN_PCT:-80}"
CRIT_PCT="${CRIT_PCT:-95}"

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -t -A -F ',')

echo "=== RDS Connection Monitor :: ${PGHOST}:${PGPORT}/${PGDATABASE} :: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

query="SELECT
  (SELECT count(*) FROM pg_stat_activity) AS used,
  (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_conn;"

if ! result=$("${PSQL[@]}" -c "${query}" 2>&1); then
    echo "ERROR: could not connect to RDS instance."
    echo "${result}"
    exit 3
fi

used=$(echo "${result}" | cut -d',' -f1 | tr -d '[:space:]')
max_conn=$(echo "${result}" | cut -d',' -f2 | tr -d '[:space:]')

if ! [[ "${used}" =~ ^[0-9]+$ ]] || ! [[ "${max_conn}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unexpected query output (used='${used}', max_conn='${max_conn}')"
    echo "Raw result: ${result}"
    exit 3
fi

pct=$(( used * 100 / max_conn ))

echo "Used: ${used} / ${max_conn} (${pct}%)"

# Also surface idle-in-transaction count > 5 min as a contributing factor
idle_query="SELECT count(*) FROM pg_stat_activity
            WHERE state = 'idle in transaction'
            AND state_change < now() - interval '5 minutes';"
idle_count=$("${PSQL[@]}" -c "${idle_query}" 2>/dev/null | tr -d '[:space:]')
idle_count="${idle_count:-0}"
echo "Idle-in-transaction (>5min): ${idle_count}"

# And plain idle connections from a single app/client — leak signal (Issue Guide §8.3 S2)
leak_query="SELECT application_name || ':' || COALESCE(host(client_addr), 'local'), count(*)
            FROM pg_stat_activity
            WHERE state = 'idle'
            GROUP BY 1 ORDER BY 2 DESC LIMIT 1;"
top_idle=$("${PSQL[@]}" -c "${leak_query}" 2>/dev/null || true)
[[ -n "${top_idle}" ]] && echo "Top idle-connection source (app:client_addr,count): ${top_idle}"

echo ""
if (( pct >= CRIT_PCT )); then
    echo "STATUS: CRITICAL — ${pct}% of max_connections in use. Run 01_diagnostic_queries.sql immediately."
    exit 2
elif (( pct >= WARN_PCT )); then
    echo "STATUS: WARN — ${pct}% of max_connections in use. Pre-emptive investigation recommended."
    exit 1
else
    echo "STATUS: OK."
    exit 0
fi
