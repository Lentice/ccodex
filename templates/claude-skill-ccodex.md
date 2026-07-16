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

1. Never delegate generative work (writing code, plans, prose) through the advisory modes. The
   only sanctioned edit path is `run --mode implement` where `diff`/`apply` are supported (see
   Worktree isolation) — use it only when the user or the delegation policy explicitly asks,
   and always inspect `ccodex diff` before `ccodex apply`.
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
2. If `ccodex` is not on PATH: ask the user for the ccodex repo location (or to clone it) and
   for permission to install, then run `pwsh -File <repo>\install.ps1` and ensure
   `%USERPROFILE%\.local\bin` is on the user PATH. The installer also installs this skill, the
   `/ccodex` command, and the delegation rule. If the user declines, continue without ccodex.
3. Codex CLI itself must be installed and authenticated. If a call fails with
   `failure_reason: auth`, tell the user to run `codex login`; do not retry.
4. If `doctor` is in the supported list, `ccodex doctor` is the one-shot health check
   (`--no-smoke` skips the live Codex call).

Commands appear in the supported list as their phase is installed:

| Commands | Feature set |
|---|---|
| `run`, `review`, `submit`, `list`, `status`, `wait`, `read` | core (always present) |
| `cleanup`, `cancel`, `tail`, `debug`, `doctor` | job management (Phase 2b) |
| `diff`, `apply` (+ `run --mode implement`) | worktree isolation (Phase 4) |
| `resume` | multi-turn sessions (Phase 5) |

## Core usage

Prompts are piped on stdin (preferred), or passed via `--prompt-file <path>` or as a positional
argument. `run` and `submit` REQUIRE `--mode` (`review`, `brainstorm`, or `test`; plus
`implement` only where Phase 4 is installed) — omitting it exits 2. `--access` defaults per mode:
`read-only` for `review`/`brainstorm`, `worktree` for `implement` (where Phase 4 is installed),
and no default for `test` (`--access workspace` or `--access worktree` must be given explicitly —
`--access read-only` is rejected). `--repo` defaults to the repo containing the current directory.

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
"Audit error handling across src/" | ccodex submit --mode review --repo <repo>   # prints <job_id>
ccodex wait <job_id> --wait-timeout-sec 600                        # blocks; exit 20 = still running
ccodex read <job_id>                                               # print result again anytime
ccodex status <job_id>                                             # one-line state
ccodex list                                                        # enumerate jobs, newest first (all repos; --repo narrows)
ccodex list --json --state running                                 # machine-readable {schema_version,count,jobs[]}, filtered by state
                                                                   # read-only: does NOT reconcile a dead worker (a crashed job may
                                                                   # still show running/health=stale) - use `status <id>` for a verdict

# Runaway guard for any run/submit
"..." | ccodex run --mode review --hard-timeout-sec 900 --repo <repo>

# Optional per-call Codex knobs (run/submit/review/resume); omit both for Codex's defaults.
# --effort accepts none|minimal|low|medium|high|xhigh|max|ultra (per-model support varies)
"..." | ccodex run --mode brainstorm --model gpt-5.6-terra --effort xhigh --repo <repo>
```

Notes:
- ALWAYS pass `--embed-diff` on `review` unless you have verified this host's Codex sandbox can
  spawn processes: the wrapper runs `git diff` itself and embeds a size-capped diff (on many
  hosts Codex cannot run git; signature: `CreateProcessWithLogonW failed: 1385`). If the
  embedded diff got truncated by the size cap, re-run with narrower `--path` scopes until it
  fits, and report any part left unreviewed as residual risk.
- `--access workspace` grants write access inside the target repo and is reserved for
  `--mode test` tasks that produce artifacts. Never escalate a review/brainstorm to workspace
  access: if a review fails with `failure_reason: permission_or_sandbox`, use `--embed-diff`
  and/or a narrower scope, or report the review as skipped.
- Job artifacts live under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`; `status.json` there
  is the durable source of truth (`failure_reason`, `codex_thread_id`, exit codes).

## Standard post-change review recipe (the most common flow)

