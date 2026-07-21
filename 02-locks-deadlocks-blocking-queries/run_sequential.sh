#!/usr/bin/env bash
# =============================================================================
# run_sequential.sh — Locks, Deadlocks & Blocking Queries: one-drill-at-a-time run
# SysCloud DAL Team
#
# Counterpart to run_all.sh's concurrent "FAST MODE": runs the same 15 drills
# (02-08, 11-18) ONE AT A TIME, in order, against the shared lock_test_*
# tables, instead of stacking them all simultaneously. Useful when you want
# each drill's signature individually observable by a hunter rather than
# piled on top of the others.
#
# Each drill blocks until it finishes (every drill script already `wait`s
# internally, and pads itself to at least a ~12s floor via ensure_min_duration
# in _lib/env.sh), then this script stops and waits for YOU to press Enter
# before launching the next drill — a manual confirmation gate instead of a
# timed pause, so you can check the hunter/dashboard between drills before
# moving on. Setup (01) always runs first; triage (09) + automated RCA (20)
# run once, after every drill has finished — same as run_all.sh.
#
# No mitigation/cleanup step: drills fire immediately (no confirmation gate
# inside the drill scripts themselves) and drill sessions/tables are left in
# place. The manual gate below is this script's own between-drills pacing,
# separate from each drill's internal behavior.
#
# CEILING WARNING: SysCloud baseline session settings (runbook §7.3) are
# deadlock_timeout=15s, lock_timeout=10s, idle_in_transaction_session_timeout=60s,
# statement_timeout=5min. Every drill script in this folder still explicitly
# disables the relevant ones for its own sessions so hold_seconds isn't cut
# even shorter by the server's own baseline timeouts.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_sequential.sh [--hold N] [--only 02,03] [--skip 16]
#                        [--list] [--yes]
#
#   --hold N        Seconds most drills hold their sessions open (default 20)
#                    — applies to 02/04/06/11/12/13/16/17. NOTE: actions/
#                    locks-deadlocks-blocking-queries.jsonc's poller runs
#                    every 300s, so 20s is NOT guaranteed reliable hunter
#                    detection on its own — bump this (e.g. 900, matching
#                    each drill script's own suggested override — ~3 poll
#                    ticks of margin) if you need reliable coverage. 05/15/18
#                    (DDL-blocks-DML drills) use a separate, smaller DML_HOLD
#                    (fixed at 15s, not driven by this flag, to keep the DDL
#                    queue window short relative to its waiters). 03/07/08/14
#                    have no hold_seconds argument at all — their timing is
#                    fixed internally (deadlock/lock-mode scripts pad to a
#                    12s floor via ensure_min_duration instead).
#   --only 03,07    Only run these drill ids (comma list).
#   --skip 16       Skip these ids (16 overlaps topic 01's connection-
#                    exhaustion drills — skip it here if running both topics
#                    back to back).
#   --list          Print the manifest (with resolved args) and exit; runs
#                    nothing. Use this to preview before --yes.
#   --yes / -y      Non-interactive: same meaning as in every drill script,
#                    passed through to each one (or set DRILL_YES=1). Does
#                    NOT skip the manual Enter-to-continue gate between
#                    drills — that gate is the point of this script.
#
# Ids: 01=setup, 02-08/11-18=drills, 09=triage, 20=RCA
#
# Example — defaults (20s hold, manual gate between drills), skip the
# connection-exhaustion overlap drill:
#   ./run_sequential.sh --skip 16 --yes
#
# Example — longer hold for reliable hunter detection:
#   ./run_sequential.sh --hold 900 --yes
#
# Example — preview the manifest without running anything:
#   ./run_sequential.sh --list
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../_lib/env.sh"
source "../_lib/runner.sh"

HOLD=20
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --hold=*) HOLD="${arg#--hold=}" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --skip=*) SKIP="${arg#--skip=}" ;;
        --list) LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
# support `--hold 900` / `--only 02,03` (space form) alongside `--flag=value`
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--hold" ]] && HOLD="${arg}"
    [[ "${prev}" == "--only" ]] && ONLY="${arg}"
    [[ "${prev}" == "--skip" ]] && SKIP="${arg}"
    prev="${arg}"
