#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Connection Exhaustion: automated end-to-end drill run
# SysCloud DAL Team
#
# AGGRESSIVE MODE: every drill in this folder (idle-in-transaction, PgBouncer
# pool saturation, role-limit breach, idle-connection storm, PgBouncer
# session-pool pinning) launches CONCURRENTLY (not one at a time) to stack
# simultaneous issues and stress the target as hard as possible, then the
# detection scripts run once every drill has finished. Individual scripts
# remain the source of truth; this just sequences/launches them with
# aggressive-by-default sizing and a pass/fail summary.
#
# No mitigation/cleanup step, no confirmation gate: drills fire immediately
# and drill sessions are left running/expiring on their own so the hunters
# have a real window to detect them. Every drill guarantees at least a 25s
# hold/observation window (fast mode) — full mode holds for minutes.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 06,07] [--skip 09,11]
#                [--with-baseline] [--list] [--yes]
#
#   --fast          Small scale/duration (default) — full manifest finishes
#                    in a few minutes.
#   --full          Doc-example scale (matches README quick-start numbers) —
#                    slower, closer to a real incident's shape.
#   --only 06,07    Only run these drill/detection ids (comma list).
#   --skip 09       Skip these ids (e.g. 09 if DRILL_ROLE isn't configured,
#                    or 11 if PgBouncer isn't in session mode).
#   --with-baseline Also run the diagnostic sweep BEFORE any drill, so you
#                    have a clean-state comparison point.
#   --list          Print the manifest (with resolved args) and exit; runs
#                    nothing. Use this to preview before --yes.
#   --yes / -y      Non-interactive: same meaning as in every drill script,
#                    passed through to each one (or set DRILL_YES=1).
#
# Ids: baseline=01pre, 06,07,09,10,11=drills, 03,04,01=detection
#
# Example — fast, skip the two drills that need extra pre-existing config:
#   ./run_all.sh --skip 09,11 --yes
#
# Example — preview the full-scale manifest without running anything:
#   ./run_all.sh --full --list
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

FAST=1
MODE_LABEL="fast"
WITH_BASELINE=0
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) FAST=0; MODE_LABEL="full" ;;
        --fast) FAST=1; MODE_LABEL="fast" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --with-baseline) WITH_BASELINE=1 ;;
        --list) LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
# support `--only 06,07` (space form) alongside `--only=06,07`
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--only" ]] && ONLY="${arg}"
    [[ "${prev}" == "--skip" ]] && SKIP="${arg}"
    prev="${arg}"
done

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-./run_all_logs/$(date +%Y%m%d_%H%M%S 2>/dev/null || echo run)}"

if [[ "${FAST}" -eq 1 ]]; then
    N06_SESS=10;  N06_HOLD=60
    N07_CONN=100; N07_HOLD=60
    N09_LIM=3;    N09_ATT=10
    N10_CONN=200; N10_HOLD=60
    N11_POOL=10;  N11_HOLD=60
else
    N06_SESS=15;   N06_HOLD=600
    N07_CONN=400;  N07_HOLD=300
    N09_LIM=3;     N09_ATT=10
    N10_CONN=400;  N10_HOLD=900
    N11_POOL=15;   N11_HOLD=300
fi

echo "=== Connection Exhaustion — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

if [[ "${WITH_BASELINE}" -eq 1 ]]; then
    psql_always_step "01pre" "Baseline diagnostic sweep (before drills)" -f 01_diagnostic_queries.sql
fi

bg_step "06" "Idle-in-transaction blocker"        ./06_simulate_idle_in_transaction.sh "${N06_SESS}" "${N06_HOLD}" "" "${YES_FLAG[@]}"
bg_step "07" "PgBouncer transaction-pool saturation" ./07_simulate_pool_saturation.sh "${N07_CONN}" "${N07_HOLD}" "${YES_FLAG[@]}"
bg_step "09" "Role connection-limit breach"       ./09_simulate_role_limit_breach.sh "${N09_LIM}" "${N09_ATT}" "${YES_FLAG[@]}"
bg_step "10" "Idle connection storm / leak"       ./10_simulate_idle_connection_storm.sh "${N10_CONN}" "${N10_HOLD}" "${YES_FLAG[@]}"
bg_step "11" "PgBouncer session-pool pinning"     ./11_simulate_pgbouncer_session_pool_pinning.sh "${N11_POOL}" "${N11_HOLD}" "${YES_FLAG[@]}"
wait_bg_steps

always_step "03" "PgBouncer pool health check"        ./03_pgbouncer_health_check.sh
always_step "04" "RDS connection saturation monitor"  ./04_rds_connection_monitor.sh
psql_always_step "01" "Diagnostic sweep (after drills)" -f 01_diagnostic_queries.sql

echo ""
echo "No cleanup step: drill sessions are left to expire on their own so hunters"
echo "have a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
