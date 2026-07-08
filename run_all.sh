#!/usr/bin/env bash
# =============================================================================
# run_all.sh — Full DBA drill suite: automated end-to-end run across all
# four simulations/ topics
# SysCloud DAL Team
#
# Runs each topic's own run_all.sh in sequence (01 → 02 → 03 → 04):
#   01-connection-exhaustion, 02-locks-deadlocks-blocking-queries,
#   03-slow-queries, 04-autovacuum-bloat-replication-temp-files
# Sequential, not parallel — every topic hits the same instance, and running
# e.g. topic 1's connection flood concurrently with topic 4's multi-million-
# row inserts would make the resulting pg_stat_activity/log signal useless
# for anyone trying to read it afterward.
#
# No fix/remediation or cleanup step anywhere in the suite: every drill
# leaves its issue in place (sessions, locks, bloat, stale statistics, the
# replication slot, etc.) and guarantees at least a 20-30s observation
# window, so the hunters have a real window to detect them across all four
# topics.
#
# ⚠️  NON-PRODUCTION USE ONLY. Never point .env at a production endpoint.
#
# Usage:
#   ./run_all.sh [--fast|--full] [--topics 1,3] [--no-dedupe-overlaps]
#                [--list] [--yes]
#
#   --fast        Small scale/duration (default) — whole suite finishes in
#                  ~15-20 minutes. Passed through to every topic.
#   --full        Doc-example scale (matches each topic README's quick-start
#                  numbers) — much slower, closer to a real incident's shape.
#   --topics 1,3  Only run these topic numbers (comma list, 1-4). Default:
#                  all four, in order.
#   --no-dedupe-overlaps
#                 Topic 02 has its own connection-exhaustion drill (script
#                 16) that overlaps topic 01's whole purpose. By default,
#                 when both topic 1 and topic 2 are selected, this passes
#                 `--skip 16` to topic 02 to avoid a redundant flood. Pass
#                 this flag to include it anyway.
#   --list        Print the topic sequence and exit; runs nothing at any
#                  level (also passed through so each topic prints its own
#                  manifest instead of running it — verbose, see below).
#   --yes / -y    Non-interactive, passed through to every topic (or set
#                  DRILL_YES=1 once in simulations/.env and skip this flag
#                  everywhere).
#
# Credentials: exports PG*/PGBOUNCER_*/DRILL_ROLE* from simulations/.env (or
# real exported env vars, which always win) so every topic subprocess picks
# them up automatically — no per-topic .env needed. Copy simulations/
# .env.example to simulations/.env and fill it in before running this.
#
# Logs: every step's full output is captured under
#   simulations/run_all_logs/<timestamp>/<topic>/
#
# Example — fast full-suite run, non-interactive:
#   DRILL_YES=1 ./run_all.sh
#
# Example — just the two query-performance topics, doc-example scale:
#   ./run_all.sh --full --topics 3,4 --yes
#
# Example — preview what a full run would do without touching the DB:
#   ./run_all.sh --list
# =============================================================================

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "_lib/env.sh"
source "_lib/runner.sh"

TOPICS="1,2,3,4"
SCALE_FLAG="--fast"
DEDUPE=1
SUITE_LIST_ONLY=0
YES_FLAG=()
for arg in "$@"; do
    case "${arg}" in
        --full) SCALE_FLAG="--full" ;;
        --fast) SCALE_FLAG="--fast" ;;
        --topics=*) TOPICS="${arg#--topics=}" ;;
        --no-dedupe-overlaps) DEDUPE=0 ;;
        --list) SUITE_LIST_ONLY=1 ;;
        --yes|-y) YES_FLAG=(--yes) ;;
    esac
done
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--topics" ]] && TOPICS="${arg}"
    prev="${arg}"
done

# Deliberately NOT the runner.sh `LIST_ONLY` global: at the suite level we
# still want to actually invoke each topic's run_all.sh (with --list passed
# through) so its real, fully-resolved manifest prints — not just the
# one-line "./0N.../run_all.sh --list" command itself.
TOP_LOG_DIR="./run_all_logs/$(date +%Y%m%d_%H%M%S 2>/dev/null || echo run)"
LIST_ONLY_EXPORT=()
[[ "${SUITE_LIST_ONLY}" -eq 1 ]] && LIST_ONLY_EXPORT=(--list)

want_topic() { [[ ",${TOPICS}," == *",$1,"* ]]; }

echo "======================================================================"
echo " DBA Drill Suite — run_all.sh"
echo " Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo " Topics: ${TOPICS}  |  Scale: ${SCALE_FLAG}  |  Cleanup: off (no fix/cleanup step anywhere)"
[[ "${SUITE_LIST_ONLY}" -eq 1 ]] && echo " (--list: each topic below prints its own resolved manifest; nothing runs)"
echo "======================================================================"

TOPIC02_EXTRA=()
if [[ "${DEDUPE}" -eq 1 ]] && want_topic 1 && want_topic 2; then
    TOPIC02_EXTRA=(--skip 16)
    echo "(dedupe: topic 02 will skip drill 16 — already covered by topic 01)"
fi

if want_topic 1; then
    RUNNER_LOG_DIR="${TOP_LOG_DIR}/01-connection-exhaustion" \
        step "topic1" "Topic 01 — Connection Exhaustion" \
        ./01-connection-exhaustion/run_all.sh "${SCALE_FLAG}" "${LIST_ONLY_EXPORT[@]}" "${YES_FLAG[@]}"
fi

if want_topic 2; then
    RUNNER_LOG_DIR="${TOP_LOG_DIR}/02-locks-deadlocks-blocking-queries" \
        step "topic2" "Topic 02 — Locks, Deadlocks & Blocking Queries" \
        ./02-locks-deadlocks-blocking-queries/run_all.sh "${SCALE_FLAG}" "${LIST_ONLY_EXPORT[@]}" "${YES_FLAG[@]}" "${TOPIC02_EXTRA[@]}"
fi

if want_topic 3; then
    RUNNER_LOG_DIR="${TOP_LOG_DIR}/03-slow-queries" \
        step "topic3" "Topic 03 — Slow Queries" \
        ./03-slow-queries/run_all.sh "${SCALE_FLAG}" "${LIST_ONLY_EXPORT[@]}" "${YES_FLAG[@]}"
fi

if want_topic 4; then
    RUNNER_LOG_DIR="${TOP_LOG_DIR}/04-autovacuum-bloat-replication-temp-files" \
        step "topic4" "Topic 04 — Autovacuum / Bloat / Replication / Temp Files" \
        ./04-autovacuum-bloat-replication-temp-files/run_all.sh "${SCALE_FLAG}" "${LIST_ONLY_EXPORT[@]}" "${YES_FLAG[@]}"
fi

runner_summary
exit $?