Follow these steps literally after finishing a feature or fix:

1. Pick the diff selector that matches where your changes currently are:
   - already committed → `--range BASE..HEAD` (BASE = the commit you started from: record
     `git rev-parse HEAD` before working, or use `git merge-base HEAD <original-branch>`)
   - staged but not committed → `--staged`
   - unstaged in the working tree → `--working`
2. Check the matching stat (`git diff --stat BASE..HEAD`, `git diff --stat --staged`, or
   `git diff --stat`) and pick 1–3 `--path` values (directories or files) that cover everything
   you touched.
3. Run:
   `ccodex review --repo <repo-or-submodule-root> <selector-from-step-1> --path <p1> [--path <p2>] --intent "<one line: what the change does>" --embed-diff`
4. If exit code is 0: stdout is the review. For every finding, open the cited code and check it
   yourself; adopt (and fix) or reject (with a reason). Summarize adopted vs rejected in your
   final report — never present Codex's raw output as your own conclusion.
5. If exit code is nonzero: look it up in the table below, do the stated reaction, and continue
   your task. A failed or skipped review never blocks the task itself.

## Job management (if `cleanup`/`cancel`/`tail`/`debug` are supported)

```powershell
ccodex cancel <job_id>          # stop a running job (cancel exits 0; later wait exits 22; read exits 11 unless a result.md was already produced)
ccodex tail <job_id> [--lines <n>]   # last log lines of a running/finished job
ccodex debug <job_id>           # compact diagnostic bundle + suggested next command
ccodex cleanup --dry-run        # preview retention sweep (default: terminal jobs older than 14d)
ccodex cleanup                  # delete expired terminal jobs (never running/young ones)
ccodex cleanup --scrub-thread-ids --thread-ttl 30d   # ALSO blanks stale codex_thread_id on
                                                     # retained jobs; the sweep still deletes
                                                     # expired jobs - preview with --dry-run
ccodex cleanup --older-than 7d --repo <repo>         # narrower sweep
```

Use `debug` first when a job looks wrong. Run `cleanup --dry-run` and then `cleanup` when the
user asks to clear stale data, or when you notice weeks-old finished jobs accumulating.
Scrubbed thread ids make old jobs non-resumable — that is the point.

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

`resume` always creates a brand-new job (new job id/directory, `parent_job_id` lineage in its
`status.json`) and inherits the parent's mode/access/repo — it never mutates the parent. It exits
`3` if `<job_id>` doesn't exist, `4` if the parent hasn't reached a terminal status yet, and `2`
if the parent ran with `--access worktree` or its `codex_thread_id` is absent/scrubbed (message
names which). If it fails with `failure_reason: thread_expired` (Codex itself rejected the
session), the session is gone either way — start a fresh `run` instead of retrying `resume`.
Chain follow-ups off the newest child's job id, not the original parent, if the exchange
continues past one reply.

## Exit codes and failure reactions

Trust the exit code plus `status.json.failure_reason`; never parse stderr prose.

| Signal | Meaning → reaction |
|---|---|
| `0` | Success; stdout is the result. |
| `2` | Usage error (also the expected code for `ccodex help` discovery). Fix the invocation. |
| `3` / `4` | Job not found / not terminal yet. |
| `10` + `quota_or_rate_limit` | Codex quota/rate limit. Report to the user; **never retry-loop**. |
| `10` + `auth` | Codex needs `codex login`. Report; continue without the result. |
| `10` + `permission_or_sandbox` | Sandbox denial. For a **test** job, `--access workspace` may help; for a review/brainstorm, NEVER escalate to workspace (see the read-only rule above) — use `--embed-diff` and/or a narrower `--path`, or report the review as skipped. Don't auto-retry. |
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
threshold, and a per-task call cap. Defaults when keys are missing: `review_after_changes: ask`,
`plan_second_opinion: ask`, `review_min_changed_lines: 50`, `max_codex_calls_per_task: 2`. The
installed rule file carries the full decision algorithm — read it if it exists. Explicit user
requests always win over policy and never count against the cap.
