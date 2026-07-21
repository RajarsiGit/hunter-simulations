#!/usr/bin/env bash
# =============================================================================
# run_sequential.sh — Connection Exhaustion: one-drill-at-a-time drill run
# SysCloud DAL Team
#
# Counterpart to run_all.sh's concurrent "EXTREME MODE": runs the same five
# drills (idle-in-transaction, PgBouncer pool saturation, role-limit breach,
# idle-connection storm, PgBouncer session-pool pinning) ONE AT A TIME, in
# order, pausing between each instead of stacking them all simultaneously.
# Useful when you want each drill's signature individually observable by a
# hunter rather than piled on top of the others.
#
# Each drill blocks until its own hold duration elapses (every drill script
# already `wait`s internally for its sessions to self-expire), then this
# script stops and waits for YOU to press Enter before launching the next
# drill — a manual confirmation gate instead of a timed pause, so you can
# check the hunter/dashboard between drills before moving on. Detection
# (03/04/01) runs once, after every drill has finished — same as run_all.sh.
#
# No mitigation/cleanup step: drills fire immediately (no confirmation gate
# inside the drill scripts themselves) and drill sessions are left running/
# expiring on their own. The manual gate below is this script's own
# between-drills pacing, separate from each drill's internal behavior.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_sequential.sh [--hold N] [--only 06,07] [--skip 09,11]
#                        [--with-baseline] [--list] [--yes]
#
#   --hold N        Seconds each drill holds its sessions open (default 20).
#                    NOTE: actions/connection-exhaustion.jsonc's poller runs
#                    every 300s, so 20s is NOT guaranteed reliable hunter
#                    detection on its own — bump this (e.g. 300+) if you
#                    need multi-poll-tick coverage. 09's hold is fixed at 60s
#                    inside that script (not driven by this flag) since its
#                    signature is a role-limit breach, not a timed hold. 06
#                    (idle-in-transaction) opens 240 sessions (N06_SESS
#                    below) — larger than the other drills' 100/200 — since
#                    that's the scale requested for this manifest.
#   --only 06,07    Only run these drill ids (comma list).
#   --skip 09       Skip these ids (e.g. 09 if DRILL_ROLE isn't configured,
#                    or 11 if PgBouncer isn't in session mode).
#   --with-baseline Also run the diagnostic sweep BEFORE any drill, so you
#                    have a clean-state comparison point.
#   --list          Print the manifest (with resolved args) and exit; runs
#                    nothing. Use this to preview before --yes.
#   --yes / -y      Non-interactive: same meaning as in every drill script,
#                    passed through to each one (or set DRILL_YES=1). Does
#                    NOT skip the manual Enter-to-continue gate between
#                    drills — that gate is the point of this script.
#
# Ids: baseline=01pre, 06,07,09,10,11=drills, 03,04,01=detection
#
# Example — defaults (20s hold, manual gate between drills), skip drills
# needing extra config:
#   ./run_sequential.sh --skip 09,11 --yes
#
# Example — longer hold for reliable hunter detection:
#   ./run_sequential.sh --hold 300 --yes
#
# Example — preview the manifest without running anything:
#   ./run_sequential.sh --list
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

HOLD=20
WITH_BASELINE=0
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --hold=*) HOLD="${arg#--hold=}" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --with-baseline) WITH_BASELINE=1 ;;
        --list) LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
# support `--hold 300` / `--only 06,07` (space form) alongside `--flag=value`
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--hold" ]] && HOLD="${arg}"
    [[ "${prev}" == "--only" ]] && ONLY="${arg}"
    [[ "${prev}" == "--skip" ]] && SKIP="${arg}"
    prev="${arg}"
done

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-./run_all_logs/$(date +%Y%m%d_%H%M%S 2>/dev/null || echo run)}"

N06_SESS=180
N07_CONN=200
N09_LIM=8;  N09_ATT=15
N10_CONN=200
N11_POOL=10

echo "=== Connection Exhaustion — run_sequential.sh ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Hold per drill: ${HOLD}s | Manual confirmation gate between drills"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

if [[ "${WITH_BASELINE}" -eq 1 ]]; then
    psql_always_step "01pre" "Baseline diagnostic sweep (before drills)" -f 01_diagnostic_queries.sql
fi

# confirm_step — blocks on a manual Enter before the next drill; only called
# after a drill that actually ran (should_run guard at each call site), so a
# run narrowed by --only/--skip doesn't prompt around skipped ids.
confirm_step() {
    if [[ "${LIST_ONLY}" -eq 1 ]]; then
        echo "         ... manual gate: press Enter to continue to next drill ..."
        return 0
    fi
    echo ""
    read -r -p "--- Drill finished. Press Enter to continue to the next drill (Ctrl+C to stop here) --- " _
}

step "06" "Idle-in-transaction blocker"        ./06_simulate_idle_in_transaction.sh "${N06_SESS}" "${HOLD}" "" "${YES_FLAG[@]}"
should_run "06" && confirm_step
step "07" "PgBouncer transaction-pool saturation" ./07_simulate_pool_saturation.sh "${N07_CONN}" "${HOLD}" "${YES_FLAG[@]}"
should_run "07" && confirm_step
step "09" "Role connection-limit breach"       ./09_simulate_role_limit_breach.sh "${N09_LIM}" "${N09_ATT}" "${YES_FLAG[@]}"
should_run "09" && confirm_step
step "10" "Idle connection storm / leak"       ./10_simulate_idle_connection_storm.sh "${N10_CONN}" "${HOLD}" "${YES_FLAG[@]}"
should_run "10" && confirm_step
step "11" "PgBouncer session-pool pinning"     ./11_simulate_pgbouncer_session_pool_pinning.sh "${N11_POOL}" "${HOLD}" "${YES_FLAG[@]}"

always_step "03" "PgBouncer pool health check"        ./03_pgbouncer_health_check.sh
always_step "04" "RDS connection saturation monitor"  ./04_rds_connection_monitor.sh
psql_always_step "01" "Diagnostic sweep (after drills)" -f 01_diagnostic_queries.sql

echo ""
echo "No cleanup step: drill sessions are left to expire on their own so hunters"
echo "have a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
