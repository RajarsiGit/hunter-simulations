#!/usr/bin/env bash
# =============================================================================
# run_sequential.sh — Slow Queries: one-drill-at-a-time drill run
# SysCloud DAL Team
#
# Counterpart to run_all.sh's concurrent "FAST MODE": runs the same 6 drills
# (missing index, function-wrapped predicate, offset pagination, JSONB CPU
# spike, stale statistics, retry storm) ONE AT A TIME, in order, against the
# shared slowq_* tables, instead of stacking them all simultaneously. Useful
# when you want each drill's signature individually observable by a hunter
# rather than piled on top of the others.
#
# Each drill blocks until it finishes, then this script stops and waits for
# YOU to press Enter before launching the next drill — a manual confirmation
# gate instead of a timed pause, so you can check the hunter/dashboard
# between drills before moving on. Setup (01) always runs first; the
# diagnostic sweep (08) runs once, after every drill has finished — same as
# run_all.sh.
#
# No fix/remediation or cleanup step: every drill fires immediately, only
# demonstrates the problem, and leaves it in place (stale stats, missing
# indexes, etc.) so hunters have a window to detect them. NOTE: 06 resets
# slowq_orders' pg_stat counters (seq_scan/idx_scan) as part of forcing
# deterministic staleness — running it right after 02 zeroes out 02's
# seq_scan burst; re-run 02 alone with --only 02 if you need a clean
# seq_scan_tables reading after a full sequential pass.
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a disposable/drill database.
#
# Usage:
#   ./run_sequential.sh [--fast|--full] [--hold N] [--only 02,05] [--skip 07]
#                        [--list] [--yes]
#
#   --fast        Default scale — each drill finishes in well under 20s.
#   --full        A heavier scale (still bounded), for a more substantial
#                  manual/CI stress run.
#   --hold N      Seconds each drill holds its session active (02/03/04/05,
#                  via hold_session_active) or pads its total wall time
#                  (06/07, via ensure_min_duration) — default 10. NOTE: the
#                  slow-queries hunter's poller runs every 300s and
#                  query_slow needs >=30s, so 10s is NOT guaranteed reliable
#                  hunter detection on its own — bump this (e.g. 60+) if you
#                  need a wider observation window.
#   --only 02,05  Only run these drill ids (comma list).
#   --skip 07     Skip these ids.
#   --list        Print the manifest (with resolved args) and exit; runs
#                  nothing. Use this to preview before --yes.
#   --yes / -y    Non-interactive: same meaning as in every drill script,
#                  passed through to each one (or set DRILL_YES=1). Does NOT
#                  skip the manual Enter-to-continue gate between drills —
#                  that gate is the point of this script.
#
# Ids: 01=setup, 02-07=drills, 08=diagnostic sweep
#
# Example — defaults, skip the retry-storm drill:
#   ./run_sequential.sh --skip 07 --yes
#
# Example — hold each drill's session open for 60s:
#   ./run_sequential.sh --hold 60 --yes
#
# Example — preview the manifest without running anything:
#   ./run_sequential.sh --list
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

FAST=1
MODE_LABEL="fast"
HOLD=10
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) FAST=0; MODE_LABEL="full" ;;
        --fast) FAST=1; MODE_LABEL="fast" ;;
        --hold=*) HOLD="${arg#--hold=}" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --list) LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--hold" ]] && HOLD="${arg}"
    [[ "${prev}" == "--only" ]] && ONLY="${arg}"
    [[ "${prev}" == "--skip" ]] && SKIP="${arg}"
    prev="${arg}"
done

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-./run_all_logs/$(date +%Y%m%d_%H%M%S 2>/dev/null || echo run)}"

if [[ "${FAST}" -eq 1 ]]; then
    DEEP_OFFSET=100000; N07_SESS=15; N07_RETRY=5
else
    DEEP_OFFSET=150000; N07_SESS=30; N07_RETRY=10
fi

echo "=== Slow Queries — run_sequential.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Hold per drill: ${HOLD}s | Manual confirmation gate between drills"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup slowq_* tables (~550k rows, no secondary indexes)" -f 01_setup_slow_query_tables.sql

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

step "02" "Missing-index seq scan"                   ./02_simulate_missing_index_scan.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "02" && confirm_step
step "03" "Function-wrapped predicate defeats index" ./03_simulate_function_wrapped_predicate.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "03" && confirm_step
step "04" "Deep OFFSET pagination cost growth"       ./04_simulate_offset_pagination.sh "${DEEP_OFFSET}" "${HOLD}"
should_run "04" && confirm_step
step "05" "JSONB field extraction CPU spike"         ./05_simulate_json_processing_spike.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "05" && confirm_step
step "06" "Stale planner statistics bad estimate"    ./06_simulate_stale_statistics.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "06" && confirm_step
step "07" "Application retry storm"                  ./07_simulate_retry_storm.sh "${N07_SESS}" "${N07_RETRY}" "${HOLD}" "${YES_FLAG[@]}"

psql_always_step "08" "Diagnostic sweep (active queries, pg_stat_statements, missing-index/stale-stats candidates)" -f 08_diagnostic_query_sweep.sql

echo ""
echo "No cleanup step: slowq_* tables and any drill sessions are left in place"
echo "so hunters have a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
