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
| F2. Cold-start exit-23 flake: 120 s sentinel default + `CCODEX_STARTUP_TIMEOUT_SEC` + dead-worker fast-fail | 7079237 |
| F3. Worktree-job continuation: snapshot-seeded child worktree + cumulative diff/apply | 07a8a51 |
| F1. `help` / `--help` / `-h` support (top level + per subcommand) | fdc58b8 |
| F4. `apply --allow-untracked` (opt-in, overlap-safe) | 0ae6fbd |
| 11. `diff --stat` / `--name-only` (mutually-exclusive scoped views) | f669eec |
| 12. `apply --message <msg>` / `--reset-author` (single-commit operator identity) | f669eec |
| 14. Dispatcher → data-driven command registry (enabler for #6–#13) | 246d5f3 / 025ccd1 / 27200bb / 5e89a7e |
| 16. Zero-wait orphan reconciliation on the `status`/`read`/`wait`/`wait --all` lifecycle polling paths | landed 2026-07-20 |
| 19. Structured review findings schema (parser + `findings` in `read`/`wait`/`wait --all` `--json`; review-prompt appendix) | 394e73b / ee58261 / cfaec83 / 047c7c2 (+ docs) |
| 15. Drop `confidence:low` failure-classification signatures (precision over recall) | landed 2026-07-20 |
| 13. `tail --max-line` per-line events truncation + oversized-final-line retrieval fix | landed 2026-07-21 (#11) |

## Open — curated backlog items (user picks)

| # | Item | Tier | Notes |
|---|---|---|---|
| 6 | Prompt/invocation provenance (scoped) + idempotency (`--client-task-id` / `--force-new`) | 2 | prompt_source + byte count + hash, argv, model/effort, repo revision, wrapper version — not the full prompt |
| 7 | Installer hardening (`-AddToUserPath`, manifest-backed install, `-Uninstall`, `-WhatIf`/`-Plan`) | 3 | manifest also fixes "installer wipes user `/ccodex:<name>` commands" |
| 8 | `apply --check` (transactional preview) | 3 | validate the patch applies to the clean main repo before mutating |
| 9 | `review --include-untracked` | 3 | review new/untracked files, not just tracked diffs |
| 10 | Review profiles + `capabilities --json` | 3 | deterministic prompt presets; capability manifest consumed by skill/commands |

## Open — speed/stability review items (2026-07-20 assessment, user picks)

From a Claude review of which features are near-redundant or hurt speed/stability. #14 (dispatcher
registry) is the same review's top speed item but was already listed above.

| # | Item | Tier | Notes |
|---|---|---|---|
| 17 | Flip `--embed-diff` off by default in review flow docs/templates | 3 | embed-diff existed for the `CreateProcessWithLogonW 1385` sandbox-spawn quirk, lifted as of codex 0.144.1. Wrapper-side `git diff` + size-capped embedding adds latency and can truncate the diff Codex sees. Keep the flag, but make self-diff the documented default and embed-diff the fallback (rule/skill/README updates). |
| 18 | Simplify or drop `cleanup --scrub-thread-ids` | 3 | Scrubbing exists only to make old jobs non-resumable; an age check on the `resume` path achieves the same with far less destructive-path code in the largest lib module (`Cleanup.ps1`, 403 lines). Contract note: keep the flag accepted (append-only contract) even if it becomes a no-op alias for the age policy. |

## Open — delegation-quality items (2026-07-20 assessment, user picks)

From a Claude assessment of where the biggest leverage sits outside the existing items: the
consumability of Codex's output and quota economics dominate per-delegation cost/quality.

| # | Item | Tier | Notes |
|---|---|---|---|
| 20 | Fan-out concurrency cap (`max_parallel` queue for `submit`) | 3 | `submit` + `--group` encourages fan-out with no guard against launching N jobs that exhaust quota or local resources at once. A simple config-driven cap: jobs beyond the limit queue as `created` and start as slots free. Defensive; lower priority than 19. |

## Open — issues from the 2026-07-16 delegation run (user picks)

Priority order per the Codex-confirmed triage:

| # | Item | Origin | Notes |
|---|---|---|---|
| F5 | `retry_after_sec` / `rate_limit_reset_at` on quota failures (conditional) | O7 | only from explicit structured Codex evidence, never inferred from prose. **Blocked — precondition unmet (verified 2026-07-16, codex-cli 0.144.4):** `codex exec --json` emits only `thread`/`turn`/`item` events; quota surfaces solely as prose stderr (matched by `FailureClassify`'s `usage limit`/`rate limit`/`quota` phrase signatures; the bare `429` row was removed by #15, landed 2026-07-20, so quota no longer classifies via a bare `429`). No structured retry/reset field exists to source these from. Revisit only if a future Codex release emits structured rate-limit evidence. |
| F6 | Proactive quota visibility (pre-flight, e.g. via `doctor --json`) (conditional) | 2026-07-17 #11/#12 review skip | Quota only surfaces today AFTER a failed call (`failure_reason: quota_or_rate_limit`); the #11/#12 Codex review was skipped near-quota with no way to check first. If quota remaining were queryable pre-flight, policy checkpoints could skip-with-note instead of burning a failing call. **Blocked — precondition unmet (verified 2026-07-20, codex-cli 0.144.4):** neither `codex doctor --json` nor `codex login status` exposes quota/usage fields; usage data exists server-side (interactive `/status` shows limits) but has no non-interactive CLI surface. Same conditional stance as F5: never infer from prose; revisit when a Codex release exposes usage programmatically. |

## Explicitly not planned

- O3 (chained waits): user-misuse; indefinite wait and `wait --all` already cover it.
- O4 (`apply` lands worker commit): by-design and documented; optional `--stage-only` only if
  uncommitted landing is ever genuinely wanted.
- Everything under "Dropped / indefinitely deferred" in the curated backlog.
