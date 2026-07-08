#!/usr/bin/env bash
# =============================================================================
# 03_pgbouncer_health_check.sh
# Connection Exhaustion - PgBouncer Admin Console Health Check
# SysCloud DAL Team
#
# Connects to the PgBouncer admin virtual database and evaluates SHOW POOLS;
# against standard thresholds:
#   maxwait > 30s   -> WARN  (visible client latency)
#   maxwait > 120s  -> CRITICAL
#
# Usage (credentials from .env in the current directory, see .env.example):
#   ./03_pgbouncer_health_check.sh
#
# Exit codes: 0 = OK, 1 = WARN, 2 = CRITICAL, 3 = connection error
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

WARN_THRESHOLD_SEC="${WARN_THRESHOLD_SEC:-30}"
CRIT_THRESHOLD_SEC="${CRIT_THRESHOLD_SEC:-120}"

PSQL=(psql -h "${PGBOUNCER_HOST}" -p "${PGBOUNCER_PORT}" -U "${PGBOUNCER_ADMIN_USER}" -d pgbouncer -t -A -F ',')
export PGPASSWORD="${PGBOUNCER_ADMIN_PASSWORD}"

echo "=== PgBouncer Health Check :: ${PGBOUNCER_HOST}:${PGBOUNCER_PORT} :: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

if ! pools_output=$("${PSQL[@]}" -c "SHOW POOLS;" 2>&1); then
    echo "ERROR: could not connect to PgBouncer admin console."
    echo "${pools_output}"
    exit 3
fi

echo ""
echo "--- SHOW POOLS ---"
echo "database,user,cl_active,cl_waiting,sv_active,sv_idle,sv_used,sv_tested,sv_login,maxwait,maxwait_us,pool_mode"
echo "${pools_output}"

# Evaluate the highest maxwait across all pools (column 10, 0-indexed -> field 10)
max_observed=0
worst_db=""
while IFS=',' read -r dbname user cl_active cl_waiting sv_active sv_idle sv_used sv_tested sv_login maxwait rest; do
    [[ -z "${dbname:-}" ]] && continue
    if [[ "${maxwait}" =~ ^[0-9]+$ ]] && (( maxwait > max_observed )); then
        max_observed=${maxwait}
        worst_db="${dbname} (user: ${user}, cl_waiting: ${cl_waiting})"
    fi
done <<< "${pools_output}"

echo ""
echo "--- Evaluation ---"
echo "Highest maxwait observed: ${max_observed}s ${worst_db:+(${worst_db})}"

if (( max_observed >= CRIT_THRESHOLD_SEC )); then
    echo "STATUS: CRITICAL — maxwait >= ${CRIT_THRESHOLD_SEC}s. Treat as a pool-saturation incident."
    exit 2
elif (( max_observed >= WARN_THRESHOLD_SEC )); then
    echo "STATUS: WARN — maxwait >= ${WARN_THRESHOLD_SEC}s. Investigate pool saturation (see 07_simulate_pool_saturation.sh for repro)."
    exit 1
else
    echo "STATUS: OK — maxwait below warning threshold."
    exit 0
fi
