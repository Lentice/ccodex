# ccodex

A thin, user-level PowerShell CLI that lets an AI coding assistant (e.g. Claude Code) delegate
review, brainstorming, testing, and implementation tasks to [Codex CLI](https://github.com/openai/codex)
as an external subagent — without a daemon, an MCP server, or tmux.

`ccodex` normalizes a task prompt into a job directory, invokes `codex exec` non-interactively,
captures its raw output, and hands back only the clean final result, so the calling agent can
treat it like any other command it shells out to.

```powershell
# From Claude Code (the main way) — Claude scopes the diff, runs Codex, triages the findings:
#   /ccodex:review --staged
# The CLI primitive underneath:
"Review this diff for correctness issues." | ccodex run --mode review
```

## Why ccodex exists

Two goals:

1. **Save the primary agent's tokens.** Self-contained work — especially reviewing a large diff —
   can be handed to Codex entirely, so the diff and Codex's back-and-forth never enter the calling
   agent's own context.
2. **A cross-model second opinion.** Codex reviews plans, designs, and changes as an independent
   model. Its findings are meant to be triaged, not adopted blindly — the calling agent stays the
   one deciding what to act on.

## Key features

- **Scoped code review** (`ccodex review`) over a git diff range, the staged index, or the working
  tree — severity-ordered findings, not a free-form answer.
- **Synchronous or async execution**: `run` blocks for an answer now; `submit` hands the job to a
  detached background worker and returns immediately, with `status`/`wait`/`read` to check in
  later from any directory.
- **Worktree-isolated implementation** (`--mode implement`): Codex's edits land in an isolated git
  worktree, never your working tree, until you explicitly review and `apply` them.
- **Multi-turn follow-up** (`ccodex resume`): continue the same Codex session for a clarifying
  question or pushback, instead of starting from scratch.
- **Debuggable by default**: every job leaves `prompt.md`, `status.json`, raw event/stderr logs,
  and the final result behind under a global state root.
- **Job lifecycle management**: `cancel`, `tail`, `debug`, `cleanup` (with retention + stale
  Codex-session scrubbing), and `doctor` for diagnosing environment-shaped failures.
- **Global, not per-project**: install once, call `ccodex` from any repo's `PATH` without adding
  anything to that repo (an optional per-project delegation policy is available if you want it).

## Installation

Requirements:

- Windows (the native backend uses `Win32_Process` and Windows user-profile paths)
- PowerShell 7+
- [Codex CLI](https://github.com/openai/codex) installed, on `PATH`, and authenticated
  (`codex login`)
- Git (used for project-root resolution and the `review`/`implement` flows)

```powershell
git clone <this repo> D:\Documents\GitHub\ccodex
D:\Documents\GitHub\ccodex\install.ps1
```

`install.ps1` copies `ccodex.ps1` + `lib/` to `%USERPROFILE%\.local\bin\ccodex\` and writes a
`ccodex.cmd` shim there, so add `%USERPROFILE%\.local\bin` to your user `PATH` if it isn't already
(the script warns if it's missing). It also installs:

- the default worker-prompt template to `%APPDATA%\ccodex\templates\worker-prompt.md`
- the `ccodex` Claude Code agent skill to `%USERPROFILE%\.claude\skills\ccodex\SKILL.md`
- the `/ccodex` command plus the per-function `/ccodex:<name>` commands to
  `%USERPROFILE%\.claude\commands\`
- the delegation policy rule to `%USERPROFILE%\.claude\rules\ccodex-delegation.md`

Pass `-InstallDir`/`-TemplatesDir`/`-ClaudeDir` to override any of these locations.

## Using ccodex from Claude Code (the main way)

You normally never type `ccodex` yourself — Claude Code does. The installer wires three layers
into Claude, and after a restart of the session they're all active:

- **The `ccodex` skill** — Claude discovers on its own when a task is worth delegating (a big
  diff review, a second opinion, a long background job) and drives the CLI correctly, including
  exit-code/failure reactions and triage of Codex's findings.
- **Slash commands** — you invoke a specific ccodex function on demand:

  | Command | What it does |
  | --- | --- |
  | `/ccodex:review [--staged\|--working\|--range a..b] [--background]` | Scoped Codex code review of your current changes; findings come back triaged (adopted vs rejected), not pasted raw. |
  | `/ccodex:ask [--background] <question>` | Second opinion / brainstorm from a different model — plans, designs, or "I'm stuck" debugging. |
  | `/ccodex:implement [--background] <task>` | Delegate an edit to Codex in an isolated git worktree; Claude reviews `ccodex diff` with you before anything is applied. |
  | `/ccodex:resume <job_id> [follow-up]` | Continue the same Codex session — answer its clarifying question or push back on a finding. |
  | `/ccodex:jobs [job_id] [action]` | Check on / collect / cancel background jobs. |
  | `/ccodex:doctor` | Health-check Codex + ccodex when failures look environmental (auth, quota, sandbox). |
  | `/ccodex:cleanup [--older-than 7d]` | Preview-then-delete aged job state; optionally scrub stale Codex session ids. |
  | `/ccodex <task>` | The general dispatcher when you don't care which function fits. |

  `--background` on `review`/`ask`/`implement` submits the work as a detached background job so
  Claude keeps working while Codex runs; collect later via `/ccodex:jobs`.

- **The delegation rule** — with a `.ccodex/ccodex.json` in your project (see
  [Delegation policy](#delegation-policy-ccodexccodexjson)), every Claude session automatically
  offers (or runs) a scoped Codex review after changes and a second opinion after plans, within
  the cost guards you set. No per-session prompting needed.

Typical day-to-day: finish a feature → `/ccodex:review --staged` → Claude scopes the diff, runs
the review, verifies each finding against the code, and reports what it adopted vs rejected.

## Direct CLI usage

Everything the slash commands do is plain CLI underneath — useful for scripts, other agents, or
poking at it by hand. The essential flows — full flag reference, exit-code contract, and file
formats are in [`docs/2026-07-08-ccodex-reference.md`](docs/2026-07-08-ccodex-reference.md).

**Scoped review of a diff.** Use `--embed-diff` so the wrapper generates and embeds the diff
itself; it's the reliable form on hosts where Codex's own sandbox can't spawn `git diff`
(signature: `CreateProcessWithLogonW failed: 1385`).

```powershell
ccodex review --range <base>..HEAD --path lib/ --intent "Add retry logic to CodexInvoke" --embed-diff
```

**Brainstorm / second opinion**, synchronous:

```powershell
"What are the trade-offs of X vs Y?" | ccodex run --mode brainstorm
```

**Async: submit, then check in later** (long tasks, or several running in parallel):

```powershell
"Run the full test suite and report failures." | ccodex submit --mode test --access workspace
# -> <job_id>
#    <job_dir>

ccodex status <job_id>   # non-blocking lifecycle check
ccodex wait <job_id>      # blocks until terminal, then prints the result
ccodex read <job_id>      # non-blocking result read
```

**Delegated implementation**, isolated in a worktree until you explicitly land it:

```powershell
"Add input validation to the signup form." | ccodex run --mode implement --repo D:\some\repo
ccodex diff <job_id>     # ALWAYS review before applying — never auto-apply
ccodex apply <job_id>    # lands the worker's snapshot commit onto the main repo
```

**Continue a discussion** with the same Codex session instead of starting a fresh, memory-less
`run` — e.g. when Codex's last answer was a clarifying question:

```powershell
"Now say CONTINUED instead." | ccodex resume <job_id>
```

**Pick a model or effort per call** (optional; omit both to use Codex's configured defaults) —
`run`, `submit`, `review`, and `resume` all take `--model <model>` and
`--effort <none|minimal|low|medium|high|xhigh|max|ultra>` (not every model supports every
effort; Codex rejects unsupported combinations):

```powershell
"Deep design review of this plan." | ccodex run --mode brainstorm --model gpt-5.6-terra --effort xhigh
```

**Cleanup**, periodically or when reclaiming disk:

```powershell
ccodex cleanup --dry-run                             # preview only
ccodex cleanup --older-than 7d --scrub-thread-ids    # delete aged jobs + blank old session ids
```

## Other key points

### Exit codes

The full contract (including `12`/`21`/`22`/`23`) is in the
[reference doc](docs/2026-07-08-ccodex-reference.md#exit-codes). The ones you'll hit most:

| Code | Meaning |
| ---- | ------- |
| `0`  | Success. |
| `2`  | Usage/validation error. |
| `3`  | Job id not found. |
| `4`  | Job not finished yet (`read`). |
| `10` | `codex exec` itself failed. |
| `11` | Empty result. |
| `20` | `wait` timed out (job is unaffected — re-run `wait`). |
| `24` | Hit `--hard-timeout-sec`; process tree killed. |
| `25` | `apply` conflicted; main repo restored, untouched. |

### Failure reasons

On a failed job, `status.json.failure_reason` hints the reaction: `quota_or_rate_limit` → report
it, never retry · `auth` → run `codex login` · `permission_or_sandbox` → try `--access workspace`
or narrow the task · `network` → one retry is safe · `thread_expired` (`resume` only) → start a
fresh `run`. When it's unclear, run `ccodex doctor` before retrying anything.

### Delegation policy (`.ccodex/ccodex.json`)

A project can opt into automatic review checkpoints for any Claude Code session working in it:

```json
{
  "delegation": {
    "review_after_changes": "ask",
    "review_min_changed_lines": 50,
    "review_default_paths": [],
    "plan_second_opinion": "ask",
    "max_codex_calls_per_task": 2
  }
}
```

`review_after_changes`/`plan_second_opinion` are each `"auto"` (run automatically), `"ask"`
(offer it), or `"off"` (only on explicit request); `review_min_changed_lines` and
`max_codex_calls_per_task` are cost guards. The file, section, and every key are optional and fall
back to the defaults above; the installed `~/.claude/rules/ccodex-delegation.md` rule teaches any
session how to apply them. Full key reference:
[reference doc](docs/2026-07-08-ccodex-reference.md#delegation-policy).

### Where job state lives

Every job's artifacts (`prompt.md`, `status.json`, raw logs, `result.md`, ...) live under
`%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`, with an index at
`%LOCALAPPDATA%\ccodex\index\<job_id>.json` so `status`/`wait`/`read` can find a job from any
directory. `--mode implement` worktrees live under `%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`.
Field-by-field `status.json` notes:
[reference doc](docs/2026-07-08-ccodex-reference.md#job-artifacts-and-status-fields).

## Status

All planned phases (synchronous CLI, async jobs, the Claude slash command, scoped review +
delegation policy, job management, worktree-isolated implementation, and multi-turn `resume`) are
implemented and tested. See
[`docs/2026-07-07-ccodex-handoff.md`](docs/2026-07-07-ccodex-handoff.md) for current development
state and [`docs/2026-07-08-ccodex-reference.md`](docs/2026-07-08-ccodex-reference.md) for the
full technical reference, roadmap, and repository layout.
