#!/usr/bin/env bash
# =============================================================================
# 20_lock_incident_rca.sh
# Locks & Deadlocks — Automated Incident Classification & RCA
# SysCloud DAL Team
#
# NEW (not a port): derived from the "Lock Troubleshooting" agent-workflow
# runbook — collects a session snapshot + lock snapshot, classifies the
# incident type, computes blast radius, and prints an RCA report in the
# same shape a human first-responder would fill in by hand. Complements
# 09_lock_triage_queries.sql (raw diagnostic queries) with an automated
# classification + narrative summary — useful for an agent to run first on
# any "something is blocked" report.
#
# Read-only by default (safe mode) — never modifies session state unless you
# explicitly pass --remediate-cancel or --remediate-terminate.
#
# Classification logic (best-effort from SQL alone — see caveats printed at
# the end for signals that need an external check: deadlock-in-CloudWatch-logs,
# PgBouncer cl_waiting):
#   1. Idle-in-transaction session blocking others  → "Idle transaction blocking"
#   2. A waiting ALTER/CREATE/DROP/TRUNCATE          → "DDL blocking"
#   3. Connection usage >= 90% of max_connections     → "Connection exhaustion"
#   4. Any blocked session (blockers non-empty)        → "Generic lock contention"
#   5. None of the above                                → "No blocking detected"
#
# Usage:
#   ./20_lock_incident_rca.sh [--remediate-cancel|--remediate-terminate] [--yes]
#
# Default (no flags): safe mode — prints the full RCA report only.
# --remediate-cancel   : after the report, pg_cancel_backend() the identified
#                        primary blocker (requires confirmation unless --yes).
# --remediate-terminate: same, but pg_terminate_backend() (stronger — requires
#                        confirmation unless --yes; only use with policy approval).
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

REMEDIATE=""
for arg in "$@"; do
    case "${arg}" in
        --remediate-cancel)    REMEDIATE="cancel" ;;
        --remediate-terminate) REMEDIATE="terminate" ;;
    esac
done

PSQL=(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}")

echo "============================================================"
echo "  Lock Incident RCA — ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo 'timestamp unavailable')"
echo "============================================================"

echo ""
echo "--- Step 1: Session snapshot ---"
"${PSQL[@]}" -c "
SELECT pid, usename, application_name, client_addr, state,
       wait_event_type, wait_event, backend_type,
       now() - xact_start  AS xact_age,
       now() - query_start AS query_age,
       pg_blocking_pids(pid) AS blocking_pids,
       left(query, 150) AS query
FROM   pg_stat_activity
WHERE  pid <> pg_backend_pid()
ORDER  BY xact_start NULLS LAST, query_start NULLS LAST;"

echo ""
echo "--- Step 2: Lock snapshot ---"
"${PSQL[@]}" -c "
SELECT l.pid, a.application_name, a.usename, a.client_addr,
       l.locktype, l.relation::regclass AS relation_name,
       l.mode, l.granted, a.state, a.wait_event_type, a.wait_event,
       left(a.query, 150) AS query
FROM   pg_locks l
JOIN   pg_stat_activity a ON a.pid = l.pid
ORDER  BY l.granted, l.pid;"

