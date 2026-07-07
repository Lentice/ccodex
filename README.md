# ccodex

A thin, user-level PowerShell CLI that lets an AI coding assistant (e.g. Claude Code) delegate
review, testing, brainstorming, and eventually implementation tasks to [Codex CLI](https://github.com/openai/codex)
as an external subagent — without a daemon, an MCP server, or tmux in the first version.

`ccodex` normalizes a task prompt into a job directory, invokes `codex exec` non-interactively,
captures its raw output, and hands back only the clean final result — so the calling agent can
treat it like any other command it shells out to.

```powershell
"Review this diff for correctness issues." | ccodex run --mode review
```

## Status

**Phase 1 (synchronous CLI), Phase 2a (async result channel), Phase 2c (scoped review +
delegation policy), Phase 2b (job management: locks, retention/cleanup, cancel, heartbeat/
health, tail, debug, doctor), and Phase 4 (worktree-isolated `implement` mode with `diff`/`apply`)
are done**, along with the Phase 3 `/ccodex` Claude command.
`ccodex run` is synchronous end-to-end; `ccodex submit` returns a job id immediately and hands the
work to a detached background worker that survives the submitting process exiting, with
`status`/`wait`/`read` to retrieve lifecycle and the final result from any directory. `ccodex
review` adds a path-scoped code review over a git diff range; `cancel`/`cleanup`/`tail`/`debug`/
`doctor` round out job lifecycle management and environment diagnosis; `--mode implement` (default
`--access worktree`) runs an edit-capable worker inside an isolated git worktree under the state
root — never the caller's own working tree — and `ccodex diff`/`ccodex apply` let the caller
inspect and explicitly land the worker's snapshot commit onto the main repo; and
`.ccodex/ccodex.json` plus the installed `~/.claude/rules/ccodex-delegation.md` rule let a project
opt every Claude Code session into automatic review/second-opinion checkpoints. See
[`docs/2026-07-03-ccodex-adapter-phase1-plan.md`](docs/2026-07-03-ccodex-adapter-phase1-plan.md),
[`docs/2026-07-04-ccodex-adapter-phase2a-plan.md`](docs/2026-07-04-ccodex-adapter-phase2a-plan.md),
[`docs/2026-07-05-ccodex-delegation-plan.md`](docs/2026-07-05-ccodex-delegation-plan.md),
[`docs/2026-07-07-ccodex-phase2b-plan.md`](docs/2026-07-07-ccodex-phase2b-plan.md), and
[`docs/2026-07-07-ccodex-phase4-plan.md`](docs/2026-07-07-ccodex-phase4-plan.md)
for the task-by-task build logs and [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md)
for the full design across all planned phases.

Implemented so far:

- `ccodex.ps1` — dispatcher for `run`, `submit`, `status`, `wait`, `read`, `review`, `cancel`,
  `diff`, `apply`, `tail`, `debug`, `cleanup`, `doctor`, and the internal `worker` subcommand;
  `run`/`submit` accept `--mode` (including `implement`), `--access` (including `worktree`),
  `--repo`, `--prompt-file`, a positional task argument, or a piped/redirected-stdin task;
  `review` accepts a diff selector (`--range`/`--staged`/`--working`), `--path`, `--intent`,
  `--focus`, `--embed-diff`, and `--repo`; `diff`/`apply` take a worktree job id; `cancel`/`tail`/
  `debug` take a job id (`tail` also accepts `--lines`); `cleanup` accepts `--older-than`,
  `--thread-ttl`, `--dry-run`, `--include-stalled`, `--scrub-thread-ids`, and `--repo`; `doctor`
  accepts `--no-smoke` and `--repo`
- `ccodex.cmd` — `PATH` shim that forwards to `pwsh -File ccodex.ps1`
- `install.ps1` — copies `ccodex.ps1` + `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes the
  `ccodex.cmd` shim there, installs the default worker-prompt template to
  `%APPDATA%\ccodex\templates\worker-prompt.md`, installs the `/ccodex` Claude command to
  `%USERPROFILE%\.claude\commands\ccodex.md`, and installs the delegation policy rule to
  `%USERPROFILE%\.claude\rules\ccodex-delegation.md`
- `lib/Paths.ps1` — global state-root path helpers and `repo_key` hashing
- `lib/Repo.ps1` — `--repo` override / `git rev-parse --show-toplevel` resolution
- `lib/JobId.ps1` — job id generation and atomic job-directory reservation
- `lib/PromptSource.ps1` / `lib/StdinTimeout.ps1` — prompt-source precedence (`--prompt-file` /
  positional task / piped or redirected stdin) and bounded-timeout stdin reading
- `lib/WorkerPrompt.ps1` — worker-prompt template resolution and rendering
- `lib/ModeAccess.ps1` — mode/access validation and `codex exec` argument construction
- `lib/JobStore.ps1` — job file writers (`prompt.md`, `command.txt`, `debug.json`, `status.json`,
  `worker-complete.json`)
- `lib/CodexInvoke.ps1` — `codex exec` process invocation, event/stderr log capture
- `lib/ResultValidation.ps1` — `result.md` validation into status + wrapper exit code
- `lib/JobIndex.ps1` — global job-id → job-dir lookup, callable from any directory
- `lib/JobStatus.ps1` — status.json read, worker liveness check, narrowly-gated orphan
  reconciliation, and `Get-CcodexJobHealth` (derives `ok`/`stale` from `last_heartbeat_at`,
  never stored itself)
- `lib/Worker.ps1` — the internal worker entrypoint (`ccodex worker --job-id <id>`); runs the same
  Codex flow as `run` but reads the prepared job directory instead of taking task text on the
  command line, and re-stamps `last_heartbeat_at` on a fixed cadence while Codex runs
- `lib/Detach.ps1` — detached-process launch (CIM `Win32_Process.Create` in production,
  `Start-Process` for tests) plus a startup sentinel so `submit` can report exit `23` if the
  worker never starts; also process-tree termination (`Stop-CcodexProcessTree`) used by `cancel`
- `lib/Config.ps1` — `.ccodex/ccodex.json` `delegation` section reader, with per-key defaults and
  enum/type validation
- `lib/UserConfig.ps1` — `%APPDATA%\ccodex\config.json` `retention` section reader (`jobs_days`/
  `thread_ttl_days`), with per-key defaults and non-negative-integer validation
- `lib/JobLock.ps1` — the per-job advisory lock (`<job_dir>\.lock\`) every status.json writer
  (worker, `cancel`, `cleanup`'s thread-id scrub) now routes through; stale-lock breaking after a
  10-minute owner-dead window; lock acquisition failure surfaces as wrapper exit `21`
- `lib/Cleanup.ps1` — the `ccodex cleanup` retention-sweep engine: deletes aged terminal jobs
  (index entry first, then the job directory), removes dangling index entries, optionally
  reconciles and sweeps stalled jobs (`--include-stalled`), scrubs `codex_thread_id` on
  retained-but-expired jobs (`--scrub-thread-ids`) under the per-job lock, and (Phase 4) removes a
  deleted job's worktree via `lib/Worktree.ps1` and sweeps any dangling worktree directory whose
  job dir is already gone
- `lib/ReviewPrompt.ps1` — composes the `ccodex review` task text (self-diff and `--embed-diff`
  forms) from a diff selector, paths, intent, and focus
- `lib/Worktree.ps1` — the `--access worktree` lifecycle: `New-CcodexJobWorktree` creates a
  detached git worktree at the main repo's current HEAD under
  `%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`; `Complete-CcodexJobWorktree` stages and commits
  whatever the worker left behind (as `ccodex-worker <ccodex@local>`) into one deterministic
  snapshot commit after the process exits; `Remove-CcodexJobWorktree` tears the worktree down
  (best-effort when the main repo itself is already gone)
- `templates/worker-prompt.md` — default worker-prompt contract template
- `templates/claude-command-ccodex.md` — the `/ccodex` Claude command template (includes `review`,
  job-management, and delegated-implementation `implement` → `diff` → `apply` guidance)
- `templates/claude-rule-ccodex-delegation.md` — the always-on delegation policy rule, installed
  to `~/.claude/rules/ccodex-delegation.md` (includes the never-auto-apply `implement`/`diff`/
  `apply` guidance)
- `templates/claude-skill-ccodex.md` — the `ccodex` Claude Code agent skill, installed to
  `~/.claude/skills/ccodex/SKILL.md`, teaching any session how and when to use every phase's
  commands (discovered at runtime via `ccodex help`'s exit-2 command list)
- A full plain-PowerShell test suite under `tests/` (no Pester; see Testing below)

Not yet implemented: tmux and `resume` (Phase 5). Running `ccodex` with any subcommand other than
`run`, `submit`, `status`, `wait`, `read`, `review`, `cancel`, `diff`, `apply`, `tail`, `debug`,
`cleanup`, `doctor`, or `worker` exits 2 with a "not implemented" message.

## Quick reference

One line per goal — full details in [Usage](#usage) below.

| Goal | Command |
| --- | --- |
| Second opinion / brainstorm (sync) | `"<task>" \| ccodex run --mode brainstorm` |
| Code/plan review (sync, free-form) | `"<task>" \| ccodex run --mode review` |
| Review exactly the changes just made | `ccodex review --range <base>..HEAD --path lib/ --intent "<what changed>" --embed-diff` |
| Review uncommitted work | `ccodex review --working --path <p> --intent "<what changed>" --embed-diff` |
| Review inside a submodule | `ccodex review --repo <submodule-path> --range <base>..HEAD --embed-diff` |
| Delegate an implementation | `"<task>" \| ccodex run --mode implement` (edits happen in an isolated worktree, never your working tree) |
| Inspect/apply a worker's changes | `ccodex diff <job_id>` then, once reviewed, `ccodex apply <job_id>` |
| Long / parallel background job | `"<task>" \| ccodex submit --mode test --access workspace` then `ccodex wait <job_id>` |
| Check on a background job | `ccodex status <job_id>` (non-blocking) / `ccodex read <job_id>` (result if finished) |
| Bound a possibly-hanging job | add `--hard-timeout-sec <n>` to `run`/`submit` (kills the tree, exit `24`) |
| Stop a background job | `ccodex cancel <job_id>` (kills the process tree; no-op on an already-terminal job) |
| Inspect a job's raw logs | `ccodex tail <job_id> [--lines <n>]` (tails `stderr.log` + `codex-events.jsonl`) |
| Compact diagnosis + next step | `ccodex debug <job_id>` |
| Reclaim disk / scrub old sessions | `ccodex cleanup --dry-run` then `ccodex cleanup [--older-than <Nd\|Nh>] [--scrub-thread-ids]` |
| Diagnose an environment-shaped failure (auth/quota/1385-style) | `ccodex doctor` (add `--no-smoke` to skip the live Codex call) |
| From Claude Code | `/ccodex <task>`; per-project automatic checkpoints via `.ccodex/ccodex.json` |

Picking the right verb:

- **`run`** — synchronous: you want the answer now and the task is one self-contained ask.
- **`submit` + `wait`/`read`** — the task is long, or you want several Codex workers running in
  parallel while you keep working; the worker survives the submitting shell exiting.
- **`review`** — you want severity-ordered findings on a *diff* (path-scoped) rather than a
  free-form answer. On hosts where Codex's sandbox cannot spawn processes (observed signature:
  `CreateProcessWithLogonW failed: 1385`), always pass `--embed-diff` — it is the form verified
  live on this machine; the default self-diff form is lighter where the sandbox allows process
  execution.
- **`run --mode implement`** — you want Codex to actually make an edit rather than advise on one;
  it runs inside an isolated git worktree under the state root, so your own working tree is never
  touched by the job itself. Inspect with `ccodex diff <job_id>` and land the change explicitly
  with `ccodex apply <job_id>` — never auto-apply; review the diff first.
- **`cancel`** — a submitted job needs to be stopped (wrong task, taking too long, no longer
  needed) rather than waited out.
- **`cleanup`** — periodic hygiene: run it (ideally with `--dry-run` first) to reclaim disk from
  aged terminal jobs and, with `--scrub-thread-ids`, to blank out stale `codex_thread_id` values
  so old jobs stop being resumable.
- **`doctor`** — the first move whenever a failure looks environment-shaped (auth, quota, sandbox
  denial, the `CreateProcessWithLogonW failed: 1385` signature) rather than task-specific; it
  isolates whether Codex/the wrapper/the state root itself is broken before you re-run anything.

Exit codes at a glance: `0` ok · `2` usage · `3` unknown job · `4` not finished yet (`read`) ·
`10` codex failed · `11` empty result · `12` internal · `20` wait timeout · `21` job lock timeout
· `22` job cancelled · `23` worker never started · `24` hard-timeout kill · `25` `apply` conflict/
failure (main repo left untouched). On failure,
`status.json.failure_reason` hints the reaction: `quota_or_rate_limit` → report it, don't retry ·
`auth` → run `codex login` · `permission_or_sandbox` → consider `--access workspace` or narrow the
task · `network` → one retry is safe. When the reason itself is unclear, run `ccodex doctor` (or
`ccodex debug <job_id>`) before retrying.

## Why

- **Simple interface.** Claude sends a task, waits for a result when appropriate, and reads
  stdout — like running any other CLI command.
- **No command-length or quoting issues.** Task content always goes through `prompt.md` /
  stdin, never long command-line arguments.
- **Debuggable by default.** Every job leaves behind `prompt.md`, `command.txt`, `debug.json`,
  `status.json`, raw event logs, and the final result — without cluttering the caller's stdout.
- **Global, not per-project.** `ccodex` runs from `PATH` and stores job state under
  `%LOCALAPPDATA%\ccodex\` / `%APPDATA%\ccodex\`, so every project can use the same installed
  command without adding anything to its own repo.

## Usage

`ccodex run` and `ccodex submit` both read task text from exactly one of a piped or redirected
stdin stream, `--prompt-file <path>`, or a positional task argument. `run` sends it to `codex exec`
non-interactively and blocks until it finishes; `submit` prepares the same job and hands it to a
detached background worker, returning immediately.

```powershell
# Synchronous, read-only review or brainstorming (defaults to --access read-only)
"Review this diff for correctness issues." | ccodex run --mode review
"What are the trade-offs of X vs Y?" | ccodex run --mode brainstorm

# Positional task text or --prompt-file instead of piping
ccodex run --mode review "Review this diff for correctness issues."
ccodex run --mode review --prompt-file .\review-task.md

# Test tasks need explicit write access for artifacts (screenshots, traces, logs)
"Run the login flow in Playwright and report the result." | ccodex run --mode test --access workspace

# Point at a repo other than the current directory's
"Review this diff." | ccodex run --mode review --repo D:\Documents\GitHub\some-other-repo
```

### Scoped code review (`ccodex review`)

`ccodex review` is sugar over the `run` pipeline (always `--mode review`, `--access read-only`):
it composes a review prompt from a diff selector and hands it to the same execution path as
`run` — identical job artifacts, exit codes, and failure classification. It never reads piped
stdin; the task text is the composed prompt, not caller-supplied text. By default it tells Codex
to run `git diff` itself (inside its own read-only sandbox) and review the result, which keeps
the prompt tiny and lets Codex open surrounding files for context.

Pick exactly one range selector:

```powershell
# A commit range
ccodex review --range abc123..HEAD --path lib/ --intent "Add retry logic to CodexInvoke"

# The staged index
ccodex review --staged --path lib/Config.ps1 --intent "New config reader"

# The working tree (uncommitted, unstaged changes)
ccodex review --working --path lib/ --intent "In-progress refactor"
```

Other flags:

- `--path <p>` — repeatable; scopes the diff to one or more paths (directories or files) instead
  of the whole repo. Omit it to review the full range.
- `--intent "<text>"` — one-line description of what the change is trying to do; included in the
  prompt to give Codex context.
- `--focus "<text>"` — an additional angle to emphasize (e.g. "concurrency" or "error handling").
- `--embed-diff` — instead of having Codex run `git diff` itself, the wrapper runs it up front
  (from `--repo`'s root) and embeds the diff plus a `git diff --stat` summary directly in the
  prompt, capped at 100 KB with a truncation note. Use this when Codex regenerating the diff
  itself would be unreliable (unusual git states, detached worktrees, etc) — and treat it as the
  default on hosts where Codex's sandbox cannot spawn processes at all (Codex reports
  `CreateProcessWithLogonW failed: 1385`; the self-diff form cannot work there).
- `--repo <path>` — as with `run`/`submit`, target a repository other than the current directory.

Findings always come back severity-ordered (Critical, then Important, then Minor) with a
file:line and a suggested fix per finding, plus a one-line verdict — success prints exactly that
to stdout, and failures behave exactly like a failed `run` (same exit codes and
`failure_reason` hints).

**Submodule scoping:** when the change under review lives inside a git submodule, point `--repo`
directly at the submodule instead of the superproject, so the diff and path scoping resolve
against the submodule's own history:

```powershell
ccodex review --repo D:\Documents\GitHub\superproject\vendor\some-submodule `
  --range abc123..HEAD --path src/ --intent "Bump dependency and adjust call sites"
```

### Worktree-isolated implementation (`--mode implement`, `ccodex diff`, `ccodex apply`)

Mode/access matrix:

| Mode | Valid `--access` | Default when `--access` is omitted |
| --- | --- | --- |
| `review` | `read-only` only | `read-only` |
| `brainstorm` | `read-only` only | `read-only` |
| `test` | `workspace` or `worktree` | none — `--access` must be given explicitly (`read-only` is rejected) |
| `implement` | `worktree` only | `worktree` |

`--mode implement` runs an edit-capable Codex worker inside an isolated, detached git worktree
under the state root (`%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`) — never inside the caller's own
working tree, and the main repo is never mutated by the run itself:

```powershell
"Add input validation to the signup form." | ccodex run --mode implement --repo D:\some\repo
# -> blocks until Codex finishes, then prints its final message (same as any other `run`)

# Or run it in the background like any other job:
"Add input validation to the signup form." | ccodex submit --mode implement --repo D:\some\repo
ccodex wait <job_id>
```

When the process exits (success, failure, or a hard-timeout kill), the wrapper stages and commits
whatever the worker left behind into one deterministic snapshot commit (author
`ccodex-worker <ccodex@local>`, message `ccodex: worker output <job_id>`) on top of the worktree's
base commit — a no-op worker leaves the worktree at its base commit instead (`status.json`'s
`worktree_committed` is `false`). `status.json`/`debug.json` additionally record `main_repo`,
`worktree_repo`, and `base_commit` for a worktree job (`null` for non-worktree jobs).

**`ccodex diff <job_id>`** — read-only inspection of a worktree job's changes; prints
`git diff --stat <base_commit>..HEAD` followed by the full `git diff <base_commit>..HEAD` from the
job's worktree. An empty change set prints an informational "no changes to diff" line instead
(still exit `0`). Exit `3` for an unknown job id or a worktree already removed by `cleanup`
("worktree removed; artifacts remain at `<job_dir>`"); exit `4` if the job hasn't finished yet;
exit `2` if the job wasn't run with `--access worktree` in the first place.

```powershell
ccodex diff <job_id>
```

**`ccodex apply <job_id>`** — explicitly lands a **done** worktree job's snapshot commit onto the
main repo: `git format-patch <base_commit>..HEAD --stdout` from the worktree, piped to
`git am --3way` in the main repo. Requires the main repo's working tree to be clean first (exit
`2`, naming the dirty files, otherwise); only `done` jobs may be applied (`failed`/`timed_out`/
`cancelled` → exit `2`); an empty change set is a no-op (exit `0`, main repo untouched). On
success it prints the applied commit range and exits `0`. **Any** non-success outcome — a textual
conflict, or a patch `git am` accepts as a no-op without advancing `HEAD` (e.g. already applied) —
runs `git am --abort` and force-restores the main repo to its pre-apply `HEAD`, then exits **`25`**
naming the conflicting files and pointing at `ccodex diff <job_id>`. The main repo is never left
mutated except by a genuinely successful apply.

