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
  command).
- **Test suite:** 23 files / 601 assertions, all green (see dev-notes for the run recipe).
- **Live evidence:** gold-seal round-trip 2026-07-06 (submit → wait → "FINAL", thread id
  captured); real quota exhaustion 2026-07-07 correctly classified as
  `failure_reason=quota_or_rate_limit` (exit 10, do-not-retry hint honored).
- **Exit codes active:** 0, 2, 3, 4, 10, 11, 12, 20, 23, 24. Reserved by design for pending
  phases: 21 (lock timeout, 2b), 22 (cancelled, 2b), 25 (apply conflict, Phase 4). Authoritative
  table: design spec § "Exit Code Contract".
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
| `docs/2026-07-07-ccodex-phase2b-plan.md` | **NEXT TO IMPLEMENT.** 9 tasks: retention config, per-job locks, `cleanup` (incl. `--scrub-thread-ids`), `cancel`, heartbeat/health, `tail`, `debug`, `doctor`, docs+smokes. |
| `docs/2026-07-07-ccodex-phase4-plan.md` | Pending. 7 tasks: worktree isolation for edit-capable workers, snapshot finalization, `diff`, `apply` (exit 25), cleanup integration, E2E. Requires 2b. |
| `docs/2026-07-07-ccodex-phase5-plan.md` | Pending. 4 tasks: `resume` multi-turn advisor on `codex exec resume`, `thread_expired` class, lineage in status, guidance. Requires 2b; independent of Phase 4. |
| `README.md` | User-facing usage, quick reference, exit-code/failure-class cheat sheet, delegation config. Must be updated as part of each phase (CLAUDE.md rule). |
| `CLAUDE.md` | Repo conventions: what this repo is, testing policy (no Pester), encoding, README-per-phase rule, git/commit policy. |
| `templates/worker-prompt.md` | The worker prompt contract prepended to `run`/`submit` prompts (installed to `%APPDATA%\ccodex\templates\`). |
| `templates/claude-command-ccodex.md` | Source of the installed `/ccodex` slash command. |
| `templates/claude-rule-ccodex-delegation.md` | Source of the installed delegation-policy rule (`~/.claude/rules/ccodex-delegation.md`). |
| Executed plans: `docs/2026-07-03-...phase1-plan.md`, `docs/2026-07-04-...phase2a-plan.md`, `docs/2026-07-05-ccodex-failure-modes-plan.md`, `docs/2026-07-05-ccodex-delegation-plan.md` | Historical record of completed work. Useful as style/granularity reference for how tasks were specified and committed; not work items. |
| `.superpowers/sdd/progress.md` | Machine-local, git-ignored SDD ledger (task-by-task completion lines, review outcomes, dogfood results). If present, trust it over recollection; if absent (fresh clone), git history + this handoff are sufficient. |

## 4. Remaining work and execution order

**Order: Phase 2b → Phase 4 → Phase 5.** Phases 4 and 5 are independent of each other; both
require 2b (4 needs cleanup's worktree sweep and lock infrastructure; 5's resume-ability ends at
cleanup's thread-id scrub). Each plan is handoff-complete: exact file paths, function signatures,
test scenarios, and commit messages per task — follow them with
superpowers:subagent-driven-development (or equivalent task-by-task TDD execution), checking off
checkboxes as you go.

| Phase | Plan | Scope in one line |
|---|---|---|
| 2b (9 tasks) | `2026-07-07-ccodex-phase2b-plan.md` | Job management: user retention config (`%APPDATA%\ccodex\config.json`), per-job locks (exit 21), `cleanup` with stale-job deletion and `--scrub-thread-ids` (the user-required stale-data purge), `cancel` (exit 22), worker heartbeat + derived health, `tail`, `debug`, `doctor`. |
| 4 (7 tasks) | `2026-07-07-ccodex-phase4-plan.md` | Worktree isolation: `--mode implement` workers run in a detached worktree under the state root, output snapshot-committed; `ccodex diff` / `ccodex apply` (conflict → exit 25, main repo untouched). |
| 5 (4 tasks) | `2026-07-07-ccodex-phase5-plan.md` | Multi-turn advisor: `<follow-up> \| ccodex resume <job_id>` continues the parent job's Codex session as a new job with lineage; new `thread_expired` failure class. |

Governing design decisions for all three live in the spec amendment
**"Retention, cleanup, and remaining-phase decisions (2026-07-07)"** — if a plan detail ever
seems ambiguous, that section plus the plan's own Global Constraints resolve it.

### Step 0 before implementing (deferred item)

Per the delegation policy, the three plans were to get a Codex second opinion, but the attempt on
2026-07-07 hit live quota exhaustion (correctly classified; do-not-retry honored). When Codex
quota is available again, run it first and triage the findings into the plans before starting
Task 1:

```powershell
ccodex review --range e7abfc2..HEAD --path docs/ --intent "second opinion on phase 2b/4/5 implementation plans and handoff docs" --embed-diff
```

(`e7abfc2` = last commit before the planning docs. Use `--embed-diff` — mandatory on this host,
see dev-notes.) If it fails again with `quota_or_rate_limit`, note it and proceed; the plans are
self-consistent without it.

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
