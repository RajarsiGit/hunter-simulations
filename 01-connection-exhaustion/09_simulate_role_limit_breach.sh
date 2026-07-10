#!/usr/bin/env bash
# =============================================================================
# 09_simulate_role_limit_breach.sh
# Connection Exhaustion DRILL — Role/DB Connection Limit Breach Simulator
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY.
#     Temporarily sets a low CONNECTION LIMIT on a drill role, then opens
#     more connections than the limit allows to trigger the real Postgres
#     error: "FATAL: too many connections for role"
#
# Requires a dedicated DRILL ROLE that already exists and is safe to limit
# (do NOT point this at a real application role on a shared instance).
# Set DRILL_ROLE / DRILL_ROLE_PASSWORD in .env (see .env.example) — PGUSER
# must be a superuser able to run ALTER ROLE.
#
# Usage:
#   ./09_simulate_role_limit_breach.sh [connection_limit] [attempt_count] [--yes]
#
# Defaults: connection_limit=8, attempt_count=15 — capped for fast local
# drilling (total run stays under ~20s, including the per-attempt check
# delay below and the final hold). Filling the limit to exactly 8/8
# successful connections is 100% of it, comfortably past both actions/
# connection-exhaustion.jsonc RL-1/RL-2 thresholds (role_limit_warning
# pct_of_limit>=0.75, role_limit_critical>=0.90), while the remaining ~7
# attempts demonstrate the real "too many connections for role" failure.
# Each successful connection holds pg_sleep(8) — well under the hunter's
# 300s poll interval, so hunter-detection reliability is NOT guaranteed at
# the default; pass larger connection_limit/attempt_count (and bump the
# hardcoded pg_sleep below) if you need multi-tick poll coverage.
#
# Example: limit drill_role to 3 connections, then attempt 6
#   ./09_simulate_role_limit_breach.sh 3 6 --yes
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

: "${DRILL_ROLE:?Set DRILL_ROLE (in .env) — an existing, dedicated test role}"
: "${DRILL_ROLE_PASSWORD:?Set DRILL_ROLE_PASSWORD (in .env)}"

mapfile -t ARGS < <(strip_flags "$@")
CONN_LIMIT="${ARGS[0]:-8}"
ATTEMPTS="${ARGS[1]:-15}"

echo "=== DRILL: Role Connection Limit Breach Simulator ==="
echo "Role: ${DRILL_ROLE} | Limit to apply: ${CONN_LIMIT} | Connection attempts: ${ATTEMPTS}"

confirm_drill "Confirm '${DRILL_ROLE}' is a dedicated, disposable test role — this will temporarily restrict it." "$@"

echo ""
echo "--- Applying CONNECTION LIMIT ${CONN_LIMIT} to ${DRILL_ROLE} ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER ROLE ${DRILL_ROLE} CONNECTION LIMIT ${CONN_LIMIT};"

echo ""
echo "--- Attempting ${ATTEMPTS} connections as ${DRILL_ROLE} (expect failures beyond ${CONN_LIMIT}) ---"
success=0
failed=0
for i in $(seq 1 "${ATTEMPTS}"); do
    if PGPASSWORD="${DRILL_ROLE_PASSWORD}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${DRILL_ROLE}" -d "${PGDATABASE}" \
         -c "SET application_name='drill_role_limit'; SELECT pg_sleep(8);" >/tmp/drill_attempt_${i}.log 2>&1 &
    then
        pid=$!
        sleep 0.1
        if kill -0 "${pid}" 2>/dev/null; then
            echo "Attempt ${i}: connection open (pid ${pid})"
            success=$((success+1))
        else
            echo "Attempt ${i}: FAILED — $(tail -n1 /tmp/drill_attempt_${i}.log)"
            failed=$((failed+1))
        fi
    fi
done

echo ""
echo "Successful: ${success} | Failed (expected once limit exceeded): ${failed}"
echo ""
echo "--- Leaving CONNECTION LIMIT ${CONN_LIMIT} in place while the ${success} open"
echo "    session(s) hold pg_sleep(8) — restoring it now would drop rolconnlimit"
echo "    back to -1 immediately, which excludes this role from connection-roles.sql"
echo "    (WHERE rolconnlimit NOT IN (0,-1)) and makes RL-1/RL-2 unobservable for"
echo "    the rest of the hold. The role is restricted for real for the ~8s"
echo "    below — that's the point, not a side effect."
echo ""
echo "Waiting for drill connections to finish (max 8s)..."
wait

echo ""
echo "--- Restoring role to unlimited ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "ALTER ROLE ${DRILL_ROLE} CONNECTION LIMIT -1;"
rm -f /tmp/drill_attempt_*.log
echo "Drill complete. Role limit restored to unlimited."
