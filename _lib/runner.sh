#!/usr/bin/env bash
# =============================================================================
# _lib/runner.sh — shared orchestration helpers for run_all.sh scripts.
#
# Source AFTER _lib/env.sh:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/env.sh"
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/runner.sh"
#
# Gives every run_all.sh a common "manifest of steps" pattern:
#   - should_run <id>   — honors --only/--skip id filters (comma lists)
#   - step <id> <label> <cmd...>  — runs (or, in --list mode, just prints) one
#     manifest entry; never aborts the overall run on a single step's failure
#   - runner_summary    — prints a pass/fail/timing table at the end and
#     returns non-zero if anything failed (for a script's own exit code)
#
# Deliberately does NOT use `set -e` semantics for step failures: a drill
# timing out or a detection script exiting non-zero (monitoring scripts use
# exit codes 1-3 for warn/critical/error, not failure) should never prevent
# later steps — especially cleanup — from running. Call run_all.sh scripts
# with `set -uo pipefail` (no `-e`) for the same reason.
# =============================================================================

RUNNER_LOG_DIR="${RUNNER_LOG_DIR:-}"
RUNNER_RESULTS=()   # "id|label|status|seconds"
ONLY="${ONLY:-}"
SKIP="${SKIP:-}"
LIST_ONLY="${LIST_ONLY:-0}"

# should_run <id> — false (1) if --only was given and id isn't in it, or if
# --skip was given and id is in it. True (0) otherwise.
should_run() {
    local id="$1"
    if [[ -n "${ONLY}" ]] && [[ ",${ONLY}," != *",${id},"* ]]; then
        return 1
    fi
    if [[ -n "${SKIP}" ]] && [[ ",${SKIP}," == *",${id},"* ]]; then
        return 1
    fi
    return 0
}

# run_step "<label>" <command...> — always returns 0 (never aborts a caller
# running under `set -e`); records the outcome in RUNNER_RESULTS.
run_step() {
    local label="$1"; shift
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
    echo "▶ ${label}"
    echo "  $*"
    echo "───────────────────────────────────────────────────────────────────"
    local start end status=0
    start=$(_runner_ts)
    if [[ -n "${RUNNER_LOG_DIR}" ]]; then
        mkdir -p "${RUNNER_LOG_DIR}"
        local slug logfile
        slug="$(printf '%s' "${label}" | tr -c 'A-Za-z0-9_' '_')"
        logfile="${RUNNER_LOG_DIR}/$(printf '%03d' "${#RUNNER_RESULTS[@]}")_${slug}.log"
        "$@" > >(tee "${logfile}") 2>&1 || status=$?
    else
        "$@" || status=$?
    fi
    end=$(_runner_ts)
    RUNNER_RESULTS+=("${label}|${status}|$((end - start))")
    if [[ "${status}" -eq 0 ]]; then
        echo "✔ ${label} (ok, $((end - start))s)"
    else
        echo "✘ ${label} — exit ${status} ($((end - start))s)"
    fi
    return 0
}

_runner_ts() { date +%s; }

# step <id> <label> <command...>
#
# Wraps run_step with --list/--only/--skip handling. In --list mode, prints
# the manifest entry and returns without running anything — lets an agent
# preview a full run before committing to it.
step() {
    local id="$1" label="$2"; shift 2
    if [[ "${LIST_ONLY}" -eq 1 ]]; then
        if should_run "${id}"; then
            printf '  [%-3s] %-48s %s\n' "${id}" "${label}" "$*"
        else
            printf '  [%-3s] %-48s %s  (would be SKIPPED by --only/--skip)\n' "${id}" "${label}" "$*"
        fi
        return 0
    fi
    if ! should_run "${id}"; then
        echo "⏭  [${id}] ${label} (skipped)"
        return 0
    fi
    run_step "[${id}] ${label}" "$@"
}

# always_step <id> <label> <command...>
#
# Like step(), but ignores --only/--skip filtering — for detection and
# cleanup steps that should still run even when --only narrows a manifest
# down to one or two drills (cleanup in particular must never be silently
# skipped just because it wasn't in an --only list). Still honors --list.
always_step() {
    local id="$1" label="$2"; shift 2
    if [[ "${LIST_ONLY}" -eq 1 ]]; then
        printf '  [%-3s] %-48s %s  (always runs — not affected by --only/--skip)\n' "${id}" "${label}" "$*"
        return 0
    fi
    run_step "[${id}] ${label}" "$@"
}

# psql_step <id> <label> <psql-args...> — convenience wrapper for a `psql -f
# some.sql` (or `-c`) detection/cleanup step, so callers don't repeat the
# connection flags in every manifest line.
psql_step() {
    local id="$1" label="$2"; shift 2
    step "${id}" "${label}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" "$@"
}

# psql_always_step — psql_step's always-run counterpart (see always_step).
psql_always_step() {
    local id="$1" label="$2"; shift 2
    always_step "${id}" "${label}" psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" "$@"
}

# runner_summary — prints the results table; returns 1 if any step failed
# (monitoring-script exit codes 1-3 for warn/critical still count as
# "failed" here purely for the summary glyph — check individual logs for
# what they actually mean).
runner_summary() {
    echo ""
    echo "======================================================================"
    echo " SUMMARY"
    echo "======================================================================"
    local total=0 failed=0 entry label status seconds
    for entry in "${RUNNER_RESULTS[@]}"; do
        IFS='|' read -r label status seconds <<< "${entry}"
        total=$((total + 1))
        if [[ "${status}" -eq 0 ]]; then
            printf "  ✔ %-58s %5ss\n" "${label}" "${seconds}"
        else
            failed=$((failed + 1))
            printf "  ✘ %-58s %5ss  (exit %s)\n" "${label}" "${seconds}" "${status}"
        fi
    done
    echo "----------------------------------------------------------------------"
    echo "  ${total} step(s) run, ${failed} non-zero exit(s)"
    [[ -n "${RUNNER_LOG_DIR}" ]] && echo "  Logs: ${RUNNER_LOG_DIR}"
    echo "======================================================================"
    [[ "${failed}" -eq 0 ]]
}