```powershell
ccodex diff <job_id>    # ALWAYS review before applying — never auto-apply
ccodex apply <job_id>
# -> ccodex: applied job <job_id> to <main_repo>
#      range: <base_commit>..<new_head>
```

`ccodex cleanup` removes a deleted job's worktree directory (via the recorded `main_repo`) before
removing its job dir, and separately sweeps any dangling worktree directory whose job dir is
already gone — see "Job management" below.

### Delegation policy (`.ccodex/ccodex.json`)

A project can opt into automatic delegation checkpoints — teaching a Claude Code session when to
run a `ccodex review` on its own — by adding `<repo_root>/.ccodex/ccodex.json`:

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

This file is configuration only — it is never touched by job execution and lives outside the
job-state tree entirely. The file and the `delegation` section are both optional; a missing file,
a missing section, or missing individual keys all fall back to the defaults shown above.
Malformed JSON or an invalid enum value is a usage error (exit `2`) naming the file.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `review_after_changes` | `"auto"` \| `"ask"` \| `"off"` | `"ask"` | Post-change checkpoint: run a review automatically, ask the user first, or only review on explicit request. |
| `review_min_changed_lines` | int | `50` | Below this changed-line count, skip the post-change review entirely (cost guard). |
| `review_default_paths` | string[] | `[]` | Default `--path` set for the post-change review when the caller hasn't narrowed it further. |
| `plan_second_opinion` | `"auto"` \| `"ask"` \| `"off"` | `"ask"` | Post-plan checkpoint: same auto/ask/off semantics, applied after writing or updating a plan/spec document. |
| `max_codex_calls_per_task` | int | `2` | Cap on total `ccodex` calls (review or otherwise) per task; once reached, no further calls are made for the rest of the task. |

