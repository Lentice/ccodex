# ccodex Adapter - Claude-to-Codex Subagent Wrapper

## Problem

Claude needs a lightweight way to delegate review, testing, brainstorming, and eventually
implementation tasks to Codex as an external subagent. The interaction should feel like running a
normal CLI command: Claude sends a task, waits for a result when appropriate, reads stdout, and
then merges Codex's answer into its own reasoning.

The initial idea was a tmux-based background worker. After review, tmux should be treated as one
execution backend, not the product boundary. The product boundary is a `ccodex` adapter that gives
Claude a stable command interface while hiding prompt transport, Codex invocation, job logs, and
background execution details.

## Goals

- Let Claude call Codex through a simple CLI and read the final response from stdout.
- Avoid command-length and quoting issues by sending task content through stdin or files, not long
  command arguments.
- Support both synchronous short tasks and asynchronous long-running/background tasks.
- Preserve job artifacts for debugging without requiring Claude to read files in the normal path.
- Keep the first implementation small enough to verify phase by phase.
- Leave Claude as the orchestrator that decides how to merge or apply Codex results.

## Non-goals

- Do not build a long-running daemon or queue worker in the first version.
- Do not build an MCP server in the first version.
- Do not package an `.exe` before the CLI contract is stable.
- Do not automatically merge multiple Codex workers' file changes.
- Do not automatically commit any generated code or spec changes.
- Do not let background workers modify the main workspace by default.

## Recommended Shape

Build `ccodex` as a thin user-level PowerShell CLI first. The product contract is the command name
on `PATH`, not a repository-local script path:

```text
ccodex
```

The implementation may keep its source in any development repository, but installation must expose a
stable `ccodex` command that works from any project directory. On Windows, acceptable Phase 1 install
shapes are a PowerShell script plus shim in a user-owned PATH directory, such as
`%USERPROFILE%\.local\bin\ccodex.ps1` plus `ccodex.cmd`, or a documented equivalent. Runtime state
must not depend on the current project containing the wrapper source.

The wrapper exposes a stable Claude-facing interface. This is the target interface across all phases,
not the Phase 1 scope:

```powershell
ccodex run --mode review
ccodex run --mode test --access workspace
ccodex submit --mode test --access workspace
ccodex status <job_id>
ccodex wait <job_id>
ccodex read <job_id>
ccodex tail <job_id>
ccodex debug <job_id>
ccodex cancel <job_id>
ccodex doctor
```

`run` is synchronous and uses `codex exec -`. `submit` is asynchronous and runs the same
Codex execution flow in a background backend. The preferred backend can be tmux, but Windows
support must be verified before making tmux the only backend.

## Why CLI First

`codex exec` already supports non-interactive execution and can read the prompt from stdin with
`-`. That means the first version does not need tmux to solve command-length limits or to return a
result to Claude.

The wrapper is still useful because it standardizes:

- repository root (`-C <repo>`)
- prompt framing
- colorless output (`--color never`)
- final-message capture (`--output-last-message <job_dir>/result.md`)
- stdout/stderr/result capture
- job ids and logs
- default access level
- sync vs async behavior
- Codex command shape and access flags

## Global State And Project Layout

`ccodex` is a global user-level tool. Runtime state must live outside project repositories by
default so every project can use the same command without adding `.ccodex/jobs/` or `.gitignore`
entries.

Default Windows locations:

```text
%LOCALAPPDATA%\ccodex\
|-- jobs\
|   `-- <repo_key>\
|       `-- <job_id>\
|           |-- prompt.md
|           |-- command.txt
|           |-- result.md
|           |-- status.json
|           |-- debug.json
|           |-- codex-events.jsonl
|           |-- stdout.log
|           |-- stderr.log
|           |-- exit_code.txt
|           |-- worker-complete.json
|           `-- artifacts\
`-- index\
    `-- <job_id>.json

%APPDATA%\ccodex\
|-- config.json
`-- templates\
    `-- worker-prompt.md
```

`repo_key` is a short stable hash of the canonical `repo_root`, for example the first 12 hex
characters of SHA-256 over the fully resolved path. It is for grouping and diagnostics only; it must
not replace storing the full `repo_root` in job metadata. `index/<job_id>.json` maps a job id to its
`repo_key` and job directory so `read`, `wait`, `status`, `debug`, and `cancel` can work even when
Claude later runs them from a different project directory.

Optional project-local files may customize behavior, but they are not required:

```text
<repo>\.ccodex\ccodex.json
<repo>\.ccodex\worker-prompt.md
```

Project-local `.ccodex/` is configuration only. Job prompts, results, logs, traces, debug metadata,
and artifacts must not be written under project-local `.ccodex/jobs/` unless the caller explicitly
passes a future opt-in state-root flag. Normal `run` or `submit` execution must not silently modify
`.gitignore` or any other source file.

Version-control policy:

- Global job state under `%LOCALAPPDATA%\ccodex\jobs\` is local runtime state and should not enter
  any repository.
- Project-local `.ccodex/ccodex.json` and `.ccodex/worker-prompt.md` may be versioned when a project
  intentionally wants shared defaults.
- Project-local config must not contain secrets. If future secret configuration is needed, keep it in
  user-level `%APPDATA%\ccodex\config.json` or a dedicated credential store.
- Retention and cleanup are operational behavior, not source control behavior.

## Project Resolution

Every `run` and `submit` must resolve a target project before invoking Codex:

- If `--repo <path>` is provided, use its resolved absolute path.
- Otherwise run `git rev-parse --show-toplevel` from the current directory and use that repository
  root.
- If no git repository is found, fail with wrapper exit code `2` unless a future explicit
  `--allow-non-git --repo <path>` mode is added.
- Invoke Codex with `-C <repo_root>` and record `repo_root`, `repo_key`, current working directory,
  and any project-local config path in `status.json`/`debug.json`.

## Job ID Generation

`job_id` is generated by the `ccodex` wrapper before any Codex process starts. Claude should not
provide it, and Codex should not invent it. The wrapper owns the id because job directories,
status, debug commands, cancellation, and result lookup all depend on the same stable identifier.

Format:

```text
YYYYMMDDTHHMMSSZ-<8-char-random>-<mode>
```

Examples:

```text
20260703T073512Z-k4p9x2qa-review
20260703T073640Z-n8v3m1zt-test
```

Rules:

- Use UTC time in `YYYYMMDDTHHMMSSZ` format so job ids sort chronologically across machines and
  time zones.
- Use only Windows-path-safe characters: ASCII letters, digits, and hyphens.
- Generate the random suffix with a cryptographic random source, not by hashing the prompt or
  using a process id.
- Include only the normalized mode suffix (`review`, `brainstorm`, `test`, or `implement`) for
  human readability.
- Reserve the id by atomically creating `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`. If the
  directory already exists, generate a new random suffix and retry.
- After reservation, write `%LOCALAPPDATA%\ccodex\index\<job_id>.json` so later commands can locate
  the job from any project directory.
- Do not put prompt text, prompt hashes, usernames, branch names, or task titles in the job id.
  Store hashes and descriptive metadata in `debug.json` or `status.json` instead.

Both `run` and `submit` create a `job_id`. Synchronous `run` still saves state so a failed call can
point Claude to the job directory. Phase 2 adds `debug <job_id>` and `tail <job_id>` commands for
richer diagnosis.

## Prompt Transport

All user task content is normalized into `prompt.md`.

Supported inputs:

```powershell
# preferred for Claude slash command usage
<task text via stdin> | ccodex run --mode review

# optional human usage
ccodex run --mode review --prompt-file .\plan.md

