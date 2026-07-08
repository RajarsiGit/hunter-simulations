#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Autovacuum / Bloat / Replication / Temp Files: automated
# end-to-end drill run
# SysCloud DAL Team
#
# Runs setup, all 9 drills in this folder (table/index bloat, autovacuum
# worker starvation, stale-stats bad plan, temp-file spill x3 modes, CREATE
# INDEX temp spike, replication-slot WAL retention, replica-lag write surge),
# the diagnostic sweep, then cleanup.
#
# ⚠️  NON-PRODUCTION USE ONLY. Same rules as every script in this folder.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--only 04,09] [--skip 07-sort]
#                [--no-cleanup] [--list] [--yes]
#
#   --fast    Smaller row counts (default) — full manifest finishes in a
#              few minutes. May not reliably reproduce every signal (e.g.
#              temp-file spill needs enough data to exceed work_mem) — use
#              --full for a realistic reproduction.
#   --full    Doc-example row counts (matches README quick-start numbers) —
#              slower (multi-million-row inserts), closer to a real incident.
#   --only id Only run these ids (comma list) — see id list below.
#   --skip id Skip these ids.
#   --no-cleanup  Leave drill tables/slot/sessions in place after the run.
#   --list    Print the manifest (with resolved args) and exit.
#   --yes/-y  Non-interactive, passed through to each drill (or set
#              DRILL_YES=1).
#
# Ids: 01=setup, 03-06/08-10=drills, 07-sort/07-hash/07-group=temp-spill
#      drill (3 sub-modes, separate ids), 02=diagnostic sweep, 11=cleanup
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
    N03_ROWS=50000;  N03_CHURN=10
    N04_ROWS=50000
    N05_TABLES=2;    N05_ROWS=200000
    N06_ROWS=50000
    N07_SORT=1000000; N07_HASH=500000; N07_GROUP=1000000
    N08_ROWS=1000000
    N09_ROWS=500000
    N10_ROWS=500000
else
    N03_ROWS=500000; N03_CHURN=50
    N04_ROWS=500000
    N05_TABLES=3;    N05_ROWS=1000000
    N06_ROWS=500000
    N07_SORT=5000000; N07_HASH=2000000; N07_GROUP=5000000
    N08_ROWS=5000000
    N09_ROWS=2000000
    N10_ROWS=3000000
fi

echo "=== Autovacuum / Bloat / Replication / Temp Files — run_all.sh (${MODE_LABEL}) ==="
echo "Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
[[ "${LIST_ONLY}" -eq 1 ]] && echo "(--list: printing manifest only, nothing will run)"
echo ""

psql_always_step "01" "Setup bloat-drill table shells" -f 01_setup_bloat_drill_tables.sql

step "03" "Table bloat from UPDATE/DELETE churn"        ./03_simulate_table_bloat_update_churn.sh "${N03_ROWS}" "${N03_CHURN}" "${YES_FLAG[@]}"
step "04" "Index bloat outpaces table bloat"            ./04_simulate_index_bloat.sh "${N04_ROWS}" "${YES_FLAG[@]}"
step "05" "Autovacuum worker starvation (concurrent vacuum-eligible tables)" ./05_simulate_autovacuum_worker_starvation.sh "${N05_TABLES}" "${N05_ROWS}" "${YES_FLAG[@]}"
step "06" "Stale statistics → bad plan"                 ./06_simulate_stale_statistics_bad_plan.sh "${N06_ROWS}" "${YES_FLAG[@]}"
step "07-sort" "Temp-file spill: sort"                  ./07_simulate_temp_file_spill.sh sort "${N07_SORT}" "${YES_FLAG[@]}"
step "07-hash" "Temp-file spill: hash join"              ./07_simulate_temp_file_spill.sh hash_join "${N07_HASH}" "${YES_FLAG[@]}"
step "07-group" "Temp-file spill: hash aggregate"        ./07_simulate_temp_file_spill.sh group_by "${N07_GROUP}" "${YES_FLAG[@]}"
step "08" "CREATE INDEX build temp/maintenance_work_mem spike" ./08_simulate_create_index_temp_spike.sh "${N08_ROWS}" "${YES_FLAG[@]}"
step "09" "Inactive replication slot retains WAL"       ./09_simulate_replication_slot_wal_retention.sh "${N09_ROWS}" "${YES_FLAG[@]}"
step "10" "Write surge → replica lag"                   ./10_simulate_replica_lag_write_surge.sh "${N10_ROWS}" "${YES_FLAG[@]}"

psql_always_step "02" "Diagnostic sweep (autovacuum, bloat, replication, temp files, monitoring gaps)" -f 02_bloat_vacuum_diagnostic_sweep.sql

if [[ "${DO_CLEANUP}" -eq 1 ]]; then
    psql_always_step "11" "Cleanup (drill sessions, replication slot, drill tables)" -f 11_cleanup_bloat_drill.sql
else
    echo ""
    echo "⚠️  --no-cleanup: drill tables/slot/sessions left in place. Clean up later with:"
    echo "    psql -h \"\$PGHOST\" -p \"\$PGPORT\" -U \"\$PGUSER\" -d \"\$PGDATABASE\" -f 11_cleanup_bloat_drill.sql"
fi

[[ "${LIST_ONLY}" -eq 1 ]] && exit 0
runner_summary
exit $?
