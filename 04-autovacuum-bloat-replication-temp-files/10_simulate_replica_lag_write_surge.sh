#!/usr/bin/env bash
# =============================================================================
# 10_simulate_replica_lag_write_surge.sh
# Replication DRILL — Write Surge / Long Replica Query Causes Replica Lag
# SysCloud DAL Team
#
# ⚠️  NON-PRODUCTION USE ONLY. Requires 01_setup_bloat_drill_tables.sql.
#
# Source: gpt-docs "RDS PostgreSQL Investigation Guide" §4.5-4.6
#         (Scenario B1 write-surge lag, Scenario B2 long replica query
#         delays replay).
#
# LIMITATION: fully observing replica lag requires an actual RDS read
# replica to point REPLICA_PGHOST/REPLICA_PGPORT at. Without one, this
# script still performs the primary-side write-surge simulation and the
# primary-side pg_stat_replication detection query (useful on its own if you
# already have a replica attached to this instance) — it just can't show you
# the replica-side replay_delay/query-cancellation half of the picture.
# Set REPLICA_PGHOST (and optionally REPLICA_PGUSER/REPLICA_PGDATABASE, which
# default to PGUSER/PGDATABASE) to enable the replica-side checks.
#
# Usage:
#   ./10_simulate_replica_lag_write_surge.sh [row_count] [--yes]
#   REPLICA_PGHOST=<read-replica-endpoint> ./10_simulate_replica_lag_write_surge.sh 3000000
# =============================================================================

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"

ROW_COUNT="${1:-3000000}"
REPLICA_PGHOST="${REPLICA_PGHOST:-}"
REPLICA_PGUSER="${REPLICA_PGUSER:-${PGUSER}}"
REPLICA_PGDATABASE="${REPLICA_PGDATABASE:-${PGDATABASE}}"

confirm_drill "This bulk-inserts/updates ${ROW_COUNT} rows into wal_drill_records on the PRIMARY to generate a write surge, then checks pg_stat_replication for lag. ${REPLICA_PGHOST:+A replica check against ${REPLICA_PGHOST} will also run.}" "$@"

echo ""
echo "=== DRILL: Write Surge Causes Replica Lag (Investigation Guide §4.5-4.6 / Scenario B1-B2) ==="
echo "Target (primary): ${PGHOST}:${PGPORT}/${PGDATABASE} | rows=${ROW_COUNT}"
if [[ -z "${REPLICA_PGHOST}" ]]; then
    echo "REPLICA_PGHOST not set — running primary-side simulation + detection only."
else
    echo "Replica  : ${REPLICA_PGHOST}"
fi

echo ""
echo "--- Baseline: pg_stat_replication (empty/no rows if this instance has no replicas) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT application_name, state, sync_state,
                pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes, replay_lag
         FROM pg_stat_replication;"

echo ""
echo "--- Generating a write surge on the primary (bulk insert + bulk update) ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 \
     -c "SET application_name = 'drill_replica_lag_writer';
         INSERT INTO wal_drill_records (payload)
         SELECT repeat(md5(random()::text), 50) FROM generate_series(1, ${ROW_COUNT});
         UPDATE wal_drill_records SET payload = repeat(md5(random()::text), 50)
         WHERE id % 2 = 0;"

echo ""
echo "--- Detect (primary): replication lag right after the surge ---"
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
     -c "SELECT application_name, state,
                pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag_bytes,
                write_lag, flush_lag, replay_lag
         FROM pg_stat_replication;"

if [[ -n "${REPLICA_PGHOST}" ]]; then
    echo ""
    echo "--- Detect (replica ${REPLICA_PGHOST}): replay delay ---"
    psql -h "${REPLICA_PGHOST}" -p "${PGPORT}" -U "${REPLICA_PGUSER}" -d "${REPLICA_PGDATABASE}" \
         -c "SELECT pg_is_in_recovery() AS is_replica,
                    now() - pg_last_xact_replay_timestamp() AS replay_delay,
                    pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS receive_replay_gap;"
else
    echo ""
    echo "Skipping replica-side check (REPLICA_PGHOST not set). CloudWatch metrics to watch"
    echo "instead: ReplicaLag, WriteIOPS, WriteThroughput, TransactionLogsDiskUsage."
fi

echo ""
echo "Remediation: pause/throttle the batch job, commit in smaller chunks"
echo "  (UPDATE ... WHERE id BETWEEN x AND y; COMMIT;), scale the replica instance"
echo "class if replay genuinely can't keep up, or route analytical reads off the"
echo "lagging replica. For a long-running query stalling replay on the replica"
echo "itself (Scenario B2), cancel it there: SELECT pg_cancel_backend(<pid>);"
echo ""
echo "Drill complete. Run 11_cleanup_bloat_drill.sql when finished with this topic's drills."
