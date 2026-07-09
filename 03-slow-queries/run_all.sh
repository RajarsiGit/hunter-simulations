#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Slow Queries: automated end-to-end drill run
# SysCloud DAL Team
#
# EXTREME MODE: setup seeds ~27M rows across slowq_orders/slowq_customers/
# slowq_json_events, then all 6 drills in this folder (missing index,
# function-wrapped predicate, offset pagination, JSONB CPU spike, stale
# statistics, retry storm) launch CONCURRENTLY against those shared tables to
# stack simultaneous load as hard as possible, then the diagnostic sweep runs
# once every drill has finished. Note: 06 resets slowq_orders' pg_stat
# counters (seq_scan/idx_scan) as part of forcing deterministic staleness —
# if it lands mid-flight of 02's seq_scan burst it can zero out that counter;
# the 200000-iteration burst plus 06's own bulk insert (10M rows) mean this
# rarely erases the signal in practice, but re-run 02 alone with --only 02 if
# you need a clean seq_scan_tables reading.
#
# No fix/remediation or cleanup step, no confirmation gate: every drill
# fires immediately, only demonstrates the problem, and leaves it in place
# (stale stats, missing indexes, etc.) so the hunters have a real window to
# detect them. Every drill guarantees at least a 2400s (40min) observation
# window — comfortably clearing the slow-queries hunter's query_critical
# >=1800s threshold, not just query_slow's >=30s one — and the retry storm
# defaults to 1500 sessions x 300 retries (see 07's own header for the
# max_connections/ulimit caveat at this concurrency).
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a disposable/drill database.
# Setup alone can take several minutes at this scale, and the retry storm +
# concurrent drills can meaningfully load a small non-prod instance — this
# is intentional.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 02,05] [--skip 07]
#                [--list] [--yes]
#
#   --fast        Extreme scale (default) — full manifest still takes several
#                  minutes at this row/session count.
#   --full        Even more extreme still, beyond default scale.
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
    DEEP_OFFSET=9000000; N07_SESS=1500; N07_RETRY=300
else
    DEEP_OFFSET=11000000; N07_SESS=5000; N07_RETRY=500
fi

echo "=== Slow Queries — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup slowq_* tables (~27M rows, no secondary indexes)" -f 01_setup_slow_query_tables.sql

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
