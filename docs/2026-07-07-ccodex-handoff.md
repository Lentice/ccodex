# ccodex Agent Handoff — Read This First

> Audience: the next agent (or engineer) taking over development. This is the single entry point:
> it states where the project stands and where every piece of required knowledge lives.
> Everything here is verifiable against git history and the docs it indexes.
> Last updated 2026-07-16 at commit `9e911f1`; working tree clean.

## 1. What ccodex is and why it exists

`ccodex` is a standalone, project-agnostic PowerShell 7 CLI that wraps non-interactive
`codex exec` so Claude can delegate work to the Codex CLI. The user's two goals:

1. **Codex as a subagent** — hand suitable self-contained work (especially large-input diff
   reviews) to Codex so the material never enters Claude's context, saving Claude tokens.
2. **Codex as a second brain (智囊)** — cross-model second opinions on plans, designs, and
   changes, with findings triaged (never adopted blindly) by Claude.

## 2. Current state

**All planned phases (1, 2a, 2a.1, 2b, 2c, 3, 4, 5) are implemented and verified** — including
the verification backlog once deferred from the token-lean Phase 4/5 execution (whole-branch
Codex reviews, the composed `ImplementE2E` test, and both live smokes; completed 2026-07-08).
The project is in **maintenance / incremental-feature mode**; open work is tracked exclusively
in `docs/BACKLOG.md`.

Capability summary (full per-command reference: `docs/2026-07-08-ccodex-reference.md`):

- **Core:** `run` (sync), `submit`/`worker`/`status`/`wait`/`read` (async, CIM detached backend
  with startup sentinel), failure classification (`failure_reason`), `codex_thread_id` capture,
  `--hard-timeout-sec`, and exit-0 top-level/per-command `help`/`--help`/`-h`.
- **Job management:** `cleanup` (with `--scrub-thread-ids`), `cancel`, `tail`, `debug`,
  `doctor`, per-job locks, heartbeat, `list`.
- **Review + delegation:** `ccodex review` scoped diff review (`--embed-diff` recommended),
  `.ccodex/ccodex.json` delegation policy, installed Claude rule/skill/commands.
- **Worktree isolation:** `run --mode implement` in a detached worktree, `diff`, `apply`
  (conflict → exit 25, main repo untouched), plus overlap-safe `apply --allow-untracked`.
- **Multi-turn:** `resume <job_id>` (sync) and `submit --resume <job_id>` (async follow-up),
  always a brand-new child job with `parent_job_id` lineage; implement parents continue in a
  distinct snapshot-seeded worktree with cumulative diff/apply; `thread_expired` handling.
- **Machine-readable output:** stable `schema_version: 1` lifecycle envelope via `--json` on
  `status`/`read`/`wait`/`doctor`; `wait --all` batch waiting with `--group`/`--label` job
  metadata for fan-out/gather; structured `status.json.failure` signal (`matched_signal`,
  `source`, `confidence`, `http_code`).
- **Passthrough knobs:** `--model`, `--effort` (eight-value enum `none..ultra` since Codex CLI
  0.144.1) on `run`/`submit`/`review`/`resume`.

Milestones after the phase completions (see git log for the full list):

- **2026-07-08 feature wave:** hidden Codex console windows on Windows; README split into
  user-facing README + developer reference; per-function `/ccodex:<name>` Claude commands.
- **2026-07-13 Codex CLI 0.144.1 upgrade:** invocation contract re-verified live; `--effort`
  enum expanded; host fact — the Codex sandbox spawns child processes again on this machine
  (the `CreateProcessWithLogonW failed: 1385` restriction no longer reproduces), so review's
  self-diff form works, though `--embed-diff` stays the robust recommendation. Future upgrades
  follow the `codex-upgrade-check` skill (`.claude/skills/codex-upgrade-check/SKILL.md`).
- **2026-07-14 hardening wave:** latency diagnosability + silent `--prompt-file` drop fix;
  locking/install/cleanup/review/codex-invoke hardening; deferred-review-finding fixes across
  `resume`/`apply`/`wait`/`cancel`/`doctor`/`cleanup`/install; test false-green corrections;
  read-only review enforcement + installer ghost-command cleanup (`6ca18e1..078958c`).
- **2026-07-15/16 feature wave (backlog items 1–5, all landed):** `list` command,
  `--json` envelope on `status`/`read`/`wait`, `wait --all` + group/label metadata,
  `submit --resume`, structured failure signal + `doctor --json` (`e029b99..22800dd`).
- **Living backlog established (`9e911f1`):** `docs/BACKLOG.md` is now the single "what is
  left" document, fed by the curated refinement backlog and the 2026-07-16 delegation-run
  issue record.

Operational facts:

- **Test suite:** plain PowerShell assertion scripts under `tests/`, all green (full suite is
  the completion gate). Run `tests/run-tests.ps1` (quick) / `-Suite full`.
- **Exit codes active:** 0, 2, 3, 4, 10, 11, 12, 20, 21, 22, 23, 24, 25 — the full contract.
  Authoritative table: design spec § "Exit Code Contract".