# optional convenience only; wrapper still writes prompt.md internally
ccodex run --mode review "short task"
```

The implementation should not branch behavior based on prompt length. Even short prompts are
written to `prompt.md` because escaping, Markdown code fences, newlines, Chinese text, and shell
metacharacters can break argument-based transport.

Input precedence must be strict without risking a blocking stdin probe. Exactly one prompt source
may be provided among PowerShell pipeline input, OS-level redirected stdin, `--prompt-file`, and
positional task text. If more than one known source is present, the wrapper fails with a clear usage
error instead of merging inputs. This keeps the transport contract simpler than Codex's native
prompt+stdin append behavior.

The wrapper must detect explicit sources first: `--prompt-file` and positional task text. If either
explicit source is present, do not probe OS-level redirected stdin just to check whether a duplicate
stdin source exists. Many subprocess launchers attach an open stdin pipe even when they will never
write data or close it; reading that pipe can hang before Codex is invoked. In that case, the
explicit source wins, and OS-level stdin is treated as unavailable unless the caller uses the
PowerShell object pipeline path below.

PowerShell prompt-source detection must distinguish PowerShell object pipeline input from OS-level
stdin redirection. They are different channels and require different APIs.

PowerShell object pipeline:

- This is the preferred Claude slash-command path: `<task text> | ccodex run --mode review`.
- Detect it with `$MyInvocation.ExpectingInput`.
- Read it exactly once from the automatic `$input` enumerator. Do not use `[Console]::In` for this
  path.
- Read pipeline input at script top level, or explicitly pass the already-materialized pipeline
  collection into internal functions. `$MyInvocation.ExpectingInput` and `$input` are scope-sensitive
  and can be wrong if the detection is hidden inside a helper function.
- Collect all pipeline objects before prompt-source validation. Convert string objects as-is;
  convert non-string objects with PowerShell's normal string conversion.
- Preserve embedded newlines in string objects. When multiple pipeline records are received, join
  them with `[Environment]::NewLine`.
- Empty pipeline input means zero objects or a final joined string with zero characters. Whitespace
  is content and must not be trimmed away.
- If pipeline input and an explicit source are both present, fail with wrapper exit code `2`.

OS-level stdin redirection:

- This covers cases such as `ccodex run --mode review < plan.md` or an equivalent OS-level stdin redirection into the installed wrapper.
- Consider it only when `$MyInvocation.ExpectingInput` is false and no explicit source was provided.
  If `--prompt-file` or positional task text is present, do not call any blocking stdin read API for
  OS-level stdin.
- Detect possible redirection with `[Console]::IsInputRedirected`, but do not treat that property as
  proof that prompt data is available. It can be true for an open pipe with no writer data and no EOF.
- Do not call `[Console]::In.ReadToEnd()` for this path. Use a UTF-8 byte/stream reader over the
  standard input stream with bounded first-byte / no-progress timeouts.
- If redirected stdin does not produce data or EOF within the prompt-ingestion timeout, fail with
  wrapper exit code `2` and a concise hint to pass `--prompt-file` or positional task text. This
  timeout is only for prompt ingestion and is separate from long Codex reasoning time.
- Initial defaults: first byte or EOF within 2 seconds, then no-progress timeout of 5 seconds while
  reading. These limits may become flags later, but Phase 1 must not allow an unbounded stdin read.
- Empty redirected stdin means zero characters. It does not count as a valid prompt.

Prompt-source validation:

- Count explicit sources first, then materialize PowerShell pipeline input if present, then read
  OS-level redirected stdin only if no other prompt source has been selected.
- Exactly one non-empty source is valid.
- Empty pipeline or redirected stdin may be ignored only after it has been fully read and confirmed
  empty without exceeding the prompt-ingestion timeout.
- Do not block waiting for interactive console input or for an inert redirected pipe. Human
  interactive use should pass `--prompt-file` or positional task text.

## PowerShell And Encoding Contract

The wrapper should target PowerShell 7+ first. Windows PowerShell 5.1 may work only if explicitly
verified.

Encoding rules:

- Write `prompt.md`, `command.txt`, `debug.json`, `status.json`, logs, and event files as UTF-8.
- Do not set `[Console]::InputEncoding` unconditionally. In redirected or non-interactive handles it
  can throw `The handle is invalid` and break the preferred stdin use case.
- `$OutputEncoding` may be set to UTF-8 at process start. `[Console]::OutputEncoding` may be set only
  in a guarded best-effort block; failures must not abort prompt reading.
- For PowerShell object pipeline input, rely on the already-materialized PowerShell objects and do
  not touch console input encoding.
- For OS-level redirected stdin, do not use `[Console]::In` because it can depend on the active
  console/OEM code page. Read bytes from the standard input stream and decode explicitly as UTF-8,
  with BOM detection if available.
- Pass prompt content to Codex through stdin bytes or a UTF-8 temporary input stream; avoid shell-quoted inline prompt text.
- Preserve Traditional Chinese prompt text exactly in `prompt.md`; Phase 1 verification must include
  a redirected-stdin test containing Traditional Chinese, not only English text.

## Worker Prompt Contract

The wrapper prepends a small contract before invoking Codex. The contract should be short and
mode-specific.

Common rules:

```text
You are a background Codex worker called by Claude.
Answer the requested task directly.
Return only the final useful response in your last message.
Do not ask the user follow-up questions unless the task is impossible without them.
Do not modify files unless the access mode explicitly allows it.
For test tasks before worktree support, write screenshots, traces, caches, and logs only under
the artifact directory shown below. Do not modify repository source files.
Artifact directory: <absolute path to %LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\artifacts>
For review tasks, lead with findings ordered by severity.
For test tasks, include commands/actions run, observed result, evidence, and residual risks.
For brainstorming tasks, include options, trade-offs, and a recommendation.
```

The wrapper uses this command shape and feeds the combined contract and task through stdin:

```text
codex --ask-for-approval never exec --sandbox <sandbox> --json --color never -C <repo> --output-last-message <job_dir>/result.md -
```

`--ask-for-approval` is a top-level Codex option and must appear before `exec`. `--sandbox` is an
`exec` option and appears after `exec`. `--json` records Codex event output for diagnosis while
`result.md` remains the final response that `ccodex` prints back to Claude.

Stdout boundary:

- Raw Codex stdout is JSONL when `--json` is enabled. It must be written only to
  `codex-events.jsonl`.
- `ccodex run`, `ccodex wait`, and `ccodex read` must print only the final `result.md` content to
  their parent stdout on success.
- Failure output to parent stdout/stderr should be concise and human-readable: job id, status,
  exit code, result path, and log/job directory path. Phase 2 commands may also include the
  recommended `debug <job_id>` command. It must not stream raw JSONL events to Claude.
- `stdout.log` is optional and may contain a parsed human-readable event summary, not the raw parent
  stdout contract.

## Mode Semantics

`--mode` controls the worker prompt contract. `--access` controls what Codex is allowed to do.
The wrapper validates the pair instead of letting modes silently imply unsafe permissions.

| Mode | Default access | Notes |
|---|---|---|
| `review` | `read-only` | Review code, plans, or diffs. No edits. |
| `brainstorm` | `read-only` | Produce options, trade-offs, and recommendation. No edits. |
| `test` | none; caller must choose | Browser tests need artifact writes. Before worktree support, `--access workspace` is a high-risk exception and must be paired with an artifact-only policy. Use `--access worktree` later. |
| `implement` | `worktree` in future only | Not available until Phase 4 worktree isolation exists. |

`ccodex run --mode test` without `--access workspace` should fail in Phase 1 instead of pretending
read-only browser testing will be reliable. Even with `--access workspace`, the wrapper must create
`<job_dir>/artifacts/` before invoking Codex and inject its absolute path into the worker prompt.
The prompt must instruct Codex to write test artifacts only under that absolute artifact directory
and not modify repository source files. For Playwright tasks, the wrapper should also provide
artifact-scoped output/cache/temp locations, such as `PLAYWRIGHT_OUTPUT_DIR`, `TMP`, and `TEMP` when
safe for the platform. This is a prompt and environment policy, not a sandbox guarantee; Phase 4
worktree isolation is required before edit-capable test or implementation workers become routine.

## Exit Code Contract

`ccodex` should use stable wrapper exit codes so Claude can distinguish usage errors, Codex
failures, timeouts, and missing results without parsing prose.

| Code | Meaning |
|---|---|
| `0` | Success; final result printed to stdout. |
| `2` | Usage or validation error, including invalid mode/access or multiple prompt sources. |
| `3` | Job not found. |
| `4` | Job exists but is not terminal yet, so no final result is available. |
| `10` | Codex process exited nonzero. |
| `11` | Codex exited zero but `result.md` is missing or empty. |
| `12` | Wrapper internal I/O or serialization failure. |
| `20` | `wait --wait-timeout-sec` expired; job lifecycle is unchanged. |
| `21` | Per-job lock acquisition timed out. |
| `22` | Job was cancelled. |
| `23` | Requested backend is unavailable or failed to start. |
| `24` | Job-level hard timeout terminated the worker. |

Terminal job state in `status.json` remains the durable source of truth. Exit codes in this table
are wrapper exit codes for the current `ccodex` command invocation.

Codex process exit codes must be named separately:

- `exit_code.txt` stores only the raw Codex process exit code.
- `status.json.codex_exit_code` stores the raw Codex process exit code when known.
- `status.json.wrapper_exit_code` stores the wrapper classification code when useful for debugging.
- Do not use a generic `exit_code` field in new status schemas because it is ambiguous.

## CLI Commands

### `run`

Synchronous execution for short or medium tasks.

Phase 1 minimum flow:

```text
1. Create job_id and atomically reserve the job directory.
2. Read task from exactly one prompt source.
3. Write prompt.md, command.txt, debug.json, and initial status.json.
4. Invoke codex --ask-for-approval never exec --sandbox <sandbox> --json --color never -C <repo> --output-last-message <job_dir>/result.md -.
5. Redirect raw Codex stdout to codex-events.jsonl and stderr to stderr.log; do not stream raw Codex stdout to Claude.
6. Write exit_code.txt immediately after the Codex process exits.
7. Write worker-complete.json as best-effort completion evidence, whether the Codex result is
   successful, missing, empty, or nonzero.
