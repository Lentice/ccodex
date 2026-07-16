# ccodex refinement backlog — curated

**Date:** 2026-07-15
**Source:** triaged down from `C:\Users\lenticetsai\AppData\Local\Temp\ccodex-refine-and-orchestration-summary.md` (the full collection).
**Purpose:** keep only the items judged worth building; everything else is explicitly dropped so it
does not get silently re-litigated. Build gated per item — pick the next one, spec it, then
implement.

## Tier 1 — orchestration core

1. **`list` + `--json`** — job enumeration endpoint; prerequisite for `wait --all` / dashboards.
   *(in progress — design: `2026-07-15-ccodex-list-command-design.md`)*
2. **`--json` on `status` / `read` / `wait`** — stable lifecycle envelope so agents stop parsing
   human text. Single most-repeated ask. Each envelope carries `schema_version`; human text stays
   the default.
3. **`wait --all` (+ `--group` / `--label`)** — removes hand-rolled fan-out/gather. Depends on
   `list`. Adds a `group`/`label` field at submit time (the data model these filters need).
4. **`submit --resume`** — async follow-ups; reuses the sync `resume` path but returns the child id
   immediately like `submit` (inherits parent mode/access/repo, preserves `parent_job_id`).

## Tier 2 — robustness / durable fixes

5. **Structured failure signal + `doctor --json`** — persist a failure object (reason + matched
   signal + source + confidence + HTTP code) in status.json; machine-readable doctor (one object
   per check). Also the durable fix for the fragile regex-precedence classification (deferred
   C3/C4).
6. **Prompt/invocation provenance (scoped) + idempotency** — record `prompt_source` + byte
   count + hash, argv, model/effort, repo revision, wrapper version (NOT the full prompt) so runs
   are reproducible and review independence is provable. Add `--client-task-id` / `--force-new` so
   a lost submit response or transport retry can't duplicate work.

## Tier 3 — small, high-leverage

7. **Installer hardening** — `-AddToUserPath` (idempotent PATH append) + manifest-backed install
   with `-Uninstall` and `-WhatIf`/`-Plan` dry-run. The manifest is also the clean fix for
   "installer wipes user `/ccodex:<name>` commands" (own only installer-managed files).
8. **`apply --check`** — transactional preview: validate the patch applies to the (clean) main repo
   before mutating it.
9. **`review --include-untracked`** — review new/untracked files, not just tracked diffs.
10. **Review profiles + `capabilities --json`** — deterministic prompt presets
    (`correctness`/`security`/`performance`/`tests`); a capability manifest the skill/commands
    consume instead of hard-coded tables, killing stale-instruction drift after upgrades.

## Dropped / indefinitely deferred

Low ROI or speculative — not planned unless a concrete need resurfaces:

- **A:** idle-timeout policy, `progress.json` snapshot, graceful cancellation phases, event-log
  flush batching.
- **B:** event-driven completion waits, `status-events.jsonl` transition history, lock-contention
  diagnostics, artifact-aware status summaries.
- **C:** `Get-CcodexExecutionPlan` / `doctor --plan`, classification policy profiles, version-probe
  cache. *(The structured failure signal in Tier 2 #5 covers the part that matters.)*
- **D:** worktree checkpoints; standalone review scope manifest + diff fingerprint *(folded into
  Tier 2 #6)*.
- **E:** reversible quarantine before delete, per-repo retention profiles, disk-budget cleanup,
  config provenance view. *(`cleanup --dry-run` already mitigates the delete risk.)*
- **F:** diff-budget preflight, structured finding IDs.
- **Item 6 (snapshot/manifest review mode):** conditional — only revisit if provably-isolated
  parallel reviews are actually wanted. Not planned now.

## Not part of this backlog

Tests-review (Partition H) and docs-review (Partition I) are a separate handoff
(`ccodex-review-handoff.md`).