Installing `ccodex` (see below) installs a Claude Code rule at
`~/.claude/rules/ccodex-delegation.md` that teaches every session how to read this file and apply
the checkpoints — the user never has to re-explain the policy per project or per session.

Every job leaves behind `prompt.md`, `command.txt`, `debug.json`, `status.json`,
`worker-complete.json`, `codex-events.jsonl`, `stderr.log`, `exit_code.txt`, and (on success)
`result.md` under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`, plus an index entry at
`%LOCALAPPDATA%\ccodex\index\<job_id>.json` that lets `status`/`wait`/`read` find the job from any
directory. `status.json` additionally records `backend` (`sync` for `run`, `native` for
`submit`/`worker`), `backend_id`, `started_at`, `finished_at`, `failure_reason`,
`codex_thread_id`, `hard_timeout_sec`, `timeout_reason`, `terminated_at`, `cancelled_at`,
`last_heartbeat_at`, and — for a `--access worktree` job — `main_repo`, `worktree_repo`,
`base_commit`, and `worktree_committed` (all `null` for non-worktree jobs; see "Failure classes",
"Hard timeout", "Worktree-isolated implementation", and "Job management" below). Every
writer of `status.json` — the worker's running/terminal writes, `cancel`, and `cleanup`'s
thread-id scrub — now serializes through a per-job lock (`<job_dir>\.lock\`) so two writers can
never race each other; a lock that cannot be acquired within its timeout surfaces as wrapper exit
`21` rather than corrupting the file.

### Job management (`cancel` / `tail` / `debug` / `cleanup` / `doctor`)

**`ccodex cancel <job_id>`** stops a `running` (or still-`created`) job: it identity-checks the
recorded `backend_id` (pid + start time, so a reused pid is never mistaken for the job's own
worker), force-kills the whole process tree (worker + whatever `codex` child it spawned), and
marks the job `cancelled` with a `cancelled_at` timestamp. It is a no-op — exit `0`, printing
`<job_id> already <status>` — on a job that is already terminal (`done`/`failed`/`timed_out`/
`cancelled`); a `wait` on an already-cancelled job returns exit `22`.

```powershell
ccodex cancel <job_id>
# -> <job_id> cancelled
```

**`ccodex tail <job_id> [--lines <n>]`** prints the last `n` lines (default `40`) of
`stderr.log` and `codex-events.jsonl` for a job — read-only, never reconciles or mutates
`status.json`. A missing file renders as `(absent)` rather than failing the whole command.

```powershell
ccodex tail <job_id> --lines 80
```

**`ccodex debug <job_id>`** prints a compact one-shot diagnosis: status (with `health=ok|stale`
while running), mode/access/backend/repo, every recorded timestamp, `backend_id` with a live/dead
verdict, exit codes, `failure_reason` (with its hint line), `codex_thread_id` (or
`absent/scrubbed`), whether `result.md` is present, the last 5 lines of `stderr.log`, the job
directory, and a suggested next command (`ccodex wait`/`read`/`tail` depending on status).

```powershell
ccodex debug <job_id>
```

**`ccodex cleanup`** sweeps the jobs tree (not just the index — a crash mid-delete can leave an
unindexed job directory the tree scan still finds) and deletes terminal jobs older than the
retention threshold, in index-entry-then-directory order, plus any dangling index entries whose
job directory is already gone. It never touches a young or still-live job. When a deleted job
carries a recorded worktree (a `--access worktree` job), its worktree directory is removed first
via `git worktree remove` against the job's `main_repo` (best-effort — a worktree-teardown failure
never blocks the job dir/index delete); separately, any *dangling* worktree directory under
`worktrees\` whose job dir is already gone anywhere is swept too. Pass `--dry-run` to preview
without deleting (worktree candidates are listed alongside job candidates); `--include-stalled`
first reconciles non-terminal jobs with a dead worker (same check `status`/`wait`/`read` do)
before judging them; `--scrub-thread-ids` blanks `codex_thread_id` (under the per-job lock,
byte-stable rewrite — no other field changes) on retained jobs older than the thread TTL, making
them non-resumable. `--older-than <Nd|Nh>` and `--thread-ttl <Nd>` override the configured
thresholds for one run; `--repo <path>` narrows the sweep to one repo's jobs (the worktree sweep
itself is deliberately unfiltered by `--repo`, since worktrees live in one global directory, not
per-repo). Best-effort: exit `0` normally, `12` only if an individual delete/scrub failed (the
sweep still completes and reports the count).

```powershell
ccodex cleanup --dry-run                            # preview only
ccodex cleanup                                      # delete aged terminal jobs (+ their worktrees)
ccodex cleanup --older-than 7d --repo D:\some\repo   # narrower, repo-scoped sweep
ccodex cleanup --include-stalled --scrub-thread-ids # reconcile stalled jobs + scrub old thread ids
# -> cleanup: deleted=<n> reclaimed_kb=<n> dangling=<n> scrubbed=<n> skipped=<n> failed=<n> worktrees_swept=<n>
```

**`ccodex doctor [--no-smoke] [--repo <path>]`** is the first move whenever a failure looks
environment-shaped rather than task-specific (auth, quota, sandbox denial, the
`CreateProcessWithLogonW failed: 1385` signature) — it isolates whether Codex, the wrapper, or the
state root itself is the problem before you retry anything. It runs, in order: `codex --version`
resolvable and successful; delegated `codex doctor` (its own output is echoed on failure);
state-root writability (create+delete a probe file under `jobs\`); worker-prompt template
present; an informational index/jobs consistency count (dangling indexes, unindexed job
directories — never fails the command); and, unless `--no-smoke` is passed, a real end-to-end
`ccodex run` smoke test expecting the literal reply `OK`. An environment check failure always
yields exit `12`, even if the smoke test also failed — a broken environment is the more
fundamental problem. A smoke-test-only failure yields exit `10`. A bad `--repo` is a usage error
(exit `2`), same as `run`/`review`.

```powershell
ccodex doctor              # full check including the live smoke test
ccodex doctor --no-smoke   # environment checks only, no real Codex call
```

### Retention config (`%APPDATA%\ccodex\config.json`)

`cleanup`'s default thresholds come from an optional `retention` section in
`%APPDATA%\ccodex\config.json` (distinct from the per-project `.ccodex/ccodex.json` delegation
config above — this one is user-level, applying to every repo):

```json
{
  "retention": {
    "jobs_days": 14,
    "thread_ttl_days": 30
  }
}
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `jobs_days` | non-negative int | `14` | A terminal job older than this (measured from `finished_at`, else `terminated_at`, else `cancelled_at`, else `created_at`) is deleted by `cleanup`. |
| `thread_ttl_days` | non-negative int | `30` | With `--scrub-thread-ids`, a *retained* terminal job older than this has its `codex_thread_id` blanked. |