8. Validate result.md and derive final status plus wrapper exit code.
9. Rewrite worker-complete.json with the final status candidate if validation changed it, then write
   final status.json.
10. Print result.md to parent stdout on success; otherwise print a concise failure with the job id and path.
11. Exit with the stable wrapper exit code.
```

Phase 1 does not require heartbeat, health transitions, lock handling, `debug`, `tail`, background
monitoring, or orphan recovery. Those are Phase 2 behaviors. Phase 1 may still write simple
`status.json` values such as `running`, `done`, or `failed` for inspection.

Default access: `read-only`.

This is the default path for:

- plan review
- code review without edits
- second-opinion brainstorming
- quick investigation

### `submit`

Asynchronous execution for long tasks or parallel delegation.

Flow:

```text
1. Create job_id and job directory.
2. Write prompt.md and status.json.
3. Start the selected background backend running the same internal execution flow as run.
4. Print job_id and job path to stdout.
5. Exit immediately.
```

Default access: `read-only`. Playwright/browser tests must be submitted with `--access workspace`
until worktree support exists.

This is the default path for:

- Playwright browser tests with explicit workspace access
- long verification runs
- multiple parallel Codex workers
- future implementation tasks in isolated worktrees

### `status`

Reads `status.json` and prints a compact lifecycle state plus health:

```text
<job_id> created health=unknown
<job_id> running health=ok
<job_id> running health=stale
<job_id> done codex_exit_code=0 wrapper_exit_code=0
<job_id> failed codex_exit_code=1 wrapper_exit_code=10
<job_id> timed_out
<job_id> cancelled
```

`status` is lifecycle. `health` is diagnostic. Quiet model reasoning should change `health` to
`stale`, not change lifecycle `status` away from `running`.

`status.json` must be written atomically by writing a temporary file and renaming it into place.
Phase 2 minimum fields are below. Phase 1 may write a smaller subset with `schema_version`,
`ccodex_version`, `job_id`, `status`, `mode`, `access`, `repo`, timestamps,
`codex_exit_code`, `wrapper_exit_code`, and `error`.

```json
{
  "schema_version": 1,
  "ccodex_version": "0.1.0",
  "job_id": "20260703T073012Z-k4p9x2qa-review",
  "status": "running",
  "health": "ok",
  "warnings": [],
  "mode": "review",
  "access": "read-only",
  "backend": "sync",
  "backend_id": null,
  "parent_pid": 12345,
  "child_pids": [23456],
  "process_start_time": "2026-07-03T15:30:13+08:00",
  "command_hash": "sha256:...",
  "repo": "D:\\Work\\Code\\Quotation\\Docker",
  "created_at": "2026-07-03T15:30:12+08:00",
  "started_at": "2026-07-03T15:30:13+08:00",
  "last_heartbeat_at": "2026-07-03T15:30:43+08:00",
  "last_stdout_at": "2026-07-03T15:30:40+08:00",
  "last_stderr_at": null,
  "finished_at": null,
  "terminated_at": null,
  "cancelled_at": null,
  "startup_timeout_sec": 120,
  "idle_warn_sec": 900,
  "hard_timeout_sec": 0,
  "timeout_reason": null,
  "codex_exit_code": null,
  "wrapper_exit_code": null,
  "error": null
}
```

`command_hash` is the SHA-256 hash of the normalized command descriptor, not of the prompt. The
descriptor includes the resolved Codex executable path, Codex arguments, repository or worktree path,
mode, access, backend, wrapper version, and selected artifact/result paths. It is used to compare
`status.json`, `debug.json`, and `command.txt` during diagnosis. PID reuse protection still depends
on pid plus process start time; `command_hash` is supporting evidence, not the primary identity
check.

For background jobs, `backend_id` stores the tmux session name or native process id. `status` must
not stay `running` forever if the backend process/session no longer exists. Recovery must inspect
`worker-complete.json`, `exit_code.txt`, and `result.md` before deciding whether the job finished
successfully, failed, or crashed. `exit_code.txt` is the raw Codex process exit code; recovery maps
it to `status.json.codex_exit_code` and a wrapper classification in `status.json.wrapper_exit_code`.

Lifecycle transitions:

```text
created -> running
running -> done | failed | timed_out | cancelled
created -> failed | cancelled
```

`health` may move between `ok` and `stale` only while `status` is `running`. Terminal states
(`done`, `failed`, `timed_out`, `cancelled`) do not return to running.

Concurrent status updates require a per-job lock in Phase 2. Use an atomic lock directory under the
global job directory: `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\.lock\`.

Lock rules:

- Acquire by creating the lock directory atomically.
- Write `.lock/owner.json` with pid, process start time, command name, hostname, and acquired time.
- Default lock acquisition timeout is 10 seconds; timeout returns exit code `21` and must not guess
  or partially rewrite `status.json`.
- A lock is stale only when the recorded owner process is not alive or the recorded process start
  time no longer matches, and the lock age is above the stale threshold. Default stale threshold is
  10 minutes.
- Do not remove a lock owned by a live process.
- After acquiring the lock, write status to a temporary file in the same directory and atomically
  rename it over `status.json`.

## Debug And Observability

Debugging is part of the contract. Every job must leave enough evidence to answer: what command
ran, where it ran, whether the process is still alive, when output last changed, and where to look
next.

Files:

| File | Purpose |
|---|---|
| `command.txt` | Exact Codex command after wrapper expansion, with secrets redacted if any are ever added. |
| `debug.json` | Wrapper version, PowerShell version, OS, repo path, selected backend, access/mode, timeout, pid, and allowlisted environment summary. |
| `codex-events.jsonl` | Codex `--json` event stream captured from raw Codex stdout. Never print this stream to Claude stdout. |
| `stdout.log` | Optional parsed human-readable summary derived from events; raw stdout with `--json` belongs in `codex-events.jsonl`. |
| `stderr.log` | Codex/runtime warnings, sandbox errors, and process failures. |
| `exit_code.txt` | Raw Codex process exit code, written immediately after the process exits and before final status update. |
| `worker-complete.json` | Completion sentinel with job id, status candidate, raw Codex exit code, wrapper exit code when known, result presence, and completed timestamp. |
| `status.json` | Machine-readable lifecycle state and timestamps. |

Phase 2 may enhance `run` so it uses the same monitored child-process path as background workers.
That enhancement should update `last_heartbeat_at`, health, and last-output timestamps. It is not
required for the Phase 1 minimum synchronous wrapper.

`debug.json` environment data must be allowlisted. Do not dump environment variables. Allowed
fields include PowerShell edition/version, OS description, process architecture, resolved `codex`
path, Codex version, repo path, job path, selected backend, mode/access, and resolved optional
backend executable paths. If future diagnostics need environment variables, record only variable
names or redacted values.

Timeout behavior must account for legitimate long model reasoning. Lack of output is not enough to
kill a job.

- `--wait-timeout-sec <n>` applies only to the `wait` command. If it expires, `wait` exits and reports the current job status/health; it must not change job lifecycle status.
- `--hard-timeout-sec <n>` is job-level. `0` means no automatic hard timeout. Only job-level hard timeout can move lifecycle status to `timed_out`.
- `--startup-timeout-sec <n>` detects no process output shortly after launch; it sets `health=stale` and appends a warning, but does not kill the process by itself.
- `--idle-warn-sec <n>` detects no stdout/stderr/event updates after prior activity; it sets `health=stale` or appends a warning, but does not kill the process by itself.
- Phase 2 monitoring defaults should avoid automatic termination: review/brainstorm `hard_timeout_sec=0`, test `hard_timeout_sec=0`; startup warning 120 seconds; idle warning 900 seconds. Users may pass a nonzero hard timeout explicitly. Phase 1 does not need startup or idle monitoring.
- On job-level hard timeout, `status.json.status` becomes `timed_out`, `timeout_reason` is recorded, and logs/artifacts are kept.
- If hard timeout termination is enabled, the wrapper must terminate the process tree and record `terminated_at`. If termination is disabled, the wrapper must not mark `timed_out`; it should keep `status=running` with `health=stale` and warning details.
- If no `result.md` exists, stdout should report the job id, status, health, and recommended debug command.

Debug commands:

```powershell
ccodex tail <job_id>       # print recent stderr/stdout/events
ccodex debug <job_id>      # summarize status, command, pid/backend, last output, and log paths
ccodex cancel <job_id>     # cancel a running job and preserve logs/artifacts
ccodex doctor              # check codex availability, version, --output-last-message, --json, repo path, and optional tmux/native backend support
```

`debug <job_id>` should not require reading the whole log. It should print a compact diagnosis:
current status, health, warnings, elapsed time, pid/backend liveness, process start time, command
hash, last heartbeat, last stdout/stderr timestamps, last stderr lines, result path, and next
command to run.

Stuck-job detection:

- If the process/session no longer exists while `status=running`, first inspect completion
  evidence. If `worker-complete.json` indicates success and `result.md` is non-empty, mark `done`.
  If `exit_code.txt` exists with `0` and `result.md` is non-empty, mark `done`. If `exit_code.txt`
  is nonzero or the completion sentinel reports failure, mark `failed` and preserve the raw Codex
  exit code separately from the wrapper exit code. Only mark missing-process jobs as crashed when no
  valid completion evidence exists.
- If startup or idle warning thresholds are exceeded while the process still exists, set `health=stale`, append a warning, and keep waiting.
- If job-level hard timeout is exceeded and termination is enabled, terminate the process tree, mark `timed_out`, set `terminated_at`, and record `timeout_reason`.
- If job-level hard timeout is disabled (`hard_timeout_sec=0`), never mark `timed_out` solely because of time; keep `status=running`, set `health=stale`, and append warnings.
- If `codex-events.jsonl` has events but `result.md` is missing, report that Codex ran but did not
  emit a final message.
- If neither stdout nor stderr changed after process start, report likely startup/auth/path/sandbox
  failure and point to `debug.json` and `command.txt`.
- `status`, `wait`, and `debug` should all perform orphan recovery before printing: reconcile process/backend liveness with `status.json` and update stale or impossible states under the per-job lock.

Cancellation:

- `cancel <job_id>` marks a running job as `cancelled`, records `cancelled_at`, and preserves logs/artifacts.
- Cancellation must terminate the process tree when using the native backend, not only the parent process. The native backend should record parent pid, known child pids, process start time, and command hash; cancellation should use a Windows job object when available, falling back to CIM/WMI process-tree traversal with the recorded start time to reduce PID-reuse risk.
- Cancelling a completed job is a no-op with a clear message.

Result validation:

- Raw Codex exit code 0 with missing or empty `result.md` is `failed` with wrapper exit code `11`.
- Error events in `codex-events.jsonl` or auth/sandbox/approval keywords in stderr should be surfaced by `debug` even when a result exists.
- `doctor` should run a tiny smoke test that asks Codex to reply `OK`, verifying auth, stdin, `--json`, `--output-last-message`, sandbox, and job-dir writes.

Concurrency and retention:

- Phase 2 should enforce a conservative concurrency limit before launching jobs: review/brainstorm 2-3, test 1, implement 1.
- If the limit is reached, `submit` fails fast or queues only after an explicit future queue design.
- Logs should have size limits, and `tail` should read only recent lines/bytes.
- Add future cleanup support such as `cleanup --older-than 14d` once job volume makes retention painful.

## Background Backend Contract

Phase 2 should support an explicit backend parameter instead of assuming tmux is always available:

```powershell
ccodex submit --backend native --mode test --access workspace
ccodex submit --backend tmux --mode test --access workspace
```

`native` is the recommended first backend on Windows. It should launch a detached PowerShell process
that calls an internal worker entrypoint:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File <absolute-install-path>\ccodex.ps1 worker --job-id <job_id>
```

