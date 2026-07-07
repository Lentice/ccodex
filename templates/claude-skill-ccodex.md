---
name: ccodex
description: Delegate work to the Codex CLI through the ccodex wrapper - scoped code reviews (specific paths, commit ranges, or submodules), second opinions on plans and designs, brainstorming, and long-running background jobs. Use when the user mentions ccodex or asks for a Codex review/opinion, when a repo's .ccodex/ccodex.json delegation policy calls for a post-change or post-plan review, or when a large diff should be reviewed without loading it into your own context.
---

# ccodex — delegate work to the Codex CLI

`ccodex` is a PowerShell 7 CLI that wraps non-interactive `codex exec`. It turns Codex into a
shell-callable subagent: you hand it a prompt (optionally with an embedded, scoped git diff), it
runs Codex sandboxed against a repo, and it returns the final answer on stdout with a stable exit
code. The large inputs (diffs, whole files) go to Codex — only the result enters your context.

## When to use

- **Scoped code review** after you finish a feature or fix — a specific `--path`, commit
  `--range`, or a single submodule (things whole-repo review plugins cannot scope).
- **Second opinion** on a plan, spec, or design from a different model. Cross-model review
  regularly catches issues same-model review misses.
- **Brainstorming** an approach or debugging hypothesis with an independent perspective.
- **Long-running analysis** you want out-of-band (`submit` … `wait`) while you keep working.

Hard rules (follow these exactly):

1. Never delegate generative work (writing code, plans, prose). Only review/opinion/analysis.
2. Never adopt a Codex finding without first verifying it against the actual code. For each
   finding, either adopt it (and act on it) or reject it with a stated reason; report both lists.
3. Codex review is additive — still run your own tests and do your own self-review.
4. Never call `ccodex worker` (internal). Never retry after a quota failure.
5. Trust exit codes plus `status.json`; never parse stderr prose for success/failure.

## Availability check (do this first in a new environment)

1. Run `ccodex help`. It exits **2** — that is EXPECTED here (discovery, not an error) — and
   prints a line like `ccodex: command 'help' is not implemented. Supported commands: run,
   review, submit, ...`. That list is ground truth for what this installation can do — never
   call a command that is not in it.
2. If `ccodex` is not on PATH: ask the user for the ccodex repo location (or to clone it), then
   run `pwsh -File <repo>\install.ps1` and ensure `%USERPROFILE%\.local\bin` is on the user
   PATH. The installer also installs this skill, the `/ccodex` command, and the delegation rule.
3. Codex CLI itself must be installed and authenticated. If a call fails with
   `failure_reason: auth`, tell the user to run `codex login`; do not retry.
4. If `doctor` is in the supported list, `ccodex doctor` is the one-shot health check
   (`--no-smoke` skips the live Codex call).

Commands appear in the supported list as their phase is installed:

| Commands | Feature set |
|---|---|
| `run`, `review`, `submit`, `status`, `wait`, `read` | core (always present) |
| `cleanup`, `cancel`, `tail`, `debug`, `doctor` | job management (Phase 2b) |
| `diff`, `apply` (+ `run --mode implement`) | worktree isolation (Phase 4) |
| `resume` | multi-turn sessions (Phase 5) |

## Core usage

Prompts are piped on stdin (preferred), or passed via `--prompt-file <path>` or as a positional
argument. Default mode is read-only advisory.

```powershell
# Second opinion / brainstorm (synchronous; result on stdout)
"Evaluate this plan: ..." | ccodex run --mode brainstorm --repo <repo>

# Scoped code review of a commit range - the reliable form embeds the diff itself
ccodex review --range <base>..HEAD --path src/feature --intent "one-line change intent" --embed-diff

# Review staged / working-tree changes instead of a range
ccodex review --staged --path src --embed-diff
ccodex review --working --path src --embed-diff

# Review inside a submodule (scope ccodex at the submodule, not the superproject)
ccodex review --repo <submodule-path> --range <base>..HEAD --path . --intent "..." --embed-diff

# Long-running: fire, keep working, collect later
"Audit error handling across src/" | ccodex submit --repo <repo>   # prints <job_id>
ccodex wait <job_id> --wait-timeout-sec 600                        # blocks; exit 20 = still running
ccodex read <job_id>                                               # print result again anytime
ccodex status <job_id>                                             # one-line state

# Runaway guard for any run/submit
"..." | ccodex run --hard-timeout-sec 900 --repo <repo>
```

Notes:
- Prefer `--embed-diff` for reviews: the wrapper runs `git diff` and embeds a size-capped diff in
  the prompt. On some hosts Codex's sandbox cannot spawn processes (signature:
  `CreateProcessWithLogonW failed: 1385`), so asking Codex to run git itself fails; embed-diff is
  immune to that.
