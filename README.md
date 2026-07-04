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

**Phase 1 (synchronous CLI) is done.** `ccodex run` is implemented and callable end-to-end. See
[`docs/2026-07-03-ccodex-adapter-phase1-plan.md`](docs/2026-07-03-ccodex-adapter-phase1-plan.md)
for the task-by-task build log and [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md)
for the full design across all planned phases.

Implemented so far:

- `ccodex.ps1` — dispatcher; supports the `run` subcommand with `--mode`, `--access`, `--repo`,
  `--prompt-file`, a positional task argument, or a piped/redirected-stdin task
- `ccodex.cmd` — `PATH` shim that forwards to `pwsh -File ccodex.ps1`
- `install.ps1` — copies `ccodex.ps1` + `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes the
  `ccodex.cmd` shim there, and installs the default worker-prompt template to
  `%APPDATA%\ccodex\templates\worker-prompt.md`
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
- `templates/worker-prompt.md` — default worker-prompt contract template
- A full plain-PowerShell test suite under `tests/` (no Pester; see Testing below)

Not yet implemented (Phase 2+): `submit`, `status`, `wait`, `read`, `tail`, `debug`, `cancel`,
`doctor`, background/parallel jobs, alternate backends, and worktree-isolated `implement`
mode / `--access worktree` (Phase 4). Running `ccodex` with any subcommand other than `run`
currently exits 2 with a "not implemented in Phase 1" message. `--mode implement` and
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

`ccodex run` is the only implemented subcommand. It reads task text from exactly one of a piped
or redirected stdin stream, `--prompt-file <path>`, or a positional task argument; sends it to
`codex exec` non-interactively; and prints only the final result to stdout.

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
`worker-complete.json`, `codex-events.jsonl`, and `stderr.log` under
`%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`, plus an index entry at
`%LOCALAPPDATA%\ccodex\index\<job_id>.json` — even though Phase 1 only exposes the synchronous
result on stdout; `status`/`read`/`debug` commands to inspect that state come in Phase 2.

### Exit codes

Callers can rely on these wrapper exit codes from `ccodex run` (Phase 1):

| Code | Meaning |
| ---- | ------- |
| `0`  | Success — `result.md` was produced and its content was printed to stdout. |
| `2`  | Usage/validation error (bad `--mode`/`--access`, missing/ambiguous prompt source, repo resolution failure, etc.). |
| `10` | The `codex exec` process itself exited non-zero. |
| `11` | `codex exec` exited zero but `result.md` is missing or empty. |
| `12` | Wrapper-internal error (unexpected I/O/serialization failure). |

Codes `3, 4, 20-24` are reserved for Phase 2 commands (`submit`/`status`/`wait`/`cancel`) and are
never produced by Phase 1.

### Long-running or parallel work (Phase 2+, not yet implemented)

```powershell
ccodex submit --mode test --access workspace
ccodex status <job_id>
ccodex wait <job_id>
ccodex read <job_id>
```

## Installing

```powershell
git clone <this repo> D:\Documents\GitHub\ccodex
D:\Documents\GitHub\ccodex\install.ps1
```

This copies `ccodex.ps1` and `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes a `ccodex.cmd`
shim there, and installs the default worker-prompt template to
`%APPDATA%\ccodex\templates\worker-prompt.md`. Add `%USERPROFILE%\.local\bin` to your user `PATH`
if it isn't already there (the script warns if it's missing) so `ccodex` is callable from any
directory. Pass `-InstallDir`/`-TemplatesDir` to `install.ps1` to override either location.

## Repository layout

```text
ccodex.ps1          # dispatcher: parses args, implements the `run` subcommand
ccodex.cmd          # PATH shim: forwards to `pwsh -File ccodex.ps1`
install.ps1         # installs to %USERPROFILE%\.local\bin\ccodex\
templates/          # default worker-prompt contract template
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
- **Phase 2 — Background jobs:** `submit`, `status`, `wait`, `read`, `tail`, `debug`, `cancel`, `doctor`.
- **Phase 3 — Claude slash command:** `.claude/commands/ccodex.md` wiring.
- **Phase 4 — Worktree isolation:** edit-capable workers in an isolated git worktree, with explicit `diff`/`apply`.

See [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md) for the
full rationale, non-goals, and phase-by-phase verification criteria.