`submit` must launch the detached process with the recorded `repo_root` as the working directory and
use an absolute installed script path in the command. Relying on a project-local relative script path
is invalid for the native backend.

`worker` is not a Claude-facing command. It resolves the job directory from the global
`%LOCALAPPDATA%\ccodex\index\<job_id>.json`, reads `prompt.md`, `status.json`, and job metadata from
that global job directory, then runs the same Codex execution flow as `run` against the recorded
`repo_root`. `submit` must not pass prompt text, long task flags, or repo discovery state on the
background command line. This avoids reintroducing quoting, command-length, and encoding problems.

The native backend must record parent pid, known child pids, process start time, repo root, working
directory, absolute installed script path, and command hash in `status.json`/`debug.json`.

Windows detachment requirements:

- `submit --backend native` must verify that the worker survives after the submitting wrapper process
  exits.
- On Windows, account for parent processes running inside a Job Object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, which can otherwise kill child workers when the caller exits.
- Prefer a launcher that uses `CREATE_BREAKAWAY_FROM_JOB` when allowed, then places the worker in a
  new wrapper-owned Job Object for later cancellation. If breakaway is not available, the backend
  must fail fast with wrapper code `23` or fall back to a verified backend such as tmux.
- Starting a detached PowerShell process without proving breakaway/survival is not sufficient for
  Phase 2 verification.
- `cancel <job_id>` must still be able to terminate the worker process tree after successful
  detachment.

`tmux` is valid only when these are defined and verified:

- which shell owns tmux (native Windows, MSYS2, Cygwin, WSL, or another environment)
- how the resolved `repo_root` maps into that shell
- how PowerShell script invocation is encoded and quoted
- the tmux session name format
- the working directory used by Codex inside the tmux session

The result channel is still `result.md` and `status.json`. `tmux capture-pane` is debug-only.

### `wait`

Polls `status.json` until the job finishes or `--wait-timeout-sec` is reached. On success, it should print
the final result to stdout by default so Claude can use it like a synchronous command. If wait times out,
it exits with a wait-timeout code and prints the current status/health and debug command, but it must not
change the job lifecycle status.

### `read`

Prints `result.md` for an existing job. Failure behavior:

- Unknown `job_id` exits with wrapper code `3`.
- If the job is not terminal yet, exit with wrapper code `4` and print a concise status/debug hint instead of blocking. The command
  should include current lifecycle status, health if present, result path, and the recommended
  `wait <job_id>` or `debug <job_id>` command.
- If the job is terminal and `result.md` is missing or empty, exit with wrapper code `11`.

### Future: `diff` / `apply`

Only after worktree isolation exists:

```powershell
ccodex diff <job_id>
ccodex apply <job_id>
```

`apply` must remain explicit. Codex workers should not silently merge changes into Claude's main
workspace.

## Access Modes

### `read-only`

Codex may inspect, review, brainstorm, and run safe read-only checks. It must not edit files.

Use for Phase 1 and most `/ccodex` interactions.

Codex CLI mapping:

```text
codex --ask-for-approval never exec --sandbox read-only ...
```

If a task needs browser testing, artifact generation, dependency execution, or file edits, Claude
must choose a broader access mode explicitly.

### `workspace`

Codex technically may edit the current workspace because this maps to Codex `workspace-write`.
This mode is risky and should be reserved for a single worker doing a focused task when Claude is
not editing the same files.

