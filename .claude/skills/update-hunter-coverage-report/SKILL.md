---
name: update-hunter-coverage-report
description: Regenerate and republish the "Hunter Simulation Coverage Report" artifact — the per-hunter drill achieved/not-achieved breakdown with sourced reasons for every non-reproduction — from simulation-report/hunter-simulation-coverage.json. Use when new drill runs happen, AI-Hunters reports are refreshed, a hunter/topic folder is added or changed, or the JSON data file has been hand-edited and the published artifact needs to catch up. Trigger on "update the hunter coverage report", "regenerate the drill coverage artifact", "refresh the simulation coverage report", "sync the hunter report", "republish the hunter artifact".
---

# Update Hunter Simulation Coverage Report

Keeps the published Artifact in sync with `simulation-report/hunter-simulation-coverage.json`,
the single source of truth for: per-hunter simulation totals, achieved/not-achieved status per
script, and the specific sourced reason behind every non-reproduction.

Four files work together:

| File | Role |
|---|---|
| `simulation-report/hunter-simulation-coverage.json` | **Data.** One object per hunter, one row per script: `status` (`achieved` \| `not_achieved`), `reason`, plus topic-level `gaps` (scenarios with no script at all) and `meta.artifact_url` (the live link to update in place). |
| `simulation-report/hunter-simulation-coverage.html` | **Design template.** The last-published HTML — CSS custom-property theme tokens (light/dark), pill-status tables, per-hunter `<section id="h-…">`, overview cards, footer. Treat its structure/CSS as fixed; only the data-driven content (counts, rows, callouts) changes between regenerations. |
| `simulation-report/hunter-simulation-coverage.md` | **Narrative report.** A prose/markdown rendering of the same JSON data — per-hunter sections with monitor-tick context tables, a per-script achieved/not-achieved table with reasons, "not scripted" / "cannot be scripted" appendices, and a key-takeaways section. Regenerate this alongside the HTML whenever the JSON changes; keep the structure (summary table → per-hunter sections in `order` → key takeaways) but let the content follow the data. |
| Published Artifact at `meta.artifact_url` in the JSON | **Output.** What the user actually sees for the HTML version. |

## When invoked

**1. Decide whether this is a resync or a re-audit.**
- If the user (or a prior step) already edited the JSON directly — just the HTML needs to catch up. Skip to step 3.
- If the user wants fresh data pulled (new drill runs happened, `C:\SysCloud\Production\AI-Hunters\reports\` has new timestamped reports since `meta.compiled`, or a hunter/topic folder changed) — do step 2 first.

**2. Re-audit (only if fresh data is needed).**
For each hunter topic folder (`01-connection-exhaustion`, `02-locks-deadlocks-blocking-queries`,
`03-slow-queries`, `04-autovacuum-bloat-replication-temp-files`):
- Confirm the script inventory against that topic's `README.md` (its script-catalog table) — a script may have been added/removed since the JSON was last written.
- Check `session-run-output.log` and the newest `run_all_logs/<timestamp>/` for execution failures (non-zero exit, `ERROR:` lines) — these are hard "not achieved, script bug" findings independent of any hunter report.
- Cross-reference each script's drill `application_name` tag(s) (`grep -n "application_name" *.sh`) against every `C:\SysCloud\Production\AI-Hunters\reports\<hunter-name>-*.md` file newer than `meta.compiled`, plus that hunter's `-latest.md`. A script counts `achieved` only if its tag (or a table/relation it created) is named as evidence in an actual finding — appearing only in a blocked-session list or connection-count table doesn't count.
- Watch for cross-hunter check ownership (a topic folder's README sometimes says a check "lives in" a different hunter, e.g. topic 04's bloat checks actually belong to slow-queries) — verify in the *other* hunter's reports, not the folder's own.
- For anything genuinely ambiguous or requiring reading many report files, delegate to a `general-purpose` Agent per topic (as was done originally) rather than doing it all inline — it keeps context usage sane. Give it exact file paths and ask it to cite evidence per row, not just a verdict.
- Update the JSON: per-row `status`/`reason`, per-hunter `total`/`achieved`/`not_achieved`, `gaps`, and the top-level `totals`. Bump `meta.compiled` to today's date and `meta.window` if the audit window moved.

**3. Regenerate the HTML from the JSON.**
Read `hunter-simulation-coverage.html` as the structural/CSS reference and `hunter-simulation-coverage.json` as the data. Rewrite the HTML so every data-driven element reflects the JSON exactly:
- `.overview` cards: one per hunter, in `order`, with `achieved`/`total` and a `.bar .fill` width of `round(achieved/total*100)%`.
- `.totals-strip`: sum of `totals.total`/`achieved`/`not_achieved`.
- Each `<section class="hunter" id="{hunter.id}">`: heading numbered by `order`, `.tally` counts, `.callout` paragraph (omit the `<p class="callout">` entirely if `callout` is empty, as topic 3 currently has none), one `<tr>` per row with a `pill good`/`pill bad` status, and a `<details class="gaps">` block only if `gaps` is non-empty.
- `<footer>`: keep the methodology paragraph in sync with `meta.methodology`, and the source paths with `meta.sources`.
- Preserve the CSS block, theme tokens, and overall layout as-is unless the user explicitly asks for a design change — this skill's job is data sync, not a redesign. If you do change the design, load the `artifact-design` skill first and update both this file and the design description together.
- Write the regenerated HTML to the scratchpad path used by the `Artifact` tool for this session, **and** overwrite `simulation-report/hunter-simulation-coverage.html` in the repo with the same content, so the repo copy never drifts from what's actually published.
- Also regenerate `simulation-report/hunter-simulation-coverage.md` from the same JSON so all three files agree — same per-hunter totals, same rows, same reasons, just in narrative/table markdown form instead of HTML.

**4. Publish.**
Call the `Artifact` tool with `file_path` pointing at the regenerated HTML, `url` set to `meta.artifact_url` from the JSON (this is what makes it update the existing page instead of minting a new one), the same `favicon` (`meta.favicon`), and an updated `description`/`label` if the headline numbers changed materially. Do not change `favicon` on a routine data sync — only on a hard pivot in what the report covers.

**5. Report back** what changed: which rows flipped status, new totals, and the artifact URL (unchanged).

## Notes

- Never invent a "detected" verdict — every `achieved` row must trace to a specific, named piece of evidence in a report file or log. When in doubt, mark `not_achieved` and say why evidence is missing, rather than assuming success.
- The topic 2 (locks) hunter's low achieved-rate is a known, explained run-design artifact (concurrent drills sharing one lock-preemption chain) — don't "fix" this by inflating its numbers; if a future run is staggered instead of concurrent, re-audit it properly and let the numbers move on real evidence.
- If a whole new hunter/topic folder appears (a `05-*` directory), add it as a new object in `hunters[]` (bump `order`), add a new `.hcard` in the overview grid (`grid-template-columns` may need to go to 5 across, or wrap), and a new `<section>` — this is the one case where the HTML structure itself, not just data, needs to grow.
