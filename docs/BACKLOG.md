# ccodex backlog (living document)

The single place to look for "what is left to do". When the user asks an agent to list open
items, read THIS file and present the tables below; the user picks, the agent specs and
implements (delegation flow per the installed ccodex rule). Update this file in the same piece
of work whenever an item lands, is added, or is dropped.

Sources: curated refinement backlog
([2026-07-15-ccodex-refinement-backlog-curated.md](2026-07-15-ccodex-refinement-backlog-curated.md))
and the delegation-run issue record
([2026-07-16-ccodex-delegation-run-issues.md](2026-07-16-ccodex-delegation-run-issues.md)).

## Done (for reference)

| Item | Landed |
|---|---|
| 1. `list` + `--json` | 3d6981c / d9ea6a6 |
| 2. `--json` on `status`/`read`/`wait` | 3f8bc36 |
| 3. `wait --all` (+ `--group`/`--label` on run/submit/list) | eb05aee |
| 4. `submit --resume` (async follow-ups) | 28b6f66 |
| 5. Structured failure signal + `doctor --json` | 22800dd |

## Open — curated backlog items (user picks)

| # | Item | Tier | Notes |
|---|---|---|---|
| 6 | Prompt/invocation provenance (scoped) + idempotency (`--client-task-id` / `--force-new`) | 2 | prompt_source + byte count + hash, argv, model/effort, repo revision, wrapper version — not the full prompt |
| 7 | Installer hardening (`-AddToUserPath`, manifest-backed install, `-Uninstall`, `-WhatIf`/`-Plan`) | 3 | manifest also fixes "installer wipes user `/ccodex:<name>` commands" |
| 8 | `apply --check` (transactional preview) | 3 | validate the patch applies to the clean main repo before mutating |
| 9 | `review --include-untracked` | 3 | review new/untracked files, not just tracked diffs |
| 10 | Review profiles + `capabilities --json` | 3 | deterministic prompt presets; capability manifest consumed by skill/commands |

## Open — issues from the 2026-07-16 delegation run (user picks)

Priority order per the Codex-confirmed triage (F2 first):

| # | Item | Origin | Notes |
|---|---|---|---|
| F2 | Reproduce + fix detached-worker cold-start timeout flake (exit 23) under host load | O5 | suspected fixed 20 s confirmation window (ccodex.ps1:825, Detach.ps1:128); reproduce first, keep artifacts; never blanket-accept exit 23 in tests |
| F1 | `help` / `--help` / `-h` support (top level + per subcommand) | O1 | intercept before command validation; concise usage output |
| F3 | Worktree-job continuation: child job + new worktree seeded from parent snapshot commit, resume Codex thread there | O6 | never reuse the parent worktree; unblocks review-pushback rounds on implement jobs |
| F5 | `retry_after_sec` / `rate_limit_reset_at` on quota failures (conditional) | O7 | only from explicit structured Codex evidence, never inferred from prose |
| F4 | `apply --allow-untracked` (opt-in, overlap-safe) | O2 | only if demand persists; keep clean-tree default |

## Explicitly not planned

- O3 (chained waits): user-misuse; indefinite wait and `wait --all` already cover it.
- O4 (`apply` lands worker commit): by-design and documented; optional `--stage-only` only if
  uncommitted landing is ever genuinely wanted.
- Everything under "Dropped / indefinitely deferred" in the curated backlog.
