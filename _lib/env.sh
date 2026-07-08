#!/usr/bin/env bash
# =============================================================================
# _lib/env.sh — shared credential loading + confirmation helper for every
# drill/diagnostic script under dba-issues/simulations/.
#
# Source this near the top of every script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"
#
# Credentials come from a `.env` file in the CURRENT WORKING DIRECTORY (i.e.
# wherever the script is invoked from — typically the repo root), so nothing
# is ever hardcoded and nothing needs to be exported by hand. Real exported
# env vars always win over `.env` values, so CI/agent callers can override
# per-invocation without editing the file.
#
# Recognized variables (put these in .env — see simulations/.env.example):
#   PGHOST, PGPORT (default 5432), PGUSER, PGPASSWORD, PGDATABASE
#   PGBOUNCER_HOST (default PGHOST), PGBOUNCER_PORT (default 6432)
#   PGBOUNCER_ADMIN_USER (default postgres), PGBOUNCER_ADMIN_PASSWORD
#   DRILL_YES=1 — skip the interactive typed-"yes" confirmation (agent mode)
# =============================================================================

if [[ -f "${PWD}/.env" ]]; then
    set -o allexport
    # shellcheck disable=SC1091,SC1090
    source "${PWD}/.env"
    set +o allexport
fi

: "${PGHOST:?Set PGHOST — via .env in the current directory or an exported env var}"
: "${PGUSER:?Set PGUSER}"
: "${PGDATABASE:?Set PGDATABASE}"
export PGHOST PGUSER PGDATABASE
export PGPORT="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-}"

export PGBOUNCER_HOST="${PGBOUNCER_HOST:-${PGHOST}}"
export PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
export PGBOUNCER_ADMIN_USER="${PGBOUNCER_ADMIN_USER:-postgres}"
export PGBOUNCER_ADMIN_PASSWORD="${PGBOUNCER_ADMIN_PASSWORD:-${PGPASSWORD:-}}"

# confirm_drill "<what this drill is about to do>" "$@"
#
# Prints a safety banner and fires immediately — no typed confirmation, ever.
# Aggressive-mode: drills are meant to fire on demand without a human in the
# loop. --yes/-y/DRILL_YES=1 are still accepted (harmlessly) for backward
# compatibility with existing invocations, but they're no longer required —
# omitting them no longer blocks anything.
confirm_drill() {
    local message="$1"
    echo ""
    echo "⚠️  ${message}"
    echo "⚠️  NON-PRODUCTION USE ONLY. Target: ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
    echo "Firing immediately (no confirmation gate) — aggressive mode."
}

# ensure_min_duration [floor_seconds]
#
# Pads the calling script with a trailing sleep so its total wall time (as
# measured by bash's $SECONDS, which counts from shell start) is at least
# <floor_seconds> (default 90). Call this as the last thing before a drill
# script's final echo. Guarantees a minimum observation window for anyone
# querying pg_locks/pg_stat_activity mid-drill, even when a script's HOLD
# argument is small or its internal timing is fixed/short — a no-op if the
# script has already run that long.
ensure_min_duration() {
    local floor="${1:-90}"
    if (( SECONDS < floor )); then
        local remaining=$(( floor - SECONDS ))
        echo ""
        echo "--- Holding drill window open ${remaining}s more (guarantees a ${floor}s minimum observation window) ---"
        sleep "${remaining}"
    fi
}

# strip_flags "$@" — echoes back only the positional (non --yes/-y) args, so
# scripts can keep using "${1:-default}" style positional parsing after
# stripping the confirmation flag. Usage: set -- $(strip_flags "$@")
strip_flags() {
    local arg
    for arg in "$@"; do
        [[ "${arg}" == "--yes" || "${arg}" == "-y" ]] && continue
        printf '%s\n' "${arg}"
    done
}

# run_seq_scan_burst "<app_name>" "<perform_sql>" [iterations]
#
# Runs <perform_sql> (a PERFORM-safe expression, e.g. "1 FROM t WHERE ...")
# <iterations> times (default 1500) inside a single PL/pgSQL DO block on one
# connection — no per-iteration round-trip, so it finishes in a few seconds.
# Each PERFORM against an unindexed predicate is its own sequential scan, so
# this pushes pg_stat_user_tables.seq_scan past the AI-Hunters slow-queries
# hunter's seq_scan_tables threshold (seq_scan > 1000, seq_scan_ratio > 0.80 —
# see AI-Hunters/queries/slow-queries/slow-queries-seq-scans.sql). A single
# EXPLAIN ANALYZE run only bumps the counter by 1, which never crosses it.
# Requires the caller to have already defined the PSQL array.
run_seq_scan_burst() {
    local app_name="$1"
    local perform_sql="$2"
    local iterations="${3:-1500}"
    "${PSQL[@]}" -v ON_ERROR_STOP=1 -c "SET application_name = '${app_name}';
                      DO \$\$
                      BEGIN
                        FOR i IN 1..${iterations} LOOP
                          PERFORM ${perform_sql};
                        END LOOP;
                      END \$\$;"
}

# hold_session_active "<app_name>" "<sql>" [seconds]
#
# Runs <sql> then pg_sleep(seconds) in the SAME statement, backgrounded, so
# the session stays state='active' in pg_stat_activity for at least <seconds>
# (default 120 — well over the hunter's 30s query_slow threshold; see
# AI-Hunters/queries/slow-queries/slow-queries.sql). A single EXPLAIN ANALYZE
# invocation completes in well under a second and is never sampled as "slow"
# by the poller (10s interval) without this. Sets the caller's HOLD_PID
# variable to the background PID — `wait "$HOLD_PID"` before the script exits
# so the hunter has time to poll while the session is still active.
#
# Call this directly (NOT via `HOLD_PID=$(hold_session_active ...)`).
# Command substitution runs the function in a subshell, so the `&` job it
# backgrounds becomes a child of that (already-exited) subshell rather than
# of the calling script — `wait "$HOLD_PID"` then fails with "not a child of
# this shell", is swallowed by `|| true`, and returns instantly instead of
# blocking for <seconds>, so the drill never actually holds the session open
# long enough for the poller to observe it. Requires the caller to have
# already defined the PSQL array.
hold_session_active() {
    local app_name="$1"
    local sql="$2"
    local seconds="${3:-120}"
    "${PSQL[@]}" -c "SET application_name = '${app_name}';
                      SELECT (SELECT count(*) FROM (${sql}) _sustain_sub) AS matched, pg_sleep(${seconds});" \
        >/dev/null &
    HOLD_PID=$!
}