For `test` mode before worktree support, `workspace` is allowed only so tools can write artifacts
and caches. The wrapper must create the absolute artifact directory before launch, inject it into the
worker prompt, and route screenshots, traces, logs, caches, and temporary output there where the tool
supports it. The worker prompt must prohibit repository source edits. This is policy guidance, not a
hard filesystem boundary.

This should not be the default.

Codex CLI mapping:

```text
codex --ask-for-approval never exec --sandbox workspace-write ...
```

### `worktree`

Codex gets an isolated git worktree for the job and may edit there. Claude reviews the diff and
explicitly applies changes.

Codex CLI mapping for Phase 4 is expected to remain `--sandbox workspace-write`, but `-C` points to
the isolated worktree path instead of the main repository. The wrapper must record both `main_repo`
and `worktree_repo` in job metadata so `diff` and `apply` can compare the correct directories.

This is the recommended mode for future implementation delegation.

## Slash Command Integration

Create or update a Claude command only after `run` works. Prefer a user-level Claude command so all projects can use the same `/ccodex` behavior; a project-local command is only needed for project-specific policy:

```text
.claude/commands/ccodex.md
```

The command should instruct Claude to:

```text
1. Summarize the target task clearly.
2. Pipe the task into `ccodex run` or `ccodex submit` from the current project directory.
3. Read stdout.
4. Merge Codex's response into Claude's own answer.
5. Keep Claude responsible for final judgment.
```

For long or explicitly parallel tasks, Claude may choose `submit`, then `wait/read`.

## Existing Codex Integration Compatibility

Before Phase 1 implementation, inventory existing Claude-to-Codex mechanisms available in the target
Claude environment, including any `codex:*` skills or agents such as `codex:codex-rescue`,
`codex:rescue`, `codex:setup`, or `codex:codex-cli-runtime` if present.

`ccodex` should not silently replace those mechanisms. Its default product boundary is narrower: a
global user-level CLI wrapper around noninteractive `codex exec`, with explicit global job
directories, debuggable result files, project discovery, and Claude-readable stdout.

Implementation must document one of these outcomes before building beyond Phase 1:

- Reuse or adapt an existing Codex bridge if it already provides the same prompt transport, result
  channel, job state, and debug behavior.
- Keep `ccodex` as a separate global CLI only for tasks where the existing bridge lacks a
  stable command/result contract.
- Deprecate or replace an existing bridge only after an explicit user decision.

**Decision (2026-07-04):** keep `ccodex` as a separate global CLI (outcome 2). The Claude
environment's existing bridge (the `codex` plugin's `codex:codex-rescue` subagent /
`codex:rescue` skill) is session-embedded procedural guidance around a shared runtime: it has no
stable command/exit-code contract, no global job directories, no debuggable per-job artifacts, and
is not pipeable from arbitrary project directories. `ccodex` provides exactly that layer and does not
replace the plugin; the two coexist (plugin for in-session rescue flows, `ccodex` for stable
delegation with job state). Re-evaluate after Phase 3 usage stabilizes.

This gate prevents two independent Claude-to-Codex bridges from evolving conflicting conventions for
permissions, job storage, logs, and result handoff.

## Skill Decision

Do not create a Codex skill in Phase 1.

A future skill may be useful after the CLI stabilizes. Its purpose would be procedural guidance for
when and how an agent should use `ccodex` for second-opinion review, browser testing, brainstorming,
or implementation delegation.

The skill should not contain the core implementation. The CLI remains the source of operational
truth. Re-evaluate a skill after Claude/Codex usage patterns stabilize and the main need is
procedural guidance rather than tool behavior.

## MCP Decision

Do not create an MCP server in the first version.

MCP becomes useful only if `ccodex` needs a structured tool surface for listing jobs, reading
artifacts, cancelling workers, applying diffs, or sharing a worker pool across projects and
sessions. The current need is a command Claude can execute and read, so a CLI is the simpler and
more debuggable boundary. Re-evaluate MCP when job metadata and artifact operations become common
enough that parsing CLI text becomes fragile.

## EXE Decision

Do not package an `.exe` in the first version.

Use a PowerShell script first because:

- the current environment already uses PowerShell heavily
- it is easier to inspect and patch
- phase-by-phase validation is faster
- packaging can wait until the command contract is stable

An `.exe` or shim can be added later if the command needs to be called from environments where
PowerShell script execution is inconvenient, or if non-PowerShell callers become a real use case.

## Phased Delivery

### Phase 1: Synchronous CLI

Implement:

```text
user-level ccodex command on PATH
user-level default worker prompt template under %APPDATA%\ccodex\templates\worker-prompt.md
optional project-local .ccodex/worker-prompt.md override
```

Verification:

- `ccodex` is callable from `PATH` in at least two different project directories without copying the
  wrapper into either repository.
- Long multiline prompt can be passed through PowerShell pipeline stdin.
- OS-level redirected stdin can pass a long multiline prompt and preserves Traditional Chinese text
  exactly in `prompt.md`.
- If `--prompt-file` or positional task text is provided, the wrapper does not probe OS-level stdin;
  an inert redirected stdin pipe must not hang the command before Codex is invoked.
- OS-level redirected stdin enforces prompt-ingestion limits: first byte or EOF within 2 seconds and
  no-progress timeout of 5 seconds while reading.
- Redirected stdin that produces neither data nor EOF within the prompt-ingestion timeout exits with
  wrapper code `2` and a concise hint to use `--prompt-file` or positional task text.
- Empty stdin is rejected unless exactly one non-stdin prompt source is provided.
- `codex exec` receives the task and returns a clean final response.
- Wrapper captures the final response via `--output-last-message`.
- Raw Codex JSONL stdout is captured to `codex-events.jsonl` and is not printed to Claude.
- Wrapper prints only `result.md` to parent stdout on success.
- Wrapper writes `prompt.md`, `result.md`, `status.json`, `command.txt`, `debug.json`,
  `codex-events.jsonl`, `stderr.log`, `exit_code.txt`, and `worker-complete.json`.
- `worker-complete.json` is written on success and failure paths after Codex exits.
- Review/brainstorm modes invoke `codex --ask-for-approval never exec --sandbox read-only ...`.
- `--mode test` without `--access workspace` fails before invoking Codex.
- `--mode test --access workspace` includes the absolute artifact directory in the prompt and writes
  browser artifacts under `<job_dir>/artifacts/`.
- Jobs are written under the global user-level state root, not under the current repository.
- Optional project-local `.ccodex/worker-prompt.md` overrides the user-level template when present;
  normal runtime does not modify `.gitignore` or source files.
- Wrapper exit code follows the stable exit code contract, while Codex process exit code is stored
  separately as `codex_exit_code`.
- No heartbeat, health monitoring, locks, debug/tail commands, orphan recovery, background backend,
  or tmux required.

### Phase 2 scope amendment (2026-07-04)