- `--access workspace` grants write access inside the target repo (e.g. test runs that produce
  artifacts); default is read-only. Review/brainstorm modes stay read-only.
- Job artifacts live under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`; `status.json` there
  is the durable source of truth (`failure_reason`, `codex_thread_id`, exit codes).

## Standard post-change review recipe (the most common flow)

Follow these steps literally after finishing a feature or fix:

1. Determine BASE = the commit your change started from (record `git rev-parse HEAD` before you
   begin work, or use `git merge-base HEAD <original-branch>` afterwards).
2. Run `git diff --stat BASE..HEAD` and pick 1–3 `--path` values (directories or files) that
   cover everything you touched.
3. Run:
   `ccodex review --repo <repo-or-submodule-root> --range BASE..HEAD --path <p1> [--path <p2>] --intent "<one line: what the change does>" --embed-diff`
4. If exit code is 0: stdout is the review. For every finding, open the cited code and check it
   yourself; adopt (and fix) or reject (with a reason). Summarize adopted vs rejected in your
   final report — never present Codex's raw output as your own conclusion.
5. If exit code is nonzero: look it up in the table below, do the stated reaction, and continue
   your task. A failed or skipped review never blocks the task itself.

## Job management (if `cleanup`/`cancel`/`tail`/`debug` are supported)

```powershell
ccodex cancel <job_id>          # kill a running job's process tree; wait on it then exits 22
ccodex tail <job_id> [--lines <n>]   # last log lines of a running/finished job
ccodex debug <job_id>           # compact diagnostic bundle + suggested next command
ccodex cleanup --dry-run        # preview retention sweep (default: terminal jobs older than 14d)
ccodex cleanup                  # delete expired terminal jobs (never running/young ones)
ccodex cleanup --scrub-thread-ids --thread-ttl 30d   # blank stale codex_thread_id values only
ccodex cleanup --older-than 7d --repo <repo>         # narrower sweep
```

Use `debug` first when a job looks wrong; use `cleanup` periodically (or when the user asks to
clear stale data). Scrubbed thread ids make old jobs non-resumable — that is the point.

## Worktree isolation (if `diff`/`apply` are supported)

`run --mode implement` executes an edit-capable worker in an isolated git worktree — the main
repo is never touched. Then:

```powershell
ccodex diff <job_id>    # inspect what the worker changed (git diff base..snapshot)
ccodex apply <job_id>   # apply those changes to the main repo (requires a clean tree)
```

`apply` exits **25** on conflict and leaves the main repo untouched — report the conflict, do
not force it. Review the diff before applying; you own what gets applied.

## Multi-turn sessions (if `resume` is supported)

If Codex's answer is a clarifying question, or a finding needs pushback or refinement, continue
the same Codex session instead of starting over:

```powershell
"<your follow-up>" | ccodex resume <job_id>
```

If it exits 2 with a scrubbed/absent-thread message, or fails with
`failure_reason: thread_expired`, the session is gone — start a fresh `run`.

## Exit codes and failure reactions

Trust the exit code plus `status.json.failure_reason`; never parse stderr prose.

| Signal | Meaning → reaction |
|---|---|
| `0` | Success; stdout is the result. |
| `2` | Usage error (also the expected code for `ccodex help` discovery). Fix the invocation. |
| `3` / `4` | Job not found / not terminal yet. |
| `10` + `quota_or_rate_limit` | Codex quota/rate limit. Report to the user; **never retry-loop**. |
| `10` + `auth` | Codex needs `codex login`. Report; continue without the result. |
| `10` + `permission_or_sandbox` | Sandbox denial. Consider `--access workspace` or narrower scope on a future attempt; don't auto-retry. |
| `10` + `network` | One retry is safe; then report and continue. |
| `10` (no reason) / `11` | Codex failed / produced no usable result. Note it; use judgment. |
| `12` | Wrapper internal error. Note it; continue without the review. |
| `20` | Still running — re-run `wait`, don't treat as failure. |
| `21` / `22` | Job lock timeout / job was cancelled. |
| `23` / `24` | Backend failed to start / hard timeout hit. Note it; don't blind-retry. |
| `25` | `apply` conflict; main repo untouched. |

A failed or skipped delegation never blocks your own task — record it as a note in your report
and continue.

## Delegation policy

If the target repo has `.ccodex/ccodex.json` with a `delegation` section (and/or the installed
rule `~/.claude/rules/ccodex-delegation.md` is active), follow it: it defines auto/ask/off
checkpoints for post-change reviews and post-plan second opinions, a minimum changed-lines
threshold, and a per-task call cap. Explicit user requests always win over policy.
