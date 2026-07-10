#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Locks, Deadlocks & Blocking Queries: automated end-to-end run
# SysCloud DAL Team
#
# FAST MODE: setup runs once, then all 15 drills in this folder launch
# CONCURRENTLY (not one at a time) against the shared lock_test_* tables to
# stack simultaneous lock contention/deadlocks and stress the target briefly,
# then the triage sweep + automated RCA run once every drill has finished.
# Individual scripts remain the source of truth; this just launches them
# with fast-by-default sizing and a pass/fail summary.
#
# No mitigation/cleanup step, no confirmation gate: drills fire immediately
# and drill sessions/tables are left in place so they can be inspected
# afterward. Every drill now defaults to a short hold (~6-8s) so the whole
# manifest completes in well under 20s per drill — this is NOT sized to clear
# the hunter's 300s poll interval (actions/locks-deadlocks-blocking-queries.jsonc)
# any more; see ensure_min_duration in _lib/env.sh for the floor mechanism
# (now capped at 12s here) and each script's own header for what value to
# pass instead if you need reliable hunter-detection timing.
#
# CEILING WARNING: SysCloud baseline session settings (runbook §7.3) are
# deadlock_timeout=15s, lock_timeout=10s, idle_in_transaction_session_timeout=60s,
# statement_timeout=5min. Every drill script in this folder still explicitly
# disables the relevant ones for its own sessions (holders: statement_timeout +
# idle_in_transaction_session_timeout; waiters: statement_timeout + lock_timeout;
# deadlock scripts additionally SET deadlock_timeout='2s') so the short holds
# above aren't cut even shorter by the server's own baseline timeouts.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 03,07] [--skip 16]
#                [--list] [--yes]
#
#   --fast        Fast scale (default) — every drill holds ~6-8s; full
#                  manifest finishes in well under 20s per drill since drills
#                  run concurrently, not sequentially.
#   --full        Slightly larger fan-out (more waiters/connections/blockers)
#                  but still capped to the same short holds.
#   --only 03,07  Only run these drill/detection ids (comma list).
#   --skip 16     Skip these ids (16 overlaps topic 01's connection-exhaustion
#                  drills — skip it here if you're running both topics back
#                  to back via the top-level simulations/run_all.sh).
#   --list        Print the manifest (with resolved args) and exit.
#   --yes / -y    Non-interactive, passed through to each drill (or set
#                  DRILL_YES=1).
#
# Ids: 01=setup, 02-08/11-18=drills, 09=triage, 20=RCA
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
    HOLD=8; DML_HOLD=6; CONN_COUNT_16=20; LQA_WAITERS=12; IDLE_BLOCKERS=5
else
    HOLD=10; DML_HOLD=8; CONN_COUNT_16=40; LQA_WAITERS=20; IDLE_BLOCKERS=8
fi

echo "=== Locks, Deadlocks & Blocking Queries — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup lock-drill tables" -f 01_setup_lock_drill_tables.sql

bg_step "02" "Row-lock blocking (idle-in-txn holder)"     ./02_simulate_row_lock_blocking.sh 1 "${HOLD}" "${YES_FLAG[@]}"
bg_step "03" "Classic 2-session deadlock"                 ./03_simulate_deadlock.sh 1 2 "${YES_FLAG[@]}"
bg_step "04" "LOCK TABLE AccessExclusiveLock"              ./04_simulate_table_access_exclusive.sh "${HOLD}" "${YES_FLAG[@]}"
bg_step "05" "DDL (CREATE INDEX) blocks DML cascade"       ./05_simulate_ddl_blocking_dml.sh "${DML_HOLD}" "${YES_FLAG[@]}"
bg_step "06" "Advisory lock blocking"                      ./06_simulate_advisory_lock.sh 42 "${HOLD}" "${YES_FLAG[@]}"
bg_step "07" "Credits multi-module deadlock (buggy)"       ./07_simulate_credits_deadlock.sh buggy "${YES_FLAG[@]}"
bg_step "08" "MVW REFRESH blocking lock"                   ./08_simulate_mvw_refresh_lock.sh blocking no "${YES_FLAG[@]}"
bg_step "11" "Idle-in-transaction indefinite blocker"      ./11_simulate_idle_in_transaction.sh 3 "${HOLD}" "${IDLE_BLOCKERS}" "${YES_FLAG[@]}"
bg_step "12" "Long transaction blocks vacuum (dead tuples)" ./12_simulate_long_txn_vacuum_bloat.sh "${HOLD}" "${YES_FLAG[@]}"
bg_step "13" "FK contention (child_blocks_parent)"         ./13_simulate_fk_contention.sh child_blocks_parent "${HOLD}" "${YES_FLAG[@]}"
bg_step "14" "VACUUM FULL AccessExclusiveLock"             ./14_simulate_vacuum_full_blocking.sh vacuum_full_blocks_dml "${YES_FLAG[@]}"
bg_step "15" "Non-concurrent CREATE INDEX blocks DML"      ./15_simulate_index_blocking.sh "${DML_HOLD}" "${YES_FLAG[@]}"
bg_step "16" "Connection exhaustion (idle flood, in-folder demo)" ./16_simulate_connection_exhaustion.sh idle_connection_flood "${CONN_COUNT_16}" "${HOLD}" "${YES_FLAG[@]}"
bg_step "17" "Stuck worker workflow blockage"              ./17_simulate_workflow_blockage.sh stuck_worker "${HOLD}" "${YES_FLAG[@]}"
bg_step "18" "Lock queue amplification (A→B→${LQA_WAITERS} waiters)" ./18_simulate_lock_queue_amplification.sh "${DML_HOLD}" "${LQA_WAITERS}" "${YES_FLAG[@]}"
wait_bg_steps

psql_always_step "09" "Lock triage sweep (blocking tree, chains, deadlocks)" -f 09_lock_triage_queries.sql
always_step "20" "Automated incident RCA (read-only)"   ./20_lock_incident_rca.sh

echo ""
echo "No cleanup step: drill sessions/tables are left in place so hunters have"
echo "a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