The file and the `retention` section are both optional; a missing file, a missing section, or
missing individual keys fall back to the defaults above. A malformed `config.json`, a
non-integer value, or a negative value is a usage error naming the file. `--older-than <Nd|Nh>`
and `--thread-ttl <Nd>` on the `cleanup` command line always take precedence over this file for
that one invocation.

### Exit codes

Callers can rely on these wrapper exit codes:

| Code | Meaning |
| ---- | ------- |
| `0`  | Success — `result.md` was produced and its content was printed to stdout (`run`/`wait`/`read`), or the job id + job dir were printed (`submit`). |
| `2`  | Usage/validation error (bad `--mode`/`--access`, missing/ambiguous prompt source, repo resolution failure, unknown subcommand, etc.). |
| `3`  | Job id not found (`status`/`wait`/`read`). |
| `4`  | Job exists but has not reached a terminal status yet (`read` only — `wait` blocks instead). |
| `10` | The `codex exec` process itself exited non-zero. |
| `11` | `codex exec` exited zero but `result.md` is missing or empty. |
| `12` | Wrapper-internal error (unexpected I/O/serialization failure). |
| `20` | `wait` timed out (`--wait-timeout-sec`) before the job reached a terminal status; the job's lifecycle is unaffected — re-run `wait` to keep waiting. |
| `21` | Could not acquire the per-job lock (e.g. `cancel`, or an internal status write) within its timeout. Retry the command. |
| `22` | `wait` returned because the job's terminal status is `cancelled` (someone ran `ccodex cancel` on it). |
| `23` | The background worker failed to launch, or never stamped a startup sentinel, during `submit`. |
| `24` | The job hit `--hard-timeout-sec` before Codex exited; the process tree was killed and the job is terminal `timed_out`. Raise the timeout or split the task before retrying. |
| `25` | `ccodex apply <job_id>` failed or conflicted; `git am --abort` ran and the main repo was force-restored to its pre-apply `HEAD` (never left mutated). Review `ccodex diff <job_id>`, resolve by hand, and re-run `apply`. |

