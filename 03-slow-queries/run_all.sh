#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Slow Queries: automated end-to-end drill run
# SysCloud DAL Team
#
# FAST MODE: setup seeds ~550k rows across slowq_orders/slowq_customers/
# slowq_json_events, then all 6 drills in this folder (missing index,
# function-wrapped predicate, offset pagination, JSONB CPU spike, stale
# statistics, retry storm) launch CONCURRENTLY against those shared tables to
# stack simultaneous load, then the diagnostic sweep runs once every drill
# has finished. Note: 06 resets slowq_orders' pg_stat counters (seq_scan/
# idx_scan) as part of forcing deterministic staleness — if it lands
# mid-flight of 02's seq_scan burst it can zero out that counter; re-run 02
# alone with --only 02 if you need a clean seq_scan_tables reading.
#
# No fix/remediation or cleanup step, no confirmation gate: every drill
# fires immediately, only demonstrates the problem, and leaves it in place
# (stale stats, missing indexes, etc.) so the hunters have a window to
# detect them. Every drill is sized to finish in <=20s by default (row
# counts, hold durations and seq-scan burst counts are all trimmed for a
# quick local drill run) — this intentionally trades away the wide
# multi-minute hunter-poll observation window a much larger/longer-held
# drill would give; not tuned for live hunter-detection reliability.
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a disposable/drill database.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 02,05] [--skip 07]
#                [--list] [--yes]
#
#   --fast        Default scale — full manifest finishes in well under a
#                  minute.
#   --full        A heavier scale (still bounded), for a more substantial
#                  manual/CI stress run.
#   --only 02,05  Only run these drill/detection ids (comma list).
#   --skip 07     Skip these ids.
#   --list        Print the manifest (with resolved args) and exit.
#   --yes / -y    Non-interactive, passed through to each drill (or set
#                  DRILL_YES=1).
#
# Ids: 01=setup, 02-07=drills, 08=diagnostic sweep
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

FAST=1
MODE_LABEL="fast"
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) FAST=0; MODE_LABEL="full" ;;
        --fast) FAST=1; MODE_LABEL="fast" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --list) LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
prev=""
for arg in "$@"; do
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

echo "=== Slow Queries — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup slowq_* tables (~550k rows, no secondary indexes)" -f 01_setup_slow_query_tables.sql

bg_step "02" "Missing-index seq scan"                   ./02_simulate_missing_index_scan.sh "${YES_FLAG[@]}"
bg_step "03" "Function-wrapped predicate defeats index" ./03_simulate_function_wrapped_predicate.sh "${YES_FLAG[@]}"
bg_step "04" "Deep OFFSET pagination cost growth"       ./04_simulate_offset_pagination.sh "${DEEP_OFFSET}"
bg_step "05" "JSONB field extraction CPU spike"         ./05_simulate_json_processing_spike.sh "${YES_FLAG[@]}"
bg_step "06" "Stale planner statistics bad estimate"    ./06_simulate_stale_statistics.sh "${YES_FLAG[@]}"
bg_step "07" "Application retry storm"                  ./07_simulate_retry_storm.sh "${N07_SESS}" "${N07_RETRY}" "${YES_FLAG[@]}"
wait_bg_steps

psql_always_step "08" "Diagnostic sweep (active queries, pg_stat_statements, missing-index/stale-stats candidates)" -f 08_diagnostic_query_sweep.sql

echo ""
echo "No cleanup step: slowq_* tables and any drill sessions are left in place"
echo "so hunters have a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
