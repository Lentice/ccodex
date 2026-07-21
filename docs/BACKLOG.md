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
| 21. 0-byte `result.md` → exit 11 (null-coalesce) not a crash | 22972f6 |
| 22. `retention.jobs_days >= 1` per-field guard (blocks cleanup wiping all jobs) | 1d4d941 |
| 23. Run-path transactional worktree teardown on init failure (matches resume) | f48cdcb |
| 24. PID-reuse-safe launch liveness + terminalize launch-failed/dead orphans | e0e7459 |
| 33. Review-neutrality hardening: prompt frames stated intent as context-not-evidence (ReviewPrompt `$instructions` + worker-prompt review section); neutral-intent guidance in rule/reference | landed 2026-07-21 |

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

## Open — maintenance/hardening review (2026-07-21 assessment, user picks)

From a 5-way parallel Claude review of the whole tool (dispatcher/invocation, async lifecycle,
failure-classify/review output, worktree/resume/apply, cleanup/config/install), curated to the
important stability/perf/maintainability items and second-opinioned with Codex (`brainstorm`,
triaged — adopted/refined below). Nitpicks and already-tracked items dropped. Priority order is
the Codex-confirmed one.

**Cross-cutting theme — lifecycle hardening (21, 23, 24, 25):** every state transition must end in
either a terminal `status.json` or deterministic cleanup; retry alone is insufficient if the final
status write can still fail. Cover each boundary with fault-injection tests (worktree created then
prompt/status write fails; atomic move fails transiently then succeeds, then permanently; worker
dies before `running`; worker dies after `running` with no completion evidence).

Items 21–24 (Tier 1) landed 2026-07-21 — see the Done table above.

| # | Item | Tier | Notes |
|---|---|---|---|
| 25 | Atomic status writer has no retry on transient Windows sharing violations | 2 | `lib/JobStore.ps1:14-19` — `Write-CcodexJsonFileAtomic`'s `Move-Item -Force` has no retry, while readers (`Read-CcodexStatusFile`; `Get-CcodexJobList` reads every job's status.json in a loop for `list`/`wait --all`) already retry 3× for the same mid-rename window. A reader holding the file open at the instant of the move → sharing violation → `Start-CcodexWorkerRunning` (Worker.ps1:196, no catch) kills the detached worker unhandled → orphaned job stuck at `created`. Fix: bounded retry-on-IOException around the move (mirror the reader), best-effort remove the temp file on final failure. |
| 26 | Failure classifier can false-positive quota/network/auth on a failed `review` job | 2 | `lib/FailureClassify.ps1:99-120` pools stderr + every `codex-events.jsonl` line containing "error" into one blob, returning the first table-row token found anywhere. A review job's events log carries Codex's own review prose ("error handling", "on error"…), so an unrelated failure can emit `quota_or_rate_limit` (confidence high) and outrank a genuine stderr `sandbox`/`permission` signal. Fix: make **source precedence explicit** — stderr first; consult event payloads only when stderr has no match, and only for documented failure/error event *types* (match the `type` field, not substring "error"). Must not re-add dropped bare-token signatures (#15). |
| 27 | `git am --abort` failure can wedge future applies to the same main repo | 2 | `ccodex.ps1:1987` — abort is best-effort (`Out-Null`, exit ignored) then `reset --hard`, which does **not** clear `.git/rebase-apply`. If abort itself fails, the next `ccodex apply` to that repo errors "operation in progress" → exit 25 until a manual `git am --abort`. Fix: verify no am/rebase state remains before reporting "main repo restored" (fold into `Get-CcodexApplyRestoreState`); fallback `git am --quit` + reset + a clear manual-recovery message. Do not delete git admin state directly. |
| 28 | Sync `run` writes full prompt to stdin before arming stdout/stderr readers — latent deadlock | 2 | `lib/CodexInvoke.ps1:175-198` — `StandardInput.Write`+`Close` then `ReadToEndAsync`/`ReadLineAsync`. `review --embed-diff` sends up to a 100 KB diff (ReviewPrompt.ps1:152) through this path. Does not trigger today (codex drains stdin to EOF before emitting much) but is an undocumented invariant a future Codex / chattier stderr could break (hang → exit-24 at best). Fix: push the stdin write onto a background task while the main loop continuously drains both pipes (one pre-armed `ReadLineAsync` is not enough); propagate writer failure; close stdin deterministically. Prove with a fake process that emits substantial output before draining stdin. |
| 29 | Usage-error + input-bound consistency bundle | 2 | Three asymmetries: (a) `cleanup --repo <bad path>` → exit 12 not 2 (Cleanup.ps1:113 via Paths.ps1 `Resolve-Path` throw; run/review/doctor already map bad `--repo` to exit 2); (b) `--hard-timeout-sec` huge value → `sec*1000` overflows `[int]` → exit 12 not 2 (ccodex.ps1:412 / ConvertTo-CcodexHardTimeoutSec:2808) — reject above `[int]::MaxValue/1000`; (c) `Config.ps1:50-63` delegation int knobs accept negative/fractional silently while UserConfig validates strictly — use the same whole-number/range discipline with per-field minimums. |
| 30 | Findings parser silently drops a single-object / all-malformed `items` | 2 | `lib/ReviewFindings.ps1:103` — `-is [Array]` is false when a model emits `"items": {..}` (single object) → foreach skipped → **non-null** `{verdict, items:[]}` → caller sees "clean review", never falls back to prose (silent loss of a real finding). Fix: when `items` is present but not an array, return `$null` so prose fallback fires (do not silently wrap-and-accept a protocol violation). Also return `$null` when a non-empty supplied array normalizes to zero valid findings (an all-malformed array looks clean too); a genuinely empty `[]` stays a clean result. |
| 31 | Simplify `lib/Cleanup.ps1` `$script:__ccx*` accumulator (opportunistic) | 3 | Cleanup.ps1:227-235,378-385 route 7 counters through module-level `$script:` aliases with 3 nested functions redefined per call — the least-obvious control flow in the largest module. Correct today (no production failure), so **not** a standalone rewrite: pass one mutable accumulator object (hashtable) into ordinary non-nested helpers the next time a cleanup fix/feature touches this file. |
| 32 | Extract inline dispatch handlers from `ccodex.ps1` (opportunistic) | 3 | `ccodex.ps1` is 3801 lines; all ~15 `Invoke-Ccodex*Dispatch` bodies live inline (ccodex.ps1:2900-3728), against the "lib/*.ps1 single-responsibility, dot-sourceable" convention, and run/submit/resume/review parse blocks are ~70 lines each and near-duplicated. Codex triage: **do not** schedule a bulk move (high-risk in a mature CLI). Extract one handler, or the shared model/effort/group/label/timeout parser, when the next feature touches it; keep the public parsing/error-precedence tests intact. |

## Explicitly not planned

- O3 (chained waits): user-misuse; indefinite wait and `wait --all` already cover it.
- O4 (`apply` lands worker commit): by-design and documented; optional `--stage-only` only if
  uncommitted landing is ever genuinely wanted.
- Input-layer soft warning on leading/conclusory `--intent`/`--focus` phrasing (considered with #33,
  declined 2026-07-21, Codex-confirmed): a string-match heuristic for "already fine"-style wording is
  brittle, language-dependent (English + zh-TW + …), false-positive-prone, and cuts against the
  "don't be too clever" ethos. Redundant once the review prompt is neutral by construction (#33),
  which defends regardless of how intent is phrased — fixing at the input layer a bias the prompt
  layer is already immune to has low marginal value.
- Everything under "Dropped / indefinitely deferred" in the curated backlog.