`diff` and `apply` additionally use exit `2` for a non-worktree job or (for `apply`) a dirty main
repo/non-`done` job, and exit `4` for a job that hasn't finished yet — see "Worktree-isolated
implementation" above. `cancel`, `tail`, `debug`, and `cleanup` additionally use exit `3` for an unknown job id (same as
`status`/`wait`/`read`) and exit `12` for a wrapper-internal failure; `cleanup` and `doctor` are
documented in full in "Job management" above.

### Failure classes

When `codex exec` itself fails (wrapper exit `10`) or a pre-launch internal failure occurs
(exit `12`), `status.json` may carry a `failure_reason` — a conservative, best-effort HINT
derived from matching known signatures in the tail of `stderr.log` and any `"error"`-bearing
event lines. It is never stamped on a successful run, and exit codes remain authoritative;
treat `failure_reason` as a shortcut to the right reaction, not a guarantee:

| `failure_reason` | Meaning | Recommended reaction |
| ---- | ------- | ------- |
| `quota_or_rate_limit` | Codex usage/rate limit reached (signature: `usage limit`, `rate limit`, `quota`, `429`). | Report to the user; do not auto-retry. |
| `auth` | Codex auth/credential problem (signature: `login`, `auth`, `401`, `unauthorized`, `credential`). | Suggest running `codex login`. |
| `permission_or_sandbox` | Sandbox or approval denial (signature: `sandbox`, `denied`, `approval`, `permission`). | Consider `--access workspace` or narrow the task. |
| `network` | Transient network failure (signature: `network`, `connection`, `dns`, `502`, `503`). | One retry is safe. |
| *(absent)* | No recognized signature, or the run succeeded. | Fall back to the exit code and `error` message. |

