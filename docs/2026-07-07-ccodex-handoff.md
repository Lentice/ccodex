# ccodex Agent Handoff — Read This First

> Audience: the next agent (or engineer) taking over development. This is the single entry point:
> it states where the project stands, what remains, in what order, and where every piece of
> required knowledge lives. Everything here is verifiable against git history and the docs it
> indexes. Written 2026-07-07 at commit `f8e2fe2` (plus this docs commit); working tree clean.

## 1. What ccodex is and why it exists

`ccodex` is a standalone, project-agnostic PowerShell 7 CLI that wraps non-interactive
`codex exec` so Claude can delegate work to the Codex CLI. The user's two goals:

1. **Codex as a subagent** — hand suitable self-contained work (especially large-input diff
   reviews) to Codex so the material never enters Claude's context, saving Claude tokens.
2. **Codex as a second brain (智囊)** — cross-model second opinions on plans, designs, and
   changes, with findings triaged (never adopted blindly) by Claude.

Both goals are already served by the implemented phases; the remaining phases deepen job
management, isolation, and multi-turn discussion.

## 2. Current state (all verified)

- **Complete and live-verified:** Phase 1 (`run`), Phase 2a (`submit`/`worker`/`status`/`wait`/
  `read`, CIM detached backend + startup sentinel), Phase 2a.1 (failure classification,
  `codex_thread_id` capture, `--hard-timeout-sec`), Phase 2c (`ccodex review` scoped diff review,
  `.ccodex/ccodex.json` delegation policy, installed Claude rule), Phase 3 (`/ccodex` slash
  command), Phase 2b (`cleanup`/`cancel`/`tail`/`debug`/`doctor`, per-job locks, heartbeat;
  hardened through four Codex review waves).
- **Complete, suite-verified, live smokes deferred:** Phase 4 (worktree isolation, `diff`,
  `apply`) and Phase 5 (`resume` multi-turn advisor, `thread_expired`, lineage). Implemented
  token-lean (2026-07-08): per-task TDD + full-suite green per commit, but per-task reviews,
  the composed E2E test, and live smokes are deferred — see § 4's verification backlog.
- **Test suite:** 32 files, all green (independent full run 2026-07-08 at `5e44352`; see
  dev-notes for the run recipe).
- **Live evidence:** gold-seal round-trip 2026-07-06 (submit → wait → "FINAL", thread id
  captured); real quota exhaustion 2026-07-07 correctly classified as
  `failure_reason=quota_or_rate_limit` (exit 10, do-not-retry hint honored).
- **Exit codes active:** 0, 2, 3, 4, 10, 11, 12, 20, 21, 22, 23, 24, 25 — the full contract.
  Authoritative table: design spec § "Exit Code Contract".
