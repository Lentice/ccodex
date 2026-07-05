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

**Phase 1 (synchronous CLI) and Phase 2a (async result channel) are done**, along with the
Phase 3 `/ccodex` Claude command. `ccodex run` is synchronous end-to-end; `ccodex submit` returns
a job id immediately and hands the work to a detached background worker that survives the
submitting process exiting, with `status`/`wait`/`read` to retrieve lifecycle and the final
result from any directory. See
[`docs/2026-07-03-ccodex-adapter-phase1-plan.md`](docs/2026-07-03-ccodex-adapter-phase1-plan.md) and
[`docs/2026-07-04-ccodex-adapter-phase2a-plan.md`](docs/2026-07-04-ccodex-adapter-phase2a-plan.md)
for the task-by-task build logs and [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md)
for the full design across all planned phases.

Implemented so far:

- `ccodex.ps1` — dispatcher for `run`, `submit`, `status`, `wait`, `read`, and the internal
  `worker` subcommand; `run`/`submit` accept `--mode`, `--access`, `--repo`, `--prompt-file`, a
  positional task argument, or a piped/redirected-stdin task
- `ccodex.cmd` — `PATH` shim that forwards to `pwsh -File ccodex.ps1`
- `install.ps1` — copies `ccodex.ps1` + `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes the
  `ccodex.cmd` shim there, installs the default worker-prompt template to
  `%APPDATA%\ccodex\templates\worker-prompt.md`, and installs the `/ccodex` Claude command to
  `%USERPROFILE%\.claude\commands\ccodex.md`
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
  reconciliation
- `lib/Worker.ps1` — the internal worker entrypoint (`ccodex worker --job-id <id>`); runs the same
  Codex flow as `run` but reads the prepared job directory instead of taking task text on the
  command line
- `lib/Detach.ps1` — detached-process launch (CIM `Win32_Process.Create` in production,
  `Start-Process` for tests) plus a startup sentinel so `submit` can report exit `23` if the
  worker never starts
- `templates/worker-prompt.md` — default worker-prompt contract template
- `templates/claude-command-ccodex.md` — the `/ccodex` Claude command template
- A full plain-PowerShell test suite under `tests/` (no Pester; see Testing below)

Not yet implemented (Phase 2b+): `tail`, `debug`, `cancel`, `doctor`, per-job locks,
heartbeat/health monitoring, tmux, and worktree-isolated `implement` mode / `--access worktree`
(Phase 4). Running `ccodex` with any subcommand other than `run`, `submit`, `status`, `wait`,
`read`, or `worker` exits 2 with a "not implemented" message. `--mode implement` and
`--access worktree` are also rejected today — they will be enabled in Phase 4.

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

Every job leaves behind `prompt.md`, `command.txt`, `debug.json`, `status.json`,
`worker-complete.json`, `codex-events.jsonl`, `stderr.log`, `exit_code.txt`, and (on success)
`result.md` under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`, plus an index entry at
`%LOCALAPPDATA%\ccodex\index\<job_id>.json` that lets `status`/`wait`/`read` find the job from any
directory. `status.json` additionally records `backend` (`sync` for `run`, `native` for
`submit`/`worker`), `backend_id`, `started_at`, `finished_at`, `failure_reason`,
`codex_thread_id`, `hard_timeout_sec`, `timeout_reason`, and `terminated_at` (see "Failure
classes" and "Hard timeout" below).

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
| `23` | The background worker failed to launch, or never stamped a startup sentinel, during `submit`. |
| `24` | The job hit `--hard-timeout-sec` before Codex exited; the process tree was killed and the job is terminal `timed_out`. Raise the timeout or split the task before retrying. |

Codes `21` and `22` are reserved for Phase 2b (`cancel`/`tail`) and are not produced today.

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
`%APPDATA%\ccodex\templates\worker-prompt.md`, and installs the `/ccodex` Claude command to
`%USERPROFILE%\.claude\commands\ccodex.md` (overwriting any previous copy). Add
`%USERPROFILE%\.local\bin` to your user `PATH` if it isn't already there (the script warns if it's
missing) so `ccodex` is callable from any directory. Pass `-InstallDir`/`-TemplatesDir` to
`install.ps1` to override the script/template locations (the Claude command destination is fixed
at `%USERPROFILE%\.claude\commands\ccodex.md`).

Once installed, `/ccodex` is available as a slash command in Claude Code: it summarizes the task,
calls `ccodex run`/`submit`/`wait`/`read` as appropriate, and treats the wrapper's exit code as the
source of truth for success/failure rather than parsing stderr prose.

## Repository layout

```text
ccodex.ps1          # dispatcher: parses args, implements run/submit/status/wait/read/worker
ccodex.cmd          # PATH shim: forwards to `pwsh -File ccodex.ps1`
install.ps1         # installs to %USERPROFILE%\.local\bin\ccodex\ and ~\.claude\commands\ccodex.md
templates/          # default worker-prompt contract + the /ccodex Claude command template
lib/                # single-responsibility PowerShell modules, dot-sourced by ccodex.ps1
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
- **Phase 2b — Job management:** `tail`, `debug`, `cancel`, `doctor`, retention.
- **Phase 4 — Worktree isolation:** edit-capable workers in an isolated git worktree, with explicit `diff`/`apply`.

See [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md) for the
full rationale, non-goals, and phase-by-phase verification criteria.