Phase 2 is split into two increments so the riskiest platform assumption (detached worker
survival on Windows) is proven inside the smallest useful product loop. Inputs to this decision:
a live second-opinion round-trip through `ccodex run --mode brainstorm` itself (Codex advised
shipping a narrow "async result channel" first and deferring even `cancel` until process-tree
ownership is reliable), plus two local feasibility probes (a detached `pwsh` child survived its
parent's exit via plain `Start-Process`, and `Win32_Process.Create` via CIM launches workers
outside the caller's Job Object by construction).

**Phase 2a — async result channel (next):**

```text
ccodex submit                      # native backend only
ccodex worker --job-id <job_id>    # internal only
ccodex status <job_id>
ccodex wait <job_id>
ccodex read <job_id>
```

- Native backend launches the worker through CIM `Win32_Process.Create` (parented outside the
  caller's Job Object) with `Start-Process` as a test/fallback mechanism, then verifies survival
  through a startup sentinel: the worker must move `status.json` off `created` within the startup
  window or `submit` fails with wrapper code `23`.
- Single-writer status discipline instead of locks: after launch only the worker mutates
  `status.json` (always via atomic temp-file + rename). `status`/`wait`/`read` are read-only,
  except a narrowly gated orphan reconciliation: rewrite terminal state only when status is
  `running`, the recorded worker (pid + process start time) is definitely gone, AND completion
  evidence (`worker-complete.json` / `exit_code.txt` + `result.md`) exists; otherwise report
  "possibly stale" without writing. The per-job `.lock` directory is deferred to Phase 2b when
  multiple writers (cancel, monitors) appear.
- `status.json` keeps the Phase 1 field set plus `backend`, `backend_id` (`<pid>;<start-time>`),
  `started_at`, and `finished_at`. Deferred to 2b: `health`, `warnings`, pid lists,
  `command_hash`, heartbeat/output timestamps, timeout fields, `terminated_at`, `cancelled_at`.
- Wrapper exit codes added in 2a: `3` (job not found), `4` (not terminal yet), `20` (wait
  timeout), `23` (backend failed to start/survive). Still out of scope: `21`, `22`, `24`.

**Phase 2b — operability (later):** `cancel` (process-tree termination with pid+start-time
identity), `tail`, `debug`, `doctor`, per-job locks, heartbeat/health/staleness, retention.

Phase 3's user-level `/ccodex` Claude command ships with 2a (it is a thin procedural file and is
what makes both product goals — delegation and second opinions — usable from any project).

Future note: `codex exec resume <session-id>|--last` exists in codex-cli 0.142.5; a multi-turn
"discussion" mode reusing a worker's Codex session is a candidate for a later phase once job
metadata records the Codex session id.

### Failure-mode handling amendment (2026-07-05)

User requirement: the wrapper must handle Codex-side failure modes first-class — quota/rate-limit
exhaustion, Codex stalling on a question/approval, permission problems, hangs — so Claude can act
on a failure without reading logs.

| Failure mode | Detection | Wrapper behavior |
|---|---|---|
| Quota / rate limit exhausted | nonzero exit + stderr/events signature (`usage limit`, `rate limit`, `quota`, `429`) | status `failed`, exit `10`, `status.json.failure_reason = "quota_or_rate_limit"`, hint: report to user, do not auto-retry |
| Auth broken / logged out | signature (`login`, `auth`, `401`, `unauthorized`, `credential`) | `failed`/`10`, `failure_reason = "auth"`, hint `codex login` |
| Sandbox / permission denial | signature (`sandbox`, `denied`, `approval`, `permission`) | `failed`/`10` (or `11`), `failure_reason = "permission_or_sandbox"`, hint: consider `--access workspace` or narrow the task |
| Network failure | signature (`network`, `connection`, `dns`, `502`, `503`) | `failed`/`10`, `failure_reason = "network"`, hint: one retry is safe |
| Codex waits for interactive input | prevented by construction: `--ask-for-approval never` + wrapper closes stdin after writing the prompt (Codex sees EOF). A clarifying *question as the final answer* is a valid `done` result; future `codex exec resume <thread_id>` can answer it in-session | documentation only |
| Codex hangs (no exit) | job-level `--hard-timeout-sec <n>` (default `0` = never) | on expiry: kill the process tree, status `timed_out`, `timeout_reason`, `terminated_at`, wrapper exit `24`; artifacts kept |
| Codex CLI missing / not launchable | `Resolve-CcodexCodexPath` failure | `failed`/`12` with completion evidence — including in `submit`, which must write a terminal failed `status.json` + `worker-complete.json` before returning (a job must never sit at `created` after a known-fatal internal failure) |
| Worker dies without evidence | narrow orphan reconciliation (2a; #24c) | parsable evidence → terminal state; **absent** `exit_code.txt` on a provably-gone worker → terminal `failed`/`10` (a dead process writes nothing more, so no evidence can ever appear — leaving it non-terminal would hang `wait`/`wait --all` forever); a **present-but** corrupt/empty `exit_code.txt` is mid-finalize → `possibly-stale` (never raced to a fabricated terminal), never an uncaught throw |
| Empty/missing result with exit 0 | 2a validation | `failed`/`11` |

Contract points: `failure_reason` is a conservative, append-only HINT (may be absent); exit codes
stay authoritative. Signatures match case-insensitively over the tail of `stderr.log` and
error-bearing events. `status.json.codex_thread_id` is captured from the `thread.started` event
(success and failure) to enable future `codex exec resume` integration and post-mortem debugging.
This amendment pulls exit code `24` and status `timed_out` forward from Phase 2b; `21`/`22` stay
out of scope. Phase 2b `ccodex doctor` should delegate to the built-in `codex doctor` plus
wrapper-specific checks.

A live dogfood review of Phase 2a (run through `ccodex run --mode review` itself, 2026-07-05)
contributed two of these requirements: the `submit` stuck-at-`created` fix and the
corrupt-evidence reconciliation guard. Its third finding (Start-Process stdout inheritance) was
triaged as a false positive (`-WindowStyle Hidden` allocates a separate hidden console) and is
addressed by a code comment plus the existing E2E stdout-exactness assertions; its fourth
(embedded quotes in CIM command lines) is guarded with a clear error since Windows paths cannot
contain quotes.

#### Precision-over-recall refinement (2026-07-20, backlog #15)

This amendment refines the signature lists in the table above. The five `confidence: low` bare
tokens — quota `429`, auth `auth` and `401`, network `502` and `503` — are **removed** from the
ordered signal table (`lib/FailureClassify.ps1`). They matched incidental text in `stderr.log` or
embedded command output (e.g. a request id containing `502`, an unrelated `429` substring),
stamping a wrong `failure_reason` that steers the caller's documented reaction — a
misclassification is worse than no classification. Effective signatures are now:

| Class | Surviving signatures |
|---|---|
| `quota_or_rate_limit` | `usage limit`, `rate limit`, `quota` |
| `auth` | `login`, `unauthorized`, `credential` |
| `permission_or_sandbox` | `sandbox`, `denied`, `approval`, `permission` |
| `network` | `network`, `connection`, `dns` |
| `thread_expired` | `session not found`, `thread not found`, `no session`, `conversation not found` |

A failure matching only a removed token now yields **no** signal (`failure_reason`/`failure` stay
`null`), and the caller falls back to the documented "exit `10` with no `failure_reason`" path
(read the recorded error — the job's `stderr.log`, plus the stderr tail included in synchronous
failure output; `status.json.error` is generally `null` for async Codex failures — and use
judgment, don't retry-loop). Class order and precedence (thread_expired > quota > auth > permission
> network) are unchanged, as is the never-throws / degrade-to-null discipline and the generic
HTTP-code regex extraction (surviving rows still attach an `http_code`, and `unauthorized` keeps
its static `401` fallback). Contract-preserving: the `failure` object schema
(`reason`/`matched_signal`/`source`/`confidence`/`http_code`) and the `failure_reason`
compatibility field are unchanged (append-only); `confidence` simply never takes the value `low`
for newly written jobs — historical `status.json` files may still carry `low` and it remains a
weak signal when read. The surviving `medium` literals (`login`, `denied`, `permission`,
`network`, `connection`) are still unbounded substring matches with residual false-positive risk;
retaining them is an accepted scope decision, not a collision-free guarantee.

### Scoped review and delegation policy (2026-07-05)

User use cases: (1) after Claude completes a feature/fix, optionally have Codex review exactly
those changes scoped to paths or a submodule (the existing Claude-side codex plugin cannot scope
reviews); (2) reduce Claude-token consumption and the user's per-instance decision burden by
routing codex-suitable work via predefined policy, without meaningfully lowering quality.

Scoped review:

- Submodule scoping works by construction: a submodule is a repository, so `--repo
  <submodule-path>` targets it directly.
- Path scoping strategy: instruct Codex to generate the diff ITSELF inside its read-only sandbox
  (`git diff <base>..<head> -- <paths>`) — Codex demonstrably executes read-only commands there.
  This gives exact scoping, a tiny prompt, and lets Codex open surrounding files for context.
  Fallback `--embed-diff` embeds a size-capped diff for unusual git states.
- New subcommand (sugar over the `run` pipeline, mode `review`, access `read-only`):

```text
ccodex review [--repo <path>] (--range <base>..<head> | --staged | --working)
              [--path <p>]... [--intent "<change intent>"] [--focus "<extra focus>"]
              [--embed-diff]
```

Delegation policy — the USER sets policy once per project; Claude applies it at fixed
checkpoints and stays the final judge; nothing generative is auto-delegated:

- Config in project-local `.ccodex/ccodex.json`:

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

- Fixed checkpoints only (no mid-task auto-routing): (1) after Claude completes a feature/fix,
  before declaring done → `review_after_changes`; (2) after Claude writes/updates a plan or spec
  → `plan_second_opinion`; (3) explicit user request → always honored.
- Semantics: `auto` = run the scoped review at the checkpoint, triage findings (verify each
  before acting), fold into the final report. `ask` = offer a one-keystroke choice. `off` = only
  on explicit request.
- Quality guarantees: codex review is additive (Claude's own tests/self-review still run); Claude
  triages every finding; only review/summary/second-opinion tasks are eligible for `auto`.
- Cost guards: `review_min_changed_lines`, `max_codex_calls_per_task`, and failure-class
  short-circuits (quota → note and skip, never retry-loop).
- A user-level rules file (`~/.claude/rules/ccodex-delegation.md`, installed by `install.ps1`)
  teaches every Claude session the policy so the user never has to re-prompt it.
- Token honesty: savings come from large inputs (diffs/files) flowing to Codex without entering
  Claude's context while Codex returns small findings; `auto` vs `ask` changes decision burden,
  not token cost. Bulk implementation delegation arrives with Phase 4 worktrees.

### Retention, cleanup, and remaining-phase decisions (2026-07-07)

These decisions govern the remaining phases (2b, 4, 5) so that any agent can implement them from
the phase plans alone: `docs/archive/2026-07-07-ccodex-phase2b-plan.md`,
`docs/archive/2026-07-07-ccodex-phase4-plan.md`, `docs/archive/2026-07-07-ccodex-phase5-plan.md`. Recommended
execution order: 2b → 4 → 5 (4 and 5 are independent of each other; both build on 2b's locks and
cleanup).

#### Retention and cleanup (user requirement)

Job state accumulates forever today, and some recorded metadata goes stale — most notably
`codex_thread_id`, which references a Codex-side session that Codex itself eventually prunes, and
which should not be retried by Phase 5 `resume` once expired. Cleanup is a first-class command:

```text
ccodex cleanup [--older-than <Nd|Nh>] [--repo <path>] [--dry-run] [--include-stalled]
               [--scrub-thread-ids] [--thread-ttl <Nd>]
```

- Deletes **terminal** jobs (`done`/`failed`/`timed_out`/`cancelled`) whose end timestamp
  (`finished_at` → `terminated_at` → `cancelled_at` → fallback `created_at`) is older than
  `--older-than`. Default threshold comes from user-level config (below); scope defaults to ALL
  repo keys, narrowed by `--repo`.
- Deletion order per job: index entry first, then the job directory — a crash mid-way leaves an
  unindexed directory that the next sweep still finds (cleanup scans the `jobs/` tree, not the
  index). Dangling index entries (directory already gone) are removed. Phase 4 worktrees belonging
  to a deleted job are removed too (`git worktree remove --force` + `git -C <main_repo> worktree
  prune`, best-effort).
- **Never** deletes a non-terminal job, with one exception: `--include-stalled` first runs the
  existing narrow orphan reconciliation; a job that reconciles to terminal is then eligible, and a
  `running`-with-live-worker or possibly-stale job is always skipped and reported.
- `--scrub-thread-ids`: for RETAINED terminal jobs older than `--thread-ttl`, atomically rewrite
  `status.json` with `codex_thread_id = null` (append-only discipline preserved; all other fields
  untouched). Scrubbing is what makes Phase 5 fail fast with a clear message instead of resuming a
  dead Codex session. Runs under the per-job lock (it is a writer).
- `--dry-run` prints what would be deleted/scrubbed (job id, status, age, size) and changes
  nothing. Without `--dry-run`, cleanup is still non-interactive (no prompts) — it is a
  maintenance command invoked deliberately.
- Output: one summary line (jobs deleted, bytes reclaimed, dangling indexes removed, thread ids
  scrubbed, jobs skipped+why). Exit `0` on full success, `2` on usage errors (bad duration
  syntax), `12` if any individual deletion/rewrite failed (best-effort: keep going, report
  failures, then exit 12).
- User-level config `%APPDATA%\ccodex\config.json` (location reserved since Phase 1) gains its
  first real schema — read with the same tolerant/validated pattern as the project config:

```json
{
  "retention": {
    "jobs_days": 14,
    "thread_ttl_days": 30
  }
}
```

  `--older-than`/`--thread-ttl` override config; config overrides the built-in defaults (14d/30d).

#### Phase 2b scope and ordering decisions

- **Locks activate with the second writer.** Until `cancel` exists, the worker is the only
  status writer post-launch. `cancel` (and cleanup's scrub) introduce concurrent writers, so the
  per-job lock directory (`<job_dir>/.lock/` with `owner.json`, acquisition timeout 10 s → exit
  `21`, stale-lock rules as specified below in "status") lands FIRST in 2b, and every status
  writer (worker terminal write, orphan reconciliation, cancel, scrub) goes through it from then
  on.
- **`cancel <job_id>`** (exit code `22` semantics activate): under the lock, verify the recorded
  worker identity (`backend_id` = pid + process start time) is alive; kill the whole tree
  (`taskkill /PID <pid> /T /F`), mark `cancelled` + `cancelled_at`, preserve artifacts. Cancelling
  a terminal job is a no-op with a clear message (exit 0). A dead-but-`running` job is
  reconciled instead of killed.
- **Heartbeat/health stays single-writer:** the worker stamps `last_heartbeat_at` (~every 30 s)
  on its own status.json; `status`/`debug` only READ and derive `health=ok|stale` (stale = no
  heartbeat for > idle threshold while `running`). Per-stream `last_stdout_at`/`last_stderr_at`
  timestamps are deliberately NOT stored in 2b (streams are captured whole via async reads);
  `debug` uses the event/stderr log files' mtimes as the output-activity proxy. No monitor
  process writes lifecycle.
- **`tail <job_id>`**: last N lines (default 40, `--lines <n>`) of `stderr.log` +
  `codex-events.jsonl`, read via tail-bytes (no full-file loads).
- **`debug <job_id>`**: compact diagnosis — status, health, timestamps, backend liveness,
  failure_reason, thread id presence, result presence, log paths, and the recommended next
  command. Read-only except the same narrow orphan reconciliation `status` already performs.
- **`doctor`**: delegates environment diagnosis to the built-in `codex doctor`, then adds
  wrapper-specific checks (state root writable, template present, `codex` resolvable to a
  launchable `.cmd`/`.exe`, index/jobs tree consistency count) and finishes with one live smoke
  (`codex exec` "reply OK" through the normal run pipeline) unless `--no-smoke`.
- Exit codes `21` and `22` activate in 2b exactly as the contract table defines; no other codes.

#### Phase 4 worktree refinements

- Worktrees live under the global state root, never inside the repository:
  `%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`, created with
  `git -C <main_repo> worktree add --detach <path> <base_commit>` where `base_commit` is the
  repo's HEAD at job creation. `status.json`/`debug.json` record `main_repo`, `worktree_repo`,
  and `base_commit`.
- **Snapshot finalization:** after Codex exits, the worker runs `git add -A` +
  `git commit -m "ccodex: worker output <job_id>"` inside the worktree (identity
  `ccodex-worker <ccodex@local>` via `-c user.name/-c user.email`, `--no-verify` deliberately NOT
  used; empty change set → no commit, recorded as `worktree_dirty=false`). This makes
  `diff`/`apply` deterministic regardless of whether Codex committed anything itself.
- **`diff <job_id>`**: prints `git -C <worktree> diff <base_commit>..HEAD` (stat header first).
  Exit `3`/`4` as usual; `0` with empty output when the worker changed nothing.
- **`apply <job_id>`**: explicit, never automatic. Preconditions: main repo working tree clean
  (else exit `2` with message) and job terminal `done`. Mechanism: `git -C <main_repo> am
  --3way` over `git -C <worktree> format-patch <base_commit>..HEAD --stdout`. On conflict: abort
  the `am`, leave the main repo untouched, exit **`25`** (new code: "apply failed/conflict; job
  artifacts and worktree preserved"). Success prints the applied commit range.
- `--mode implement` and `--access worktree` unlock in Phase 4 (implement defaults to worktree
  access; `review`/`brainstorm` stay read-only; `test --access worktree` becomes the recommended
  replacement for `test --access workspace`).
- Cleanup integration: `cleanup` removes worktrees with their jobs (above); `apply`/`diff` on a
  cleaned-up job exit `3`.

#### Phase 5 multi-turn advisor (`resume`)

- `ccodex resume <job_id>` takes a follow-up prompt through the standard prompt sources (pipe /
  `--prompt-file` / positional) and continues the PARENT job's Codex session via
  `codex --ask-for-approval never exec resume <codex_thread_id> --sandbox <same-as-parent> ...`,
  as a NEW job (fresh job id/dir/artifacts) recording `parent_job_id` and inheriting the parent's
  mode/access/repo. The result channel is unchanged (`result.md` → stdout).
- Preconditions: parent exists (else `3`), parent terminal (else `4`), parent has a non-null
  `codex_thread_id` (else exit `2` with "thread id absent or scrubbed — start a fresh run").
- If Codex rejects the session id (expired/pruned), classification gains
  `failure_reason = "thread_expired"` (signature: session/thread not-found wording in
  stderr/events) with the hint "session expired — start a fresh ccodex run"; wrapper exit stays
  `10`.
- `status` for a resumed job shows `parent=<job_id>`; the `/ccodex` command and delegation rule
  gain the pattern "if Codex's answer is a clarifying question, answer it with `ccodex resume`".
- Thread-ttl interplay: `cleanup --scrub-thread-ids` (2b) is what retires resume-ability;
  `resume` never guesses (`--last` is deliberately NOT exposed — job-addressed sessions only).

### Codex CLI 0.144.1 re-verification amendment (2026-07-13)

The installed codex-cli was upgraded 0.142.5 → 0.144.1. The binding invocation contract was
re-verified live on 2026-07-13 (a real `run --mode brainstorm --effort max` followed by a real
`ccodex resume` of that job, both exit 0) and is **unchanged**:

- The exec shape (`--ask-for-approval never` top-level, then `exec --sandbox <sandbox> --json
  --color never -C <repo> --output-last-message <result.md> [-m <model>]
  [-c model_reasoning_effort=<effort>] [resume <thread_id>] -`) parses and runs as before.
  Top-level `--ask-for-approval` currently accepts `untrusted|on-request|never`.
- The `-c` bare-value literal fallback the `--effort` forwarding relies on is now *documented*
  in codex help ("If it fails to parse as TOML, the raw string is used as a literal").
- The `{"type":"thread.started","thread_id":"<uuid>"}` JSONL event is unchanged; thread capture
  and `exec resume <thread_id>` round-trip live-verified. `exec resume`'s positional is now
  documented as "Conversation/session id (UUID) or thread name" — the wrapper keeps passing the
  captured UUID.
- **Effort enum expanded (contract refinement):** Codex's `ReasoningEffort` is now
  `none|minimal|low|medium|high|xhigh|max|ultra`, plus arbitrary custom strings accepted at the
  config layer (`Custom(String)`). `ConvertTo-CcodexEffort`'s allowlist now mirrors the
  eight-value enum; it stays a fail-fast typo guard precisely *because* Codex itself no longer
  rejects unknown strings. Per-model support varies and is enforced by Codex/the API. The
  allowlist is a mirror, not an independent contract — re-derive it on every Codex upgrade (see
  the `codex-upgrade-check` skill, `.claude/skills/codex-upgrade-check/SKILL.md`).
- Host fact change (recorded authoritatively in the dev notes): the Codex sandbox on the
  development machine can now spawn child processes — the `CreateProcessWithLogonW failed: 1385`
  limitation no longer reproduces, so `ccodex review`'s self-diff form works there again and
  `--embed-diff` is a robustness option rather than a host requirement.
- New upstream surface (unused by the wrapper, noted for awareness): `codex review` /
  `codex exec review`, `codex update`, `codex fork`, `codex sandbox`, plugin/marketplace
  subcommands.

### Phase 2: Background Jobs

Implement:

```text
ccodex submit
ccodex status
ccodex wait
ccodex read
ccodex tail
ccodex debug
ccodex cancel
ccodex doctor
ccodex worker --job-id <job_id>   # internal only
```

Verification:

- `submit` returns immediately with a job id.
- Background backend is selected explicitly: native Windows process backend or tmux.
- If tmux is selected, the spec defines the shell, path mapping, encoding, working directory, and session name.
- Background process/session can finish without interactive input.
- Native backend launches `worker --job-id <job_id>` with repo root as working directory and an absolute installed script path; the worker reads all task data from the global job directory.
- Native backend verifies the worker survives after the submitting wrapper process exits, including when the caller is inside a Windows Job Object with kill-on-close behavior.
- `status` reports lifecycle plus health: created/running/done/failed/timed_out/cancelled and health=ok/stale for running jobs.
- `wait` blocks until done and prints final result; wait timeout returns without changing job lifecycle status.
- `read` prints the saved result.
- `tail` prints recent stdout/stderr/events without loading full logs.
- `debug` explains likely stuck/failure causes from lifecycle status, health, pid/backend, timestamps, and logs without assuming quiet means dead.
- `cancel` stops running jobs, marks `cancelled`, and preserves logs/artifacts.
- `doctor` runs a smoke test, not only a help/version check.
- stdout/stderr/events logs are retained for debugging.

### Phase 3: Claude Slash Command

Implement:

```text
.claude/commands/ccodex.md
```

Verification:

- Claude can invoke `/ccodex` for review and brainstorming through `run`.
- Claude can invoke `/ccodex` for long tasks through `submit` + `wait/read`.
- Claude's final answer clearly separates Codex's findings from Claude's own synthesis when useful.

### Phase 4: Worktree Isolation

Implement only when edit-capable Codex workers are needed.

Verification:

- Codex is invoked with `--sandbox workspace-write` and `-C <isolated-worktree>`, not `-C <main-repo>`.
- A worker can modify an isolated worktree without touching the main workspace.
- `diff` shows only that worker's changes.
- `apply` is explicit and reviewable.
- Conflicts are surfaced to Claude instead of auto-resolved silently.

## Risks And Mitigations

| Risk | Mitigation |
|---|---|
| Claude and Codex edit the same files | Default to `read-only`; use `worktree` for edit-capable workers |
| Codex process output is noisy | Use `--output-last-message`; save raw JSONL only to `codex-events.jsonl`; print only `result.md` for `run/read/wait` |
| Job logs leak sensitive task details | Store jobs under the user-level state root outside repositories; keep prompts, logs, debug metadata, and artifacts out of version control; add cleanup/retention |
| Global tool cannot identify the intended project | Resolve `--repo` first, then git root from current directory; record `repo_root` and `repo_key` in every job; fail fast outside a repo |
| Command length or escaping breaks prompts | Always normalize task content into `prompt.md` and feed Codex through stdin |
| Wrapper hangs while probing an inert redirected stdin pipe | Detect explicit sources first; use bounded first-byte/no-progress timeout on OS-level stdin; fail fast with exit code `2` |
| tmux output is truncated or polluted | Do not use tmux pane output as the result channel |
| tmux is unavailable or path mapping is unclear on Windows | Use a native Windows background process backend first, or block tmux backend until shell/path mapping is specified |
| Codex call is quiet for a long time | Keep lifecycle `status=running`; set `health=stale`/warnings first; only job-level hard timeout may create `timed_out` |
| Codex call hangs with no visible reason | Monitored child process, startup/idle/hard timeout timestamps, `debug <job_id>`, `tail <job_id>`, and retained command/log/event files |
| Background job hangs | `wait --timeout` returns without changing job lifecycle; orphan recovery checks completion sentinels before marking missing sessions/processes as failed |
| Too much infrastructure too early | Phase 1 avoids tmux, daemon, MCP, `.exe`, and worktrees |
| Codex asks follow-up questions in noninteractive mode | Prompt contract tells Codex to make assumptions or return a blocking reason |

## Success Criteria

The design is successful when Claude can use:

```powershell
<task> | ccodex run --mode review
```

and receive a clean Codex review on stdout from any git project directory, with enough global saved
job state to debug failures. Later, Claude should be able to launch background Codex jobs with
`submit`, collect results with `wait` or `read` from the same or a different project directory, and
keep final orchestration authority.