- **Installed copy:** `%USERPROFILE%\.local\bin\ccodex\` (byte-matched at phase completion);
  job state under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\` with an index at
  `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\index\`.

## 3. Document index

Read in this order for a full picture; consult individually as needed.

| Document | Role |
|---|---|
| `docs/2026-07-07-ccodex-handoff.md` | This file — entry point and index. |
| `docs/2026-07-03-ccodex-adapter-design.md` | **Master design spec.** Contracts (exit codes, status schema, worker prompt, backend, encoding), phase rationale, and dated amendments. The amendments are authoritative where they refine earlier sections: "Phase 2 scope amendment (2026-07-04)", "Failure-mode handling amendment (2026-07-05)", "Scoped review and delegation policy (2026-07-05)", "Retention, cleanup, and remaining-phase decisions (2026-07-07)" — the last one governs everything still to build. |
| `docs/2026-07-07-ccodex-dev-notes.md` | **Read before writing code.** Test recipes, fixtures, six regression-guarded pitfalls, host quirks (Codex sandbox 1385 → `--embed-diff`), process conventions, accepted minors. |
| `docs/2026-07-07-ccodex-phase2b-plan.md` | Executed (all 9 tasks, reviews clean). Historical record. |
| `docs/2026-07-07-ccodex-phase4-plan.md` | Executed (all 7 tasks; T3–T7 reviews deferred, T7's E2E + live smoke deferred — see § 4). |
| `docs/2026-07-07-ccodex-phase5-plan.md` | Executed (all 4 tasks; reviews deferred, T4's live smoke deferred — see § 4). |
| `README.md` | User-facing usage, quick reference, exit-code/failure-class cheat sheet, delegation config. Must be updated as part of each phase (CLAUDE.md rule). |
| `CLAUDE.md` | Repo conventions: what this repo is, testing policy (no Pester), encoding, README-per-phase rule, git/commit policy. |
| `templates/worker-prompt.md` | The worker prompt contract prepended to `run`/`submit` prompts (installed to `%APPDATA%\ccodex\templates\`). |
| `templates/claude-command-ccodex.md` | Source of the installed `/ccodex` slash command. |
| `templates/claude-rule-ccodex-delegation.md` | Source of the installed delegation-policy rule (`~/.claude/rules/ccodex-delegation.md`). |
| Executed plans: `docs/2026-07-03-...phase1-plan.md`, `docs/2026-07-04-...phase2a-plan.md`, `docs/2026-07-05-ccodex-failure-modes-plan.md`, `docs/2026-07-05-ccodex-delegation-plan.md` | Historical record of completed work. Useful as style/granularity reference for how tasks were specified and committed; not work items. |
| `.superpowers/sdd/progress.md` | Machine-local, git-ignored SDD ledger (task-by-task completion lines, review outcomes, dogfood results). If present, trust it over recollection; if absent (fresh clone), git history + this handoff are sufficient. |

## 4. Remaining work: deferred verification backlog

All planned phases (1, 2a, 2a.1, 2b, 2c, 3, 4, 5) are implemented. Phases 4 and 5 were executed
token-lean on 2026-07-08 (user directive: main features first): every task still ran TDD with a
full-suite green gate per commit, but the following verification was deliberately deferred and is
now the remaining work, in recommended order:

1. **Codex whole-branch review of Phases 4+5** (`a8f93e8..5e44352`, paths `lib/ ccodex.ps1
   tests/ templates/ README.md`, `--embed-diff`). Triage adopt-or-reject per the delegation
   policy. This substitutes for the skipped per-task reviews (P4 T3–T7, P5 T1–T4).
2. **`tests/ImplementE2E.tests.ps1`** (P4 T7 Step 1, skipped): shim-level composed chain
   submit → wait → diff → apply → cleanup, plus the conflict path (exit 25) and
   JSONL-never-on-stdout assertions. Spec is in the Phase 4 plan, Task 7.
3. **Phase 4 live smoke** (P4 T7 Step 3, skipped): real-codex implement job against a throwaway
   temp repo, then diff/apply/verify/cleanup.
4. **Phase 5 live smoke** (P5 T4 Step 2, skipped): real-codex run → resume continuity
   (SEED/CONTINUED), plus the negative scrubbed-thread resume (exit 2) against a temp state root.
5. **Dev-notes accepted-minor**: completion-evidence files not backend-scoped on the unreachable
   foreign-takeover path — revisit only if job dirs ever become shared (they did not in 4/5;
   `resume` creates a new job dir).

Deferred-item provenance: `.superpowers/sdd/progress.md` (machine-local) and the task reports
under `.superpowers/sdd/p4/`, `.superpowers/sdd/p5/`. Governing design decisions live in the
spec amendment **"Retention, cleanup, and remaining-phase decisions (2026-07-07)"**.

Step 0 (Codex second opinion on the three plans) was completed late on 2026-07-07 after quota
recovery; its findings were triaged into the plans before Phases 4/5 ran.

## 5. Non-negotiable working rules (summary — details in dev-notes and CLAUDE.md)

1. TDD per task, full suite green before every commit; exact commit messages from the plan; no
   co-author trailers; never commit `.superpowers/`.
2. Contracts are append-only: exit codes, `status.json` fields, file formats. Never rename or
   repurpose an existing field or code.
3. All wrapper-authored files UTF-8 without BOM via the `lib/JobStore.ps1` writers.
4. `ccodex.ps1` stays a plain `$args`-parsing script (no `[CmdletBinding()]`) — see dev-notes
   pitfall #1 before touching the dispatcher.
5. README updated within the phase itself; re-run `install.ps1` and byte-verify after
   user-facing changes.
6. Live codex calls only in each phase's final-task smoke; quota failure → report, never retry.

## 6. Out-of-repo artifacts to be aware of

- Installed CLI: `%USERPROFILE%\.local\bin\ccodex\` (+ `ccodex.cmd` shim on PATH).
- Installed Claude integration: `~/.claude/commands/ccodex.md`, `~/.claude/rules/ccodex-delegation.md`.
- Worker prompt template: `%APPDATA%\ccodex\templates\worker-prompt.md`.
- Job state root: `%LOCALAPPDATA%\ccodex\` (jobs + index; Phase 4 adds `worktrees\`).
- Planned (2b): user retention config at `%APPDATA%\ccodex\config.json`.
- Per-project delegation policy: `<repo>/.ccodex/ccodex.json` (this repo has one).
