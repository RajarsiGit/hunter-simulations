#!/usr/bin/env bash
# =============================================================================
# 12_simulate_long_txn_vacuum_bloat.sh
# Locks & Deadlocks DRILL — Long-Running Transaction Blocking Vacuum / Bloat
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Run only against a drill/test RDS instance.
#     Requires 01_setup_lock_drill_tables.sql to have been run first.
#
# Reproduces:
#   A long-running transaction (even a pure SELECT) holds an old snapshot open
#   via backend_xmin. Autovacuum and manual VACUUM cannot reclaim dead tuples
#   that are still visible to this snapshot, causing table bloat.
#
# Drill sequence:
#   t=0s  Session A: BEGIN; SELECT * ... (holds snapshot, does nothing else)
#   t=2s  Session B: runs DELETE rows + UPDATE rows → creates dead tuples
#   t=4s  Session B: VACUUM VERBOSE → vacuum runs but cannot reclaim dead tuples
#                    visible to Session A's old snapshot
#   t=Xs  DBA: checks pg_stat_activity for old backend_xmin, checks
#              pg_stat_user_tables to see n_dead_tup remains high after vacuum
#
# What to observe:
#   - Session A: state='idle in transaction', backend_xmin is an old XID
#   - After VACUUM, n_dead_tup in pg_stat_user_tables stays > 0
#   - After Session A commits/terminates, re-running VACUUM clears dead tuples
#
# Usage:
#   ./12_simulate_long_txn_vacuum_bloat.sh [hold_seconds] [--yes]
#
# Default: hold_seconds=900. NOTE: this scenario isn't gated by any check in
# THIS hunter (actions/locks-deadlocks-blocking-queries.jsonc) — table bloat
# detection lives in the autovacuum-bloat-replication-temp-files hunter. 900s
# matches run_all.sh's shared HOLD variable for this folder and gives a wide
# window for manual/agent inspection of n_dead_tup and backend_xmin.
#
# NOTE: like the pre-fix 02/11, "SELECT pg_sleep(N)" inside one -c string
# keeps state='active' the whole time, NOT 'idle in transaction', despite
# this script's inline comments — harmless here since no check in this
# jsonc keys off session state for this scenario, so left as-is.
#
# CEILING WARNING: SysCloud baseline (runbook §7.3) statement_timeout=5min
# would otherwise kill this session's pg_sleep at 300s — disabled below.
# Credentials come from .env in the current directory (see simulations/.env.example).
# =============================================================================

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

HOLD_SECONDS="${1:-900}"

echo "=== DRILL: Long-Running Transaction Blocking Vacuum ==="
echo "Target     : ${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "Hold       : ${HOLD_SECONDS}s (Session A holds old snapshot)"
echo ""
echo "⚠️  Requires lock_test_accounts (run 01_setup_lock_drill_tables.sql first)."
confirm_drill "Holds an old REPEATABLE READ snapshot for ${HOLD_SECONDS}s while dead tuples accumulate and VACUUM cannot reclaim them." "$@"

echo ""
echo "--- Baseline: checking current dead tuple count ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_autovacuum, last_vacuum
         FROM   pg_stat_user_tables
         WHERE  relname = 'lock_test_accounts';"

echo ""
echo "--- Session A (t=0): BEGIN with long-held SELECT — pins old snapshot ---"
echo "    backend_xmin will prevent vacuum from cleaning dead rows created after this point."

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_long_txn_snapshot_holder';
         SET statement_timeout = 0;
         SET idle_in_transaction_session_timeout = 0;
         BEGIN ISOLATION LEVEL REPEATABLE READ;
         SELECT count(*) FROM lock_test_accounts;
         SELECT pg_sleep(${HOLD_SECONDS});
         ROLLBACK;" &
HOLDER_PID=$!
echo "  Session A spawned (shell pid ${HOLDER_PID}) — snapshot pinned"

sleep 3

echo ""
echo "--- Session B: creating dead tuples (UPDATE + DELETE) then running VACUUM ---"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SET application_name = 'drill_long_txn_workload';" \
     -c "UPDATE lock_test_accounts SET balance = balance + 1 WHERE id <= 3;" \
     -c "DELETE FROM lock_test_accounts WHERE id = 4;" \
     -c "VACUUM (VERBOSE, ANALYZE) lock_test_accounts;" \
     2>&1 | sed 's/^/  [Session B] /'

echo ""
echo "--- Checking dead tuple count AFTER vacuum (while Session A still holds snapshot) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum
         FROM   pg_stat_user_tables
         WHERE  relname = 'lock_test_accounts';"
echo "  ↑ n_dead_tup > 0 even after VACUUM — blocked by Session A's old backend_xmin"

echo ""
echo "Drill is LIVE. Observe in another terminal:"
echo ""
echo "  -- Find the long transaction by backend_xmin and xact_start:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pid, application_name, backend_xmin,"
echo "               now()-xact_start AS xact_age, state, left(query,80) AS query"
echo "         FROM  pg_stat_activity"
echo "         WHERE xact_start IS NOT NULL"
echo "         ORDER BY xact_start;\""
echo ""
echo "  -- Also covered in 09_lock_triage_queries.sql §7"
echo ""
echo "  -- Terminate Session A, then re-run VACUUM to confirm cleanup:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"SELECT pg_terminate_backend(pid)"
echo "         FROM  pg_stat_activity"
echo "         WHERE application_name = 'drill_long_txn_snapshot_holder';\""
echo ""
echo "  -- Then:"
echo "  psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} \\"
echo "    -c \"VACUUM (VERBOSE, ANALYZE) lock_test_accounts;\""
echo "  -- And re-check n_dead_tup — it should drop to 0."
echo ""
echo "Session A auto-releases after ${HOLD_SECONDS}s. Waiting..."
wait
echo ""
echo "Session A released. Running VACUUM again to show cleanup..."
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "VACUUM (VERBOSE, ANALYZE) lock_test_accounts;" \
     2>&1 | sed 's/^/  [Post-release VACUUM] /'

echo ""
echo "--- Final dead tuple count (should be 0 or near 0 now) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum
         FROM   pg_stat_user_tables
         WHERE  relname = 'lock_test_accounts';"

ensure_min_duration 30
echo "Drill complete."