Classification precedence when multiple signatures are present in the same failure: quota beats
auth beats permission beats network. `status.json` also records `codex_thread_id` (the Codex
`thread_id`, captured on both success and failure whenever the events log carries one) for
future resume/debugging use.

### Hard timeout

Pass `--hard-timeout-sec <n>` to `run` or `submit` to bound how long Codex is allowed to run
before the wrapper kills its whole process tree:

```powershell
"Run the full test suite." | ccodex run --mode test --access workspace --hard-timeout-sec 120
"Run the full test suite." | ccodex submit --mode test --access workspace --hard-timeout-sec 120
```

On expiry the job becomes terminal `timed_out` with `timeout_reason` (e.g.
`hard_timeout_sec=120 exceeded`) and `terminated_at` recorded in `status.json`,
`codex_exit_code` stays `null` (Codex never produced one), and the wrapper/`wait` exit code is
`24`. All artifacts (`prompt.md`, `codex-events.jsonl`, `stderr.log`, `status.json`) are kept for
inspection. The default is `0`, meaning no hard timeout is applied — a quiet job is not assumed
dead.

### Long-running or parallel work

`submit` returns as soon as the job is prepared and handed to a detached worker — it prints the
job id then the job directory (two lines) and exits `0` without waiting for Codex to finish. Use
`status`/`wait`/`read` from any directory to check on it later, including after the submitting
process has exited:

```powershell
"Run the full test suite and report failures." | ccodex submit --mode test --access workspace
# -> <job_id>
#    <job_dir>

ccodex status <job_id>   # non-blocking lifecycle line, e.g. "<job_id> running"
ccodex wait <job_id>      # blocks until terminal, then prints the result (or exits 10/11/20)
ccodex read <job_id>      # non-blocking result read; exits 4 if not finished yet
```

Submit several jobs before waiting on any of them to run independent tasks in parallel.

## Installing

```powershell
git clone <this repo> D:\Documents\GitHub\ccodex
D:\Documents\GitHub\ccodex\install.ps1
```

This copies `ccodex.ps1` and `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes a `ccodex.cmd`
shim there, installs the default worker-prompt template to
`%APPDATA%\ccodex\templates\worker-prompt.md`, installs the `/ccodex` Claude command to
`%USERPROFILE%\.claude\commands\ccodex.md`, installs the delegation policy rule to
`%USERPROFILE%\.claude\rules\ccodex-delegation.md`, and installs the `ccodex` agent skill to
`%USERPROFILE%\.claude\skills\ccodex\SKILL.md` (overwriting any previous copy of each). The
skill teaches any Claude agent on a fresh machine how and when to use ccodex; it documents all
phases and instructs agents to discover which commands are actually installed via `ccodex help`,
so one skill file serves every phase. Add
`%USERPROFILE%\.local\bin` to your user `PATH` if it isn't already there (the script warns if it's
missing) so `ccodex` is callable from any directory. Pass `-InstallDir`/`-TemplatesDir`/`-ClaudeDir`
to `install.ps1` to override the script/template/Claude-config locations (the Claude command and
rule destinations are fixed at `<ClaudeDir>\commands\ccodex.md` and
`<ClaudeDir>\rules\ccodex-delegation.md`, `<ClaudeDir>` defaulting to `%USERPROFILE%\.claude`).

Once installed, `/ccodex` is available as a slash command in Claude Code: it summarizes the task,
calls `ccodex run`/`submit`/`wait`/`read`/`review`/`cancel`/`diff`/`apply`/`tail`/`debug`/
`cleanup`/`doctor` as appropriate, and treats the wrapper's exit code as the source of truth for
success/failure rather than parsing stderr prose. It always reviews a delegated implementation's
`ccodex diff` before deciding whether to `ccodex apply` it — never automatically. The installed
rule at `~/.claude/rules/ccodex-delegation.md` is loaded automatically in every session (no slash
command needed) and teaches the post-change/post-plan delegation checkpoints described above.

## Repository layout

```text
ccodex.ps1          # dispatcher: parses args, implements run/submit/status/wait/read/review/
                    #   cancel/diff/apply/tail/debug/cleanup/doctor/worker
