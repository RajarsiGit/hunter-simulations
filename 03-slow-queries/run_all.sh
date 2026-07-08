#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Slow Queries: automated end-to-end drill run
# SysCloud DAL Team
#
# Runs setup, all 6 drills in this folder (missing index, function-wrapped
# predicate, offset pagination, JSONB CPU spike, stale statistics, retry
# storm), the diagnostic sweep, then cleanup — one command instead of
# stepping through scripts 01-09 by hand.
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a disposable/drill database.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 02,05] [--skip 07]
#                [--with-fix] [--no-cleanup] [--list] [--yes]
#
#   --fast        Small offset/session counts (default) — full manifest
#                  finishes in a few minutes (setup itself takes 10-30s).
#   --full        Doc-example scale (matches README quick-start numbers).
#   --only 02,05  Only run these drill/detection ids (comma list).
#   --skip 07     Skip these ids.
#   --with-fix    For the simulate/fix scripts (02,03,05,06), also run `fix`
#                  mode right after `simulate` — shows the before/after
#                  remediation, not just the problem. Off by default (keeps
#                  the run demonstrating "the problem" without also mutating
#                  the schema with new indexes/ANALYZE).
#   --no-cleanup  Leave drill tables/sessions in place after the run.
#   --list        Print the manifest (with resolved args) and exit.
#   --yes / -y    Non-interactive, passed through to each drill (or set
#                  DRILL_YES=1).
#
# Ids: 01=setup, 02-07=drills, 08=diagnostic sweep, 09=cleanup
#
# Example — fast, include the fix/remediation pass:
#   ./run_all.sh --with-fix --yes
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

FAST=1
MODE_LABEL="fast"
WITH_FIX=0
DO_CLEANUP=1
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) FAST=0; MODE_LABEL="full" ;;
        --fast) FAST=1; MODE_LABEL="fast" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --with-fix) WITH_FIX=1 ;;
        --no-cleanup) DO_CLEANUP=0 ;;
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
    DEEP_OFFSET=50000; N07_SESS=10; N07_RETRY=5
else
    DEEP_OFFSET=250000; N07_SESS=30; N07_RETRY=15
fi

echo "=== Slow Queries — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup slowq_* tables (~650k rows, no secondary indexes)" -f 01_setup_slow_query_tables.sql

step "02" "Missing-index seq scan (simulate)"        ./02_simulate_missing_index_scan.sh simulate "${YES_FLAG[@]}"
[[ "${WITH_FIX}" -eq 1 ]] && step "02fix" "Missing-index seq scan (fix)" ./02_simulate_missing_index_scan.sh fix "${YES_FLAG[@]}"

step "03" "Function-wrapped predicate defeats index (simulate)" ./03_simulate_function_wrapped_predicate.sh simulate "${YES_FLAG[@]}"
[[ "${WITH_FIX}" -eq 1 ]] && step "03fix" "Function-wrapped predicate (fix: expression index)" ./03_simulate_function_wrapped_predicate.sh fix "${YES_FLAG[@]}"

step "04" "Deep OFFSET pagination cost growth"       ./04_simulate_offset_pagination.sh "${DEEP_OFFSET}"

step "05" "JSONB field extraction CPU spike (simulate)" ./05_simulate_json_processing_spike.sh simulate "${YES_FLAG[@]}"
[[ "${WITH_FIX}" -eq 1 ]] && step "05fix" "JSONB CPU spike (fix: expression index)" ./05_simulate_json_processing_spike.sh fix "${YES_FLAG[@]}"

step "06" "Stale planner statistics bad estimate (simulate)" ./06_simulate_stale_statistics.sh simulate "${YES_FLAG[@]}"
[[ "${WITH_FIX}" -eq 1 ]] && step "06fix" "Stale statistics (fix: ANALYZE)" ./06_simulate_stale_statistics.sh fix "${YES_FLAG[@]}"

step "07" "Application retry storm"                  ./07_simulate_retry_storm.sh "${N07_SESS}" "${N07_RETRY}" "${YES_FLAG[@]}"

psql_always_step "08" "Diagnostic sweep (active queries, pg_stat_statements, missing-index/stale-stats candidates)" -f 08_diagnostic_query_sweep.sql

if [[ "${DO_CLEANUP}" -eq 1 ]]; then
    psql_always_step "09" "Cleanup (drop slowq_* tables + drill sessions)" -f 09_cleanup_slow_query_drill.sql
else
    echo ""
    echo "⚠️  --no-cleanup: slowq_* tables and any drill sessions left in place. Clean up later with:"
    echo "    psql -h \"\$PGHOST\" -p \"\$PGPORT\" -U \"\$PGUSER\" -d \"\$PGDATABASE\" -f 09_cleanup_slow_query_drill.sql"
fi

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
