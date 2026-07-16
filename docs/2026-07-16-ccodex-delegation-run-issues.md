# ccodex issues observed during the 2026-07-16 delegation run

**Date:** 2026-07-16
**Context:** backlog items 2–5 (`--json` envelopes, `wait --all` + group/label, `submit --resume`,
structured failure signal + `doctor --json`) were implemented by delegating to Codex through
ccodex itself (spec → `submit --mode implement` → review → `apply`). Seven issue observations
(O1–O7) were logged along the way, then each was verified by Codex against the actual code and
docs (read-only brainstorm session, HEAD `22800dd`) and triaged by the driving agent. This file
is the confirmed record; actionable outcomes are tracked in [`BACKLOG.md`](BACKLOG.md).

Verdict legend: **real-defect** / **by-design** (contract says so) / **user-misuse** /
**needs-repro**.

## Summary table

| # | Observation | Verdict | Outcome |
|---|---|---|---|
| O1 | `--help`/`-h` exits 2 with "not implemented" instead of printing usage (top level and every subcommand) | by-design (reference:35 documents unknown-command exit 2; installed skill expects it) — but real UX friction | **Feature candidate**: intercept `help`/`--help`/`-h` before command validation, print concise per-command usage. → BACKLOG F1 |
| O2 | `apply` refuses when unrelated untracked files make the tree dirty | by-design (adapter-design:1141 requires clean main tree; simple transactional invariant) | Keep default. Opt-in `--allow-untracked` (inventory untracked, reject patch-path overlap incl. dirs/renames/case-folding, verify byte-preservation) only if demand persists. → BACKLOG F4 (low) |
| O3 | Long implement jobs needed chained `wait` calls (exit 20 each round) | user-misuse — `wait` without `--wait-timeout-sec` blocks indefinitely; the bounded waits were the caller's choice; `wait --all` now also exists (eb05aee) | No work needed. |
| O4 | `apply` lands the worker's own commit (author `ccodex-worker`, message `ccodex: worker output <job_id>`) | by-design **and documented** (README:204 "lands the worker's snapshot commit"; reference:203/221 gives the synthetic identity and the `format-patch \| git am` mechanism) | Observation withdrawn as a defect. Optional `--stage-only` mode noted as a separate feature if uncommitted landing is ever wanted. |
| O5 | Full-suite flake: detached-worker cold-start timeout (exit 23), a different file each run under host load, each passes in isolation | needs-repro — suspected fixed 20 s confirmation window (ccodex.ps1:825, Detach.ps1:128 → exit 23 at ccodex.ps1:969); dev-notes:34 already warns loaded-host pwsh cold starts reach 3–7 s | **Top reliability candidate**: reproduce under load keeping runner tail/status artifacts; if confirmed, raise or make test-configurable the confirmation window. Tests must never blanket-accept exit 23. → BACKLOG F2 |
| O6 | `resume` rejects worktree (implement) jobs, so a review-rejected implement round restarts from scratch with no session memory | by-design (reference:282 precondition) but a legitimate design gap; `submit --resume` (28b6f66) does not change this | **Feature candidate**: child job + NEW worktree seeded from the parent's snapshot commit, resume the Codex thread with `-C` at the child worktree. Never reuse the parent worktree (breaks per-job ownership / concurrent follow-ups). → BACKLOG F3 |
| O7 | `quota_or_rate_limit` failure carries no retry-after info; caller can only guess a delay | by-design — contract is "report, do not auto-retry" (reference:677, adapter-design:957); stderr/events + the item-5 `failure` object are the intended channels | Conditional feature: only if Codex emits explicit structured retry/reset data, add nullable append-only `retry_after_sec` / `rate_limit_reset_at` sourced from that evidence alone — never inferred from prose. → BACKLOG F5 (conditional) |

## Codex-recommended priority (adopted)

1. **O5** reproduction + fix — only candidate correctness/reliability defect.
2. **O1** help support — small cost, repeatedly useful.
3. **O6** worktree continuation — high workflow value, needs careful child-worktree design.
4. **O7** structured retry timing — only after confirming trustworthy structured timing exists.
5. **O2/O4** — keep defaults; opt-in modes only with demonstrated demand.
6. **O3** — no work.

## Process notes (what the run itself demonstrated)

- The delegation loop (spec → implement job → independent review → pushback → apply → full suite
  → install hash-verify) caught one confirmed functional bug (round-1 `wait --all <id>` guard)
  and a large silent test shortfall before landing — the review step is not optional.
- The O6 gap made the item-3 fix round a full re-implementation (spec + previous diff + findings
  embedded in a fresh job prompt), which worked but roughly doubled that item's Codex time.
- One `quota_or_rate_limit` failure (O7) was classified correctly and the run continued after a
  user-side quota reset; classification behaved as designed.