ccodex.cmd          # PATH shim: forwards to `pwsh -File ccodex.ps1`
install.ps1         # installs to %USERPROFILE%\.local\bin\ccodex\, ~\.claude\commands\ccodex.md,
                    #   ~\.claude\rules\ccodex-delegation.md, and ~\.claude\skills\ccodex\SKILL.md
templates/          # worker-prompt contract, the /ccodex Claude command, the delegation rule
                    #   template, and the ccodex Claude Code agent skill
lib/                # single-responsibility PowerShell modules, dot-sourced by ccodex.ps1
                    #   (includes lib/Worktree.ps1 for --access worktree jobs)
tests/              # plain PowerShell assertion scripts (no Pester — see the Phase 1 plan)
docs/               # design spec and phase plans
```

## Requirements

- PowerShell 7+
- [Codex CLI](https://github.com/openai/codex) available on `PATH` (`codex exec ...`)
- Git (used for project-root resolution)

## Testing

There is no Pester dependency. Each `lib/*.ps1` module has a matching `tests/*.tests.ps1` file
that is a plain PowerShell script — run it directly and check its exit code:

```powershell
pwsh -NoProfile -File tests/Paths.tests.ps1
```

## Roadmap

- **Phase 1 — Synchronous CLI:** `ccodex run`, prompt transport, job files, install script. *(done)*
- **Phase 2a — Async result channel:** `submit`, `status`, `wait`, `read`, internal `worker`, native detached backend with a startup sentinel. *(done)*
- **Phase 3 — Claude slash command:** `/ccodex` installed to `~\.claude\commands\ccodex.md`. *(done)*
- **Phase 2c — Scoped review + delegation policy:** `ccodex review`, `.ccodex/ccodex.json`
  delegation config, `~\.claude\rules\ccodex-delegation.md`. *(done)*
- **Phase 2b — Job management:** retention config, per-job locks, `cleanup` (including
  `--scrub-thread-ids` for stale session data), `cancel`, heartbeat/health, `tail`, `debug`,
  `doctor`. *(done — [`docs/2026-07-07-ccodex-phase2b-plan.md`](docs/2026-07-07-ccodex-phase2b-plan.md))*
- **Phase 4 — Worktree isolation:** `--mode implement` (default `--access worktree`) runs
  edit-capable workers in an isolated git worktree under the state root, with explicit
  `ccodex diff`/`ccodex apply` and worktree-aware `cleanup`.
  *(done — [`docs/2026-07-07-ccodex-phase4-plan.md`](docs/2026-07-07-ccodex-phase4-plan.md))*
- **Phase 5 — Multi-turn advisor:** `ccodex resume <job_id>` continues a finished job's Codex
  session for follow-up discussion. *(planned — [`docs/2026-07-07-ccodex-phase5-plan.md`](docs/2026-07-07-ccodex-phase5-plan.md))*

See [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md) for the
full rationale, non-goals, and phase-by-phase verification criteria, and
[`docs/2026-07-07-ccodex-handoff.md`](docs/2026-07-07-ccodex-handoff.md) for the current
development handoff (state, remaining work, document index).
