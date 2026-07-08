#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Locks, Deadlocks & Blocking Queries: automated end-to-end run
# SysCloud DAL Team
#
# Runs setup, all 15 drills in this folder, the triage sweep + automated RCA,
# then full cleanup — one command instead of stepping through scripts 01-20
# by hand. Individual scripts remain the source of truth; this just sequences
# them with sane defaults and a pass/fail summary.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 03,07] [--skip 16]
#                [--no-cleanup] [--list] [--yes]
#
#   --fast        Small hold durations (default) — every drill still gets a
#                  30s minimum observation window (see ensure_min_duration in
#                  _lib/env.sh); full manifest finishes in a few minutes.
#   --full        Doc-example scale (matches README quick-start numbers).
#   --only 03,07  Only run these drill/detection ids (comma list).
#   --skip 16     Skip these ids (16 overlaps topic 01's connection-exhaustion
#                  drills — skip it here if you're running both topics back
#                  to back via the top-level simulations/run_all.sh).
#   --no-cleanup  Leave drill sessions/tables in place after the run.
#   --list        Print the manifest (with resolved args) and exit.
#   --yes / -y    Non-interactive, passed through to each drill (or set
#                  DRILL_YES=1).
#
# Ids: 01=setup, 02-08/11-18=drills, 09=triage, 20=RCA, 10=full cleanup
#
# Example — fast, skip the connection-exhaustion overlap drill:
#   ./run_all.sh --skip 16 --yes
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

FAST=1
MODE_LABEL="fast"
DO_CLEANUP=1
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) FAST=0; MODE_LABEL="full" ;;
        --fast) FAST=1; MODE_LABEL="fast" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
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
    HOLD=30; DML_HOLD=30; CONN_COUNT_16=20
else
    HOLD=60; DML_HOLD=30; CONN_COUNT_16=100
fi

echo "=== Locks, Deadlocks & Blocking Queries — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup lock-drill tables" -f 01_setup_lock_drill_tables.sql

step "02" "Row-lock blocking (idle-in-txn holder)"     ./02_simulate_row_lock_blocking.sh 1 "${HOLD}" "${YES_FLAG[@]}"
step "03" "Classic 2-session deadlock"                 ./03_simulate_deadlock.sh 1 2 "${YES_FLAG[@]}"
step "04" "LOCK TABLE AccessExclusiveLock"              ./04_simulate_table_access_exclusive.sh "${HOLD}" "${YES_FLAG[@]}"
step "05" "DDL (CREATE INDEX) blocks DML cascade"       ./05_simulate_ddl_blocking_dml.sh "${DML_HOLD}" "${YES_FLAG[@]}"
step "06" "Advisory lock blocking"                      ./06_simulate_advisory_lock.sh 42 "${HOLD}" "${YES_FLAG[@]}"
step "07" "Credits multi-module deadlock (buggy)"       ./07_simulate_credits_deadlock.sh buggy "${YES_FLAG[@]}"
step "08" "MVW REFRESH blocking lock"                   ./08_simulate_mvw_refresh_lock.sh blocking no "${YES_FLAG[@]}"
step "11" "Idle-in-transaction indefinite blocker"      ./11_simulate_idle_in_transaction.sh 1 "${HOLD}" "${YES_FLAG[@]}"
step "12" "Long transaction blocks vacuum (dead tuples)" ./12_simulate_long_txn_vacuum_bloat.sh "${HOLD}" "${YES_FLAG[@]}"
step "13" "FK contention (child_blocks_parent)"         ./13_simulate_fk_contention.sh child_blocks_parent "${HOLD}" "${YES_FLAG[@]}"
step "14" "VACUUM FULL AccessExclusiveLock"             ./14_simulate_vacuum_full_blocking.sh vacuum_full_blocks_dml "${YES_FLAG[@]}"
step "15" "Non-concurrent CREATE INDEX blocks DML"      ./15_simulate_index_blocking.sh "${DML_HOLD}" "${YES_FLAG[@]}"
step "16" "Connection exhaustion (idle flood, in-folder demo)" ./16_simulate_connection_exhaustion.sh idle_connection_flood "${CONN_COUNT_16}" "${HOLD}" "${YES_FLAG[@]}"
step "17" "Stuck worker workflow blockage"              ./17_simulate_workflow_blockage.sh stuck_worker "${HOLD}" "${YES_FLAG[@]}"
step "18" "Lock queue amplification (A→B→C→D→E)"        ./18_simulate_lock_queue_amplification.sh "${DML_HOLD}" "${YES_FLAG[@]}"

psql_always_step "09" "Lock triage sweep (blocking tree, chains, deadlocks)" -f 09_lock_triage_queries.sql
always_step "20" "Automated incident RCA (read-only)"   ./20_lock_incident_rca.sh

if [[ "${DO_CLEANUP}" -eq 1 ]]; then
    psql_always_step "10" "Full teardown (drill sessions + lock_test_* objects)" -f 10_cleanup_lock_drill.sql
else
    echo ""
    echo "⚠️  --no-cleanup: drill sessions/tables left in place. Clean up later with:"
    echo "    psql -h \"\$PGHOST\" -p \"\$PGPORT\" -U \"\$PGUSER\" -d \"\$PGDATABASE\" -f 10_cleanup_lock_drill.sql"
fi

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
