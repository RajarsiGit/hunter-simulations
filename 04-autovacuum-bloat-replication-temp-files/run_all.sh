#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Autovacuum / Bloat / Replication / Temp Files: automated
# end-to-end drill run
# SysCloud DAL Team
#
# FAST MODE (default): setup runs once, then all 9 drills in this folder
# (table/index bloat, autovacuum worker starvation, stale-stats bad plan,
# temp-file spill x3 modes, CREATE INDEX temp spike, replication-slot WAL
# retention, replica-lag write surge) launch CONCURRENTLY to stack
# simultaneous IO/CPU load, then the diagnostic sweep runs once every drill
# has finished. Row counts are sized so each individual drill finishes in
# well under 20s by default — pass larger row_count args to individual
# scripts (or edit the N0X_ROWS values below) if you need wider margin above
# a threshold and can accept a longer run.
#
# Real thresholds this manifest is sized against (see each script's own
# header for the exact query file each was verified against). At the ≤20s
# --fast row counts above, the WARNING-tier floors are still reliably
# cleared; the CRITICAL-tier floors marked (*) below are NOT reliably
# cleared anymore — that headroom was traded away for the 20s cap:
#   T-3/T-4 (slow-queries.jsonc)  table dead_tup_ratio > 0.60 crit / 0.30 warn
#   AV-1/AV-2 (slow-queries.jsonc) autovacuum_enabled=false (+ dead>0.20 for AV-2)
#   ST-1/ST-2 (slow-queries.jsonc) never/>7day-stale ANALYZE, n_live_tup>100k
#   TF-1/TF-2(*) (this topic's own hunter) temp spill >=1 GiB/h warn / >=25 GiB/h crit
#   RS-1/RS-2(*) (slow-queries.jsonc) inactive slot retaining >=1 GiB/>=10 GiB WAL
#   R-1/R-2   (slow-queries.jsonc) replica replay lag >=100 MiB/>=1 GiB — 10's
#             drill CANNOT trip this without a real replica attached (REPLICA_PGHOST)
#
# Before firing the temp-spill drills (07-sort/07-hash/07-group/08), this
# script resets ${PGDATABASE}'s stats ONCE and exports SKIP_STATS_RESET=1 so
# the sub-scripts skip their own individual resets — their concurrent
# contributions to pg_stat_database.temp_bytes STACK instead of each wiping
# what its siblings already spilled, which is the only realistic way to
# threaten TF-2's 25 GiB/h critical floor without any single mode alone
# needing to spill that much (see 07's header for the full 1h-floor-since-
# reset mechanic this exploits).
#
# No fix/remediation or cleanup step, no confirmation gate: every drill
# fires immediately and leaves its condition in place (bloat un-vacuumed,
# indexes un-reindexed, statistics stale, the replication slot un-dropped),
# so the hunters have a window to detect them.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
# CAVEAT — disk space: even at these reduced row counts, 09's replication
# slot retains WAL indefinitely once created — check FreeStorageSpace/
# TransactionLogsDiskUsage headroom and drop the slot when done (see 09's
# own remediation output).
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 04,09] [--skip 07-sort]
#                [--list] [--yes]
#
#   --fast    Default — each drill finishes in well under 20s.
#   --full    ~2x the row counts of --fast — still sized to stay under 20s
#              per drill, just with wider threshold margin.
#   --only id Only run these ids (comma list) — see id list below.
#   --skip id Skip these ids.
#   --list    Print the manifest (with resolved args) and exit.
#   --yes/-y  Non-interactive, passed through to each drill (or set
#              DRILL_YES=1).
#
# Ids: 01=setup, 03-06/08-10=drills, 07-sort/07-hash/07-group=temp-spill
#      drill (3 sub-modes, separate ids), 02=diagnostic sweep
#
# Example — fast, skip the two temp-spill sub-modes that take longest:
#   ./run_all.sh --skip 07-hash,07-group --yes
#
# Example — full-scale replica-lag drill against a real read replica:
#   REPLICA_PGHOST=<replica-endpoint> ./run_all.sh --full --only 10 --yes
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
    N03_ROWS=100000; N03_CHURN=30
    N04_ROWS=100000
    N05_TABLES=5;    N05_ROWS=100000
    N06_ROWS=150000
    N07_SORT=600000; N07_HASH=300000; N07_GROUP=600000
    N08_ROWS=600000
    N09_ROWS=500000
    N10_ROWS=100000
else
    N03_ROWS=200000; N03_CHURN=50
    N04_ROWS=200000
    N05_TABLES=8;     N05_ROWS=200000
    N06_ROWS=300000
    N07_SORT=1200000; N07_HASH=600000; N07_GROUP=1200000
    N08_ROWS=1200000
    N09_ROWS=1000000
    N10_ROWS=200000
fi

echo "=== Autovacuum / Bloat / Replication / Temp Files — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup bloat-drill table shells" -f 01_setup_bloat_drill_tables.sql

bg_step "03" "Table bloat from UPDATE/DELETE churn"        ./03_simulate_table_bloat_update_churn.sh "${N03_ROWS}" "${N03_CHURN}" "${YES_FLAG[@]}"
bg_step "04" "Index bloat outpaces table bloat"            ./04_simulate_index_bloat.sh "${N04_ROWS}" "${YES_FLAG[@]}"
bg_step "05" "Autovacuum worker starvation (concurrent vacuum-eligible tables)" ./05_simulate_autovacuum_worker_starvation.sh "${N05_TABLES}" "${N05_ROWS}" "${YES_FLAG[@]}"
bg_step "06" "Stale statistics → bad plan"                 ./06_simulate_stale_statistics_bad_plan.sh "${N06_ROWS}" "${YES_FLAG[@]}"

if [[ "${LIST_ONLY}" -ne 1 ]]; then
    echo ""
    echo "--- Resetting ${PGDATABASE}'s stats ONCE, shared by 07-sort/07-hash/07-group/08 ---"
    echo "    (see 07's header for the TF-1/TF-2 1h-floor-since-reset mechanic this"
    echo "    exploits — a shared reset lets their spills stack instead of each"
    echo "    wiping what its siblings already contributed) ---"
    psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c "SELECT pg_stat_reset();"
fi
export SKIP_STATS_RESET=1

bg_step "07-sort" "Temp-file spill: sort"                  ./07_simulate_temp_file_spill.sh sort "${N07_SORT}" "${YES_FLAG[@]}"
bg_step "07-hash" "Temp-file spill: hash join"              ./07_simulate_temp_file_spill.sh hash_join "${N07_HASH}" "${YES_FLAG[@]}"
bg_step "07-group" "Temp-file spill: hash aggregate"        ./07_simulate_temp_file_spill.sh group_by "${N07_GROUP}" "${YES_FLAG[@]}"
bg_step "08" "CREATE INDEX build temp/maintenance_work_mem spike" ./08_simulate_create_index_temp_spike.sh "${N08_ROWS}" "${YES_FLAG[@]}"
bg_step "09" "Inactive replication slot retains WAL"       ./09_simulate_replication_slot_wal_retention.sh "${N09_ROWS}" "${YES_FLAG[@]}"
bg_step "10" "Write surge → replica lag"                   ./10_simulate_replica_lag_write_surge.sh "${N10_ROWS}" "${YES_FLAG[@]}"
wait_bg_steps

psql_always_step "02" "Diagnostic sweep (autovacuum, bloat, replication, temp files, monitoring gaps)" -f 02_bloat_vacuum_diagnostic_sweep.sql

echo ""
echo "No cleanup step: drill tables/slot/sessions are left in place so hunters"
echo "have a real window to detect them."

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