- **Installed copy:** `%USERPROFILE%\.local\bin\ccodex\` (must byte-match the repo after
  user-facing changes); job state under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\` with
  an index at `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\index\`.
- **Live evidence:** gold-seal round-trip 2026-07-06; real quota exhaustion 2026-07-07
  correctly classified (`failure_reason=quota_or_rate_limit`, exit 10); Phase 4/5 live smokes
  passed 2026-07-08; 0.144.1 live re-verification 2026-07-13.

## 3. Document index

| Document | Role |
|---|---|
| `docs/2026-07-07-ccodex-handoff.md` | This file — entry point and index. |
| `docs/BACKLOG.md` | **What is left to do.** Living list of open items; update it whenever an item lands, is added, or is dropped. |
| `docs/2026-07-03-ccodex-adapter-design.md` | **Master design spec.** Binding contracts (exit codes, status schema, worker prompt, backend, encoding) and dated amendments — amendments are authoritative where they refine earlier sections. |
| `docs/2026-07-07-ccodex-dev-notes.md` | **Read before writing code.** Test recipes, fixtures, regression-guarded pitfalls, host quirks, process conventions, accepted minors. |
| `docs/2026-07-08-ccodex-reference.md` | Developer-facing technical reference: full per-command/flag reference, exit-code and failure-class contracts, `status.json` field notes, repo/module layout. |
| `docs/2026-07-15-ccodex-refinement-backlog-curated.md` | Source analysis behind BACKLOG.md's curated items (rationale, tiers, dropped items). |
| `docs/2026-07-16-ccodex-delegation-run-issues.md` | Issue record from the 2026-07-16 delegation run; source of BACKLOG.md's F-items. |
| `.claude/skills/codex-upgrade-check/SKILL.md` | Checklist to run whenever the installed Codex CLI is upgraded. |
| `README.md` | User-facing readme: purpose, features, install, concise usage, cheat sheet. Must be updated with every user-visible change. |
| `AGENTS.md` / `CLAUDE.md` | Repo conventions: doc map, testing policy (no Pester), encoding, doc-maintenance rule, git/commit policy. |
| `templates/worker-prompt.md` | Worker prompt contract prepended to `run`/`submit` prompts (installed to `%APPDATA%\ccodex\templates\`). |
| `templates/claude-command-ccodex.md`, `templates/claude-commands/*.md`, `templates/claude-skill-ccodex.md`, `templates/claude-rule-ccodex-delegation.md` | Sources of the installed Claude integration (slash commands, skill, delegation rule). Keep in sync with behavior changes. |
| `docs/archive/*.md` | Executed phase plans (1, 2a, failure-modes, delegation, 2b, 4, 5). Historical record; style/granularity reference only, not work items. |
| `.superpowers/sdd/progress.md` | Machine-local, git-ignored SDD ledger. If present, trust it over recollection; if absent (fresh clone), git history + this handoff are sufficient. |

## 4. Remaining work

See `docs/BACKLOG.md` — the single living list. As of 2026-07-16: five curated items open
(provenance/idempotency, installer hardening, `apply --check`, `review --include-untracked`,
review profiles + `capabilities --json`) and one blocked delegation-run item (F5 quota retry
hints). F1, F2, F3, and F4 are complete. The user picks; the agent specs and implements.

Standing accepted-minor (dev-notes): completion-evidence files not backend-scoped on the
currently unreachable foreign-takeover path — revisit only if job dirs ever become shared
between workers.

## 5. Non-negotiable working rules (summary — details in dev-notes and AGENTS.md)

1. TDD per task, full suite green before every commit; no co-author trailers; never commit
   `.superpowers/`.
2. Contracts are append-only: exit codes, `status.json` fields, file formats. Never rename or
   repurpose an existing field or code.
3. All wrapper-authored files UTF-8 without BOM via the `lib/JobStore.ps1` writers.
4. `ccodex.ps1` stays a plain `$args`-parsing script (no `[CmdletBinding()]`) — see dev-notes
   pitfall #1 before touching the dispatcher.
5. Docs (README, reference, templates) updated within the same piece of work; re-run
   `install.ps1` and byte-verify the installed copies after user-facing or template changes.
6. Live codex calls are the exception, not the loop; quota failure → report, never retry.
7. Keep `docs/BACKLOG.md` current in the same commit that lands, adds, or drops an item.

## 6. Out-of-repo artifacts to be aware of

- Installed CLI: `%USERPROFILE%\.local\bin\ccodex\` (+ `ccodex.cmd` shim on PATH).
- Installed Claude integration: `~/.claude/commands/ccodex.md` + `~/.claude/commands/ccodex/`
  per-function commands, `~/.claude/skills/ccodex/SKILL.md`,
  `~/.claude/rules/ccodex-delegation.md`.
- Worker prompt template: `%APPDATA%\ccodex\templates\worker-prompt.md`.
- Job state root: `%LOCALAPPDATA%\ccodex\` (jobs + index + `worktrees\`).
- User retention config: `%APPDATA%\ccodex\config.json` (optional).
- Per-project delegation policy: `<repo>/.ccodex/ccodex.json` (optional; this repo currently
  has none, so the documented defaults apply).
