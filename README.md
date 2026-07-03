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

**Phase 1 (synchronous CLI) is in progress.** See [`docs/2026-07-03-ccodex-adapter-phase1-plan.md`](docs/2026-07-03-ccodex-adapter-phase1-plan.md)
for the task-by-task build log and [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md)
for the full design across all planned phases.

Implemented so far:

- `lib/Paths.ps1` — global state-root path helpers and `repo_key` hashing
- `lib/Repo.ps1` — `--repo` override / `git rev-parse --show-toplevel` resolution

Not yet implemented (tracked in the Phase 1 plan): prompt-source detection (pipeline / redirected
stdin / `--prompt-file`), worker-prompt templating, mode/access validation, job file writers, the
`codex exec` process invocation, result validation, the `ccodex run` command itself, and the
install script. `ccodex` is **not yet callable as a command** — there is no `ccodex.ps1` or
installer yet.

This README will be updated as each phase of the design lands; until Phase 1 finishes, treat
everything below "Status" as the target shape, not current behavior.

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

## Planned usage (target shape, see the design doc for full detail)

```powershell
# Synchronous, read-only review or brainstorming
"Review this diff for correctness issues." | ccodex run --mode review
"What are the trade-offs of X vs Y?" | ccodex run --mode brainstorm

# Test tasks need explicit write access for artifacts (screenshots, traces, logs)
"Run the login flow in Playwright and report the result." | ccodex run --mode test --access workspace

# Long-running or parallel work (Phase 2+)
ccodex submit --mode test --access workspace
ccodex status <job_id>
ccodex wait <job_id>
ccodex read <job_id>
```

## Repository layout

```text
ccodex.ps1          # dispatcher (Phase 1, not yet implemented)
ccodex.cmd          # PATH shim (Phase 1, not yet implemented)
install.ps1         # installs to %USERPROFILE%\.local\bin\ccodex\ (Phase 1, not yet implemented)
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

- **Phase 1 — Synchronous CLI:** `ccodex run`, prompt transport, job files, install script. *(in progress)*
- **Phase 2 — Background jobs:** `submit`, `status`, `wait`, `read`, `tail`, `debug`, `cancel`, `doctor`.
- **Phase 3 — Claude slash command:** `.claude/commands/ccodex.md` wiring.
- **Phase 4 — Worktree isolation:** edit-capable workers in an isolated git worktree, with explicit `diff`/`apply`.

See [`docs/2026-07-03-ccodex-adapter-design.md`](docs/2026-07-03-ccodex-adapter-design.md) for the
full rationale, non-goals, and phase-by-phase verification criteria.