done

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-./run_all_logs/$(date +%Y%m%d_%H%M%S 2>/dev/null || echo run)}"

DML_HOLD=15
CONN_COUNT_16=20
LQA_WAITERS=12
IDLE_BLOCKERS=5

echo "=== Locks, Deadlocks & Blocking Queries — run_sequential.sh ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Hold per drill: ${HOLD}s (DML-blocking drills: ${DML_HOLD}s) | Manual confirmation gate between drills"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup lock-drill tables" -f 01_setup_lock_drill_tables.sql

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

step "02" "Row-lock blocking (idle-in-txn holder)"     ./02_simulate_row_lock_blocking.sh 1 "${HOLD}" "${YES_FLAG[@]}"
should_run "02" && confirm_step
step "03" "Classic 2-session deadlock"                 ./03_simulate_deadlock.sh 1 2 "${YES_FLAG[@]}"
should_run "03" && confirm_step
step "04" "LOCK TABLE AccessExclusiveLock"              ./04_simulate_table_access_exclusive.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "04" && confirm_step
step "05" "DDL (CREATE INDEX) blocks DML cascade"       ./05_simulate_ddl_blocking_dml.sh "${DML_HOLD}" "${YES_FLAG[@]}"
should_run "05" && confirm_step
step "06" "Advisory lock blocking"                      ./06_simulate_advisory_lock.sh 42 "${HOLD}" "${YES_FLAG[@]}"
should_run "06" && confirm_step
step "07" "Credits multi-module deadlock (buggy)"       ./07_simulate_credits_deadlock.sh buggy "${YES_FLAG[@]}"
should_run "07" && confirm_step
step "08" "MVW REFRESH blocking lock"                   ./08_simulate_mvw_refresh_lock.sh blocking no "${YES_FLAG[@]}"
should_run "08" && confirm_step
step "11" "Idle-in-transaction indefinite blocker"      ./11_simulate_idle_in_transaction.sh 3 "${HOLD}" "${IDLE_BLOCKERS}" "${YES_FLAG[@]}"
should_run "11" && confirm_step
step "12" "Long transaction blocks vacuum (dead tuples)" ./12_simulate_long_txn_vacuum_bloat.sh "${HOLD}" "${YES_FLAG[@]}"
should_run "12" && confirm_step
step "13" "FK contention (child_blocks_parent)"         ./13_simulate_fk_contention.sh child_blocks_parent "${HOLD}" "${YES_FLAG[@]}"
should_run "13" && confirm_step
step "14" "VACUUM FULL AccessExclusiveLock"              ./14_simulate_vacuum_full_blocking.sh vacuum_full_blocks_dml "${YES_FLAG[@]}"
should_run "14" && confirm_step
step "15" "Non-concurrent CREATE INDEX blocks DML"      ./15_simulate_index_blocking.sh "${DML_HOLD}" "${YES_FLAG[@]}"
should_run "15" && confirm_step
step "16" "Connection exhaustion (idle flood, in-folder demo)" ./16_simulate_connection_exhaustion.sh idle_connection_flood "${CONN_COUNT_16}" "${HOLD}" "${YES_FLAG[@]}"
should_run "16" && confirm_step
step "17" "Stuck worker workflow blockage"              ./17_simulate_workflow_blockage.sh stuck_worker "${HOLD}" "${YES_FLAG[@]}"
should_run "17" && confirm_step
step "18" "Lock queue amplification (A→B→${LQA_WAITERS} waiters)" ./18_simulate_lock_queue_amplification.sh "${DML_HOLD}" "${LQA_WAITERS}" "${YES_FLAG[@]}"

psql_always_step "09" "Lock triage sweep (blocking tree, chains, deadlocks)" -f 09_lock_triage_queries.sql
always_step "20" "Automated incident RCA (read-only)"   ./20_lock_incident_rca.sh

echo ""
echo "No cleanup step: drill sessions/tables are left in place so hunters have"
echo "a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