echo ""
echo "--- Step 3: Classification signals ---"
# One row: idle_blockers|ddl_waiting|conn_pct|blocked_count
SIGNALS=$("${PSQL[@]}" -t -A -F'|' -c "
SELECT
  (SELECT count(DISTINCT b.pid)
     FROM pg_stat_activity b
     JOIN pg_stat_activity w
       ON w.pid <> b.pid
      AND b.pid = ANY(pg_blocking_pids(w.pid))
    WHERE b.state = 'idle in transaction')                         AS idle_blockers,
  (SELECT count(*)
     FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0
      AND query ~* '^\s*(ALTER|CREATE|DROP|TRUNCATE)')              AS ddl_waiting,
  (SELECT round(100.0 * count(*) / current_setting('max_connections')::int, 1)
     FROM pg_stat_activity)                                        AS conn_pct,
  (SELECT count(*) FROM pg_stat_activity
    WHERE cardinality(pg_blocking_pids(pid)) > 0)                   AS blocked_count;")

IFS='|' read -r IDLE_BLOCKERS DDL_WAITING CONN_PCT BLOCKED_COUNT <<< "${SIGNALS}"

echo "  idle_in_txn_blockers=${IDLE_BLOCKERS}  ddl_waiting=${DDL_WAITING}  conn_pct=${CONN_PCT}  blocked_count=${BLOCKED_COUNT}"

if   [[ "${IDLE_BLOCKERS}" -gt 0 ]]; then CATEGORY="Idle transaction blocking"
elif [[ "${DDL_WAITING}"   -gt 0 ]]; then CATEGORY="DDL blocking"
elif (( $(echo "${CONN_PCT} >= 90" | bc -l 2>/dev/null || echo 0) )); then CATEGORY="Connection exhaustion"
elif [[ "${BLOCKED_COUNT}" -gt 0 ]]; then CATEGORY="Generic lock contention"
else CATEGORY="No blocking detected"
fi

echo "  → Classification: ${CATEGORY}"
echo "  (Deadlock-in-logs and PgBouncer cl_waiting are NOT queryable from SQL —"
echo "   cross-check CloudWatch Logs and 'SHOW POOLS;' on PgBouncer if this"
echo "   classification doesn't match what you're seeing.)"

echo ""
echo "--- Step 4: Blast radius (blocker → number of sessions it blocks) ---"
"${PSQL[@]}" -c "
SELECT unnest(pg_blocking_pids(pid)) AS blocker_pid,
       count(*) AS blocked_session_count
FROM   pg_stat_activity
WHERE  cardinality(pg_blocking_pids(pid)) > 0
GROUP  BY blocker_pid
ORDER  BY blocked_session_count DESC;"

PRIMARY_BLOCKER=$("${PSQL[@]}" -t -A -c "
SELECT blocker_pid FROM (
  SELECT unnest(pg_blocking_pids(pid)) AS blocker_pid
  FROM   pg_stat_activity
  WHERE  cardinality(pg_blocking_pids(pid)) > 0
) b
GROUP BY blocker_pid
ORDER BY count(*) DESC
LIMIT 1;")

echo ""
echo "--- Step 5: RCA ---"
if [[ -n "${PRIMARY_BLOCKER}" ]]; then
    "${PSQL[@]}" -c "
SELECT pid AS primary_blocker_pid, application_name, usename, client_addr, state,
       now() - xact_start AS xact_age, left(query, 200) AS blocking_query
FROM   pg_stat_activity
WHERE  pid = ${PRIMARY_BLOCKER};"
    echo ""
    echo "  Incident type      : ${CATEGORY}"
    echo "  Primary blocker pid: ${PRIMARY_BLOCKER}"
    echo "  Blocked sessions   : see Step 4 above"
    echo "  Recommended action : ROLLBACK/COMMIT by the app owner if possible;"
    echo "                       pg_cancel_backend for an active query,"
    echo "                       pg_terminate_backend if idle-in-transaction"
    echo "                       (pg_cancel_backend has no effect on idle-in-txn)."
    echo "  Risk of termination: rolls back any uncommitted work on that session —"
    echo "                       confirm business impact before acting."
    echo "  Prevention         : idle_in_transaction_session_timeout, lock_timeout,"
    echo "                       statement_timeout, log_lock_waits=on."
else
    echo "  No blocked sessions found — nothing to classify. Re-run during the incident."
fi

echo ""
echo "--- Step 6: Remediation mode ---"
if [[ -z "${REMEDIATE}" ]]; then
    echo "  SAFE MODE (default) — no action taken. Recommendations only."
    if [[ -n "${PRIMARY_BLOCKER}" ]]; then
        echo "  To act on primary blocker pid=${PRIMARY_BLOCKER}, re-run with:"
        echo "    ./20_lock_incident_rca.sh --remediate-cancel      (pg_cancel_backend — for an active query)"
        echo "    ./20_lock_incident_rca.sh --remediate-terminate   (pg_terminate_backend — for idle-in-transaction; needs policy approval)"
    fi
elif [[ -z "${PRIMARY_BLOCKER}" ]]; then
    echo "  --remediate-${REMEDIATE} requested but no primary blocker was found. Nothing to do."
else
    if [[ "${REMEDIATE}" == "cancel" ]]; then
        confirm_drill "About to pg_cancel_backend(${PRIMARY_BLOCKER}) — the identified primary blocker." "$@"
        "${PSQL[@]}" -c "SELECT pg_cancel_backend(${PRIMARY_BLOCKER});"
    else
        confirm_drill "About to pg_terminate_backend(${PRIMARY_BLOCKER}) — the identified primary blocker. This rolls back any open transaction on that session." "$@"
        "${PSQL[@]}" -c "SELECT pg_terminate_backend(${PRIMARY_BLOCKER});"
    fi
    echo "  Remediation executed. Re-run this script or 09_lock_triage_queries.sql to confirm resolution."
fi

echo ""
echo "============================================================"
echo "  RCA complete."
echo "============================================================"
