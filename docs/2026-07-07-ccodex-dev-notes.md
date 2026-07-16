# ccodex Development Notes — Conventions, Pitfalls, and Verification Recipes

> Audience: any agent or engineer continuing development of this repo. This file records the
> hard-won, non-obvious knowledge from Phases 1–3 that is NOT derivable from the design spec or
> the code alone. Read it before touching `ccodex.ps1` or `lib/`. The companion entry point is
> `docs/2026-07-07-ccodex-handoff.md`.

## Running the tests

Each `lib/*.ps1` module has a matching plain-PowerShell assertion script in `tests/` (no Pester —
deliberate; see the Phase 1 plan's Global Constraints). Success is exit code `0`.

```powershell
# One file
pwsh -NoProfile -File tests/Paths.tests.ps1

# Quick suite — the inner dev loop (skips the slow shell-level/E2E files, and prints which)
pwsh -NoProfile -File tests/run-tests.ps1

# Full suite — must be green before a piece of work is declared done / committed
pwsh -NoProfile -File tests/run-tests.ps1 -Suite full
```

`tests/run-tests.ps1` (added 2026-07-13; guarded by `tests/RunTests.tests.ps1`) prints per-file
PASS/FAIL with seconds and exits with the failed-file count. The quick suite exists because the
shell-level/E2E files each spawn many child `pwsh` processes and dominate wall-clock time
(minutes each on a loaded machine); the skip list is the `$SlowFiles` param default inside the
runner — re-derive it from a `-Suite full` run's per-file timings when the suite's shape
changes. Quick is for iteration only: every task must still leave the FULL suite green before
it is declared done, not just the new file.

As of 2026-07-13: 34 test files, all green.

**Timing bounds in tests must tolerate slow process cold-starts.** On 2026-07-13 a loaded
desktop pushed `pwsh` cold-start to 3–7s, flaking every assertion that raced a small absolute
bound against child-process spawns (`Doctor.tests.ps1` scenario (i), 1s probe;
`RealInvocation.tests.ps1` empty-stdin, 2s; `AsyncE2E.tests.ps1` wait-timeout vs a 4s fixture
sleep). All were loosened: assert the *path taken* via messages/exit codes where possible, make
fixture sleeps outlive worst-case spawn chains, and keep wall-clock bounds only as generous
anti-hang guards — never as tight performance assertions.

The F2 submit flake had the same root cause at a larger scale: the detached-worker startup
sentinel used a fixed 20-second window, while a saturated 20-core host measured healthy worker
cold-starts at 24.8–114.4 seconds. The sentinel now defaults to 120 seconds and accepts the
`CCODEX_STARTUP_TIMEOUT_SEC` test/CI override; because the launched PID is polled too, a worker
that actually exits before stamping startup still fails quickly after one 500 ms status re-read.

### Test harness

- `tests/TestHelpers.ps1` — dot-source it; provides `Assert-Equal`, `Assert-True`,
  `Assert-Throws`, and `Complete-CcodexTests` (call last; sets the exit code).
- `tests/fixtures/fake-codex.ps1` — a stand-in codex binary driven entirely by env vars
  (`CCODEX_FAKE_RESULT`, `CCODEX_FAKE_EXIT_CODE`, `CCODEX_FAKE_STDERR`, `CCODEX_FAKE_DELAY_MS`,
  `CCODEX_FAKE_PIDFILE` for kill-tree polling, `CCODEX_FAKE_SKIP_RESULT`). It reads stdin to EOF,
  honors `--output-last-message`, emits one JSONL line on stdout and one stderr line. Extend it
  ONLY additively — many tests share it.
- `tests/fixtures/stub-worker.ps1` — minimal worker stand-in for Detach/backend tests.
- Tests always use a temp state root (`--state-root` / `$env:TEMP`-based), never the real
  `%LOCALAPPDATA%\ccodex`. Destructive behaviors (cleanup, cancel, scrub) must keep this rule.
- Live (real-codex) calls appear ONLY in the final task of a phase as an explicit "live smoke",
  with evidence captured in the task report — never inside the regular suite.

## Regression-guarded pitfalls — do not undo these

Each of these was a real bug found during Phases 1–2. Each has a regression test; if a change of
yours makes one of these tests fail, the test is right and the change is wrong.

1. **`ccodex.ps1` must remain a plain script — no `[CmdletBinding()]`, no `param()` attributes.**
   With `[CmdletBinding()]`, `pwsh -File ccodex.ps1 ...` consumed redirected/piped stdin into a
   failed pipeline bind and exited 2, silently breaking `"task" | ccodex run`. Argument parsing is
   `$args`-based via `Get-CcodexArgValue` / `Get-CcodexArgValues` (bottom of `ccodex.ps1`).
   Guarded by `tests/RealInvocation.tests.ps1`.

2. **Codex path resolution must use `Get-Command -CommandType Application`**
   (`Resolve-CcodexCodexPath` in `lib/CodexInvoke.ps1`). npm installs both `codex.cmd` and
   `codex.ps1`; PowerShell ranks ExternalScript above Application, so a bare `Get-Command codex`
   returns the `.ps1`, which `Process.Start` cannot execute. Guarded by an npm-shaped-PATH test in
   `tests/CodexInvoke.tests.ps1`.

3. **cmd.exe shim quoting is two-layered and deliberate** (`lib/CodexInvoke.ps1`,
   `lib/Detach.ps1`). When the resolved codex is a `.cmd`/`.bat`, the invocation is wrapped as
   `cmd /d /s /c "<inner line>"`. The inner line is pre-quoted with Win32 rules PLUS
   `ConvertTo-CcodexCmdInnerArgument`, which force-quotes cmd metacharacters (`& | < > ( ) ^ %`).
   For the cmd.exe branch the code assigns the joined string to `$psi.Arguments` directly —
   using `ArgumentList` there would make .NET re-escape the already-quoted line. Detach's
   Start-Process test path reuses the same quoted-command-line builder; don't fork a second
   quoting implementation.

4. **All wrapper-authored files are UTF-8 WITHOUT BOM.** Use the existing helpers in
   `lib/JobStore.ps1` — `Write-CcodexTextFile`, `Write-CcodexJsonFile`, and
   `Write-CcodexJsonFileAtomic` — never `Set-Content`/`Out-File` for job artifacts.

5. **`status.json` discipline:** single writer per lifecycle stage; every update goes through the
   atomic temp+rename writer; fields are append-only (never remove or rename an existing field —
   external tooling reads them); reconciliation must preserve `failure_reason` and
   `codex_thread_id` (a past bug dropped them). `codex_exit_code` / `wrapper_exit_code` are
   distinct fields by design — never introduce a generic `exit_code`.

6. **Raw Codex JSONL never reaches the parent's stdout.** It goes to `codex-events.jsonl` in the
   job dir; the parent prints only the final `result.md` content (and job ids for `submit`).
   `tests/AsyncE2E.tests.ps1` asserts stdout exactness — keep it byte-exact.

7. **Backend identity is `"<pid>;<UTC start time 'o'>"`** to defeat PID reuse; any code that
   kills or health-checks a backend must verify BOTH parts before acting
   (`lib/Detach.ps1`, reconciliation in `lib/JobStatus.ps1`).

8. **`install.ps1` mirrors, never merges — and the mirror is guarded** (2026-07-13).
   `Copy-Item -Recurse -Force` over an existing install merges directories, so a `lib/` module
   renamed or deleted in a newer version survived upgrades as a stale file. The installer now
   stages the new script tree at `<dest>.staging` and swaps it in whole (old copy removed only
   after the complete new one exists — a failed copy never leaves a half-installed CLI), and
   already emptied the namespaced-command dir first (77fb0a8). Because the mirror deletes its
   destination, two refusal guards are load-bearing (found by Codex review: without them,
   `-InstallDir $env:LOCALAPPDATA` made the script dir the job-state root and the mirror deleted
   all job state): refuse a script dir colliding with `%LOCALAPPDATA%\ccodex`, and refuse
   replacing an existing non-empty dir without a `ccodex.ps1` marker. Upgrade = `git pull` +
   re-run `install.ps1`; see README "Upgrading". Guarded by the planted-stale-file, foreign-dir,
   and state-root-collision assertions in `tests/Install.tests.ps1`. Accepted minor: a `ccodex`
   invocation launched in the milliseconds between the old copy's removal and the staging
   rename can fail once — rerunning it succeeds; versioned release dirs were judged
   disproportionate for a rare, manual operation.

## Host and environment facts (this development machine)

- **Codex sandbox spawn capability changed with the CLI upgrade.** Under codex-cli 0.142.5 the
  sandbox could not spawn child processes here (observed signature:
  `CreateProcessWithLogonW failed: 1385`), which made `--embed-diff` mandatory for
  `ccodex review`. Re-verified 2026-07-13 on codex-cli 0.144.1: Codex ran `git log` inside a
  read-only-sandbox job on this machine, so the self-diff review form works again.
  `--embed-diff` remains the robust default recommendation (unusual git states, other hosts),
  but it is no longer a hard host requirement here. If the signature reappears after a future
  upgrade, restore the hard requirement and re-check with a live spawn probe.
- codex-cli version verified 0.144.1 (2026-07-13; previously 0.142.5): `codex exec resume
  <SESSION_ID>` still exists and live-round-trips (Phase 5 foundation), the
  `{"type":"thread.started","thread_id":"..."}` event is unchanged, a built-in `codex doctor`
  still exists (Phase 2b's `doctor` delegates to it), and the effort enum is now
  `none|minimal|low|medium|high|xhigh|max|ultra` (wrapper allowlist mirrors it — re-derive on
  every upgrade via the `codex-upgrade-check` skill, `.claude/skills/codex-upgrade-check/`).
- **Quota exhaustion is a real, observed event** (2026-07-07): wrapper exit `10` with
  `status.json.failure_reason = "quota_or_rate_limit"` and a do-not-retry hint. Honor the hint —
  report and continue without the review; never retry-loop. This classification path is
  live-proven, treat it as load-bearing.
- Windows 11, PowerShell 7+. Production detach backend uses CIM `Win32_Process.Create`
  (breakaway by construction); tests use Start-Process (env inheritance). Both paths must stay.

## Process conventions

- **Workflow:** subagent-driven development (superpowers:subagent-driven-development) with the
  plan docs under `docs/`. One commit per task, using the EXACT commit message the plan
  specifies. TDD per task: write failing tests → verify red → implement → verify green → full
  suite → commit.
- **Commits:** no co-author trailers of any kind. Never commit `.superpowers/` (git-ignored
  scratch: SDD ledger, task briefs/reports).
- **Progress ledger:** `.superpowers/sdd/progress.md` — append one line per completed task. It is
  git-ignored and machine-local; the committed source of truth for cross-machine handoff is
  `docs/2026-07-07-ccodex-handoff.md` plus git history.
- **README rule (from CLAUDE.md):** a phase is not done until README.md reflects the new
  reality — status, roadmap, usage examples, exit codes.
- **Install verification:** after user-facing changes, re-run `install.ps1` and verify the
  installed copy under `%USERPROFILE%\.local\bin\ccodex\` byte-matches the repo
  (`tests/Install.tests.ps1` covers the mechanics; the byte-match spot check is a manual step in
  each phase's final task).
- **Delegation policy applies to this repo's own development** (dogfooding): after a phase's
  changes, a scoped `ccodex review --range <base>..HEAD --path <paths> --embed-diff` second
  opinion has repeatedly found real issues internal reviewers missed. Triage every finding —
  adopt with action or reject with a stated reason.

## Post-review hardening (2026-07-08)

The deferred Phase 4/5 verification (whole-branch Codex reviews of `a8f93e8..285bfd3` and
`285bfd3..5e44352`) produced five adopted findings, fixed in `bd1c9c8..6ccfcd3`:

- `ccodex apply` is serialized under a **per-main-repo lock** in the state root (concurrent
  applies could previously erase each other via the restore path); lock timeout → exit 21.
- New append-only status field **`worktree_finalize_error`** — set only when worktree snapshot
  finalization throws. `diff`/`apply` refuse such jobs with exit 12 (uncommitted worker output
  must not silently become a "no changes" no-op). `worktree_committed=$false` alone does NOT
  gate — it also covers legitimate zero-change runs.
- Resumed children fall back to the **parent's thread id** when the resumed run emits no
  `thread.started` event, keeping chain-off-the-newest-child resumable. Non-resume jobs
  unchanged.
- `ccodex resume` **rejects** `--repo`/`--mode`/`--access` and extra positionals (exit 2)
  instead of silently ignoring them (resume inherits parent context).
- cleanup's `worktrees_swept` counts only confirmed removals.

`tests/ImplementE2E.tests.ps1` (the deferred composed chain submit → wait → diff → apply →
cleanup + conflict path) landed at `a4b1cd2`.

The Phase 5 live smoke then caught a bug no fixture-based test could: clap rejects exec-level
options (`--sandbox`/`-C`/`--color`) placed after the `resume` token, so every real resume
failed with codex exit 2. `Build-CcodexResumeArgs` now splices `resume <thread-id>` after the
exec options, before the trailing `-`. Lesson recorded: fake-codex accepts ANY argument order —
only a live call validates flag placement against the real CLI.

## Feature-wave notes (2026-07-08, post-completion)

- **Hidden Codex windows**: the CIM worker launch passes a ClientOnly `Win32_ProcessStartup`
  with `ShowWindow=[uint16]0` (SW_HIDE); `Invoke-CcodexCodexProcess` and the doctor probe set
  `ProcessStartInfo.CreateNoWindow=$true`. Live-verified (real CIM submit, no visible window).
  Don't remove either half: the CIM startup instance hides the WORKER console, CreateNoWindow
  hides the CODEX child console.
- **`--model`/`--effort`**: hyphenated flags never bind to the script's `param()` names, so
  both land in `$args` and are read via the arg helpers — but PUBLIC value flags use
  `Get-CcodexRequiredArgValue`, which throws (→ exit 2) when the flag is present with no value
  or a `--`-shaped value. Plain `Get-CcodexArgValue` would silently ignore a trailing `--model`
  and consume `--effort` as the model's value (`-m --effort` forwarded to Codex) — a Codex
  review finding, regression-guarded in `tests/RunCommand.tests.ps1`. The effort value is
  forwarded as ONE bare `-c model_reasoning_effort=<v>` argv element on purpose (bare TOML
  falls back to a literal string; avoids cmd-shim quote layering). For `submit`, model/effort
  reach the detached worker ONLY via the launch command line (status.json carries neither —
  per-invocation knobs, not lifecycle state).
- **Per-function Claude commands**: `templates/claude-commands/<name>.md` installs to
  `~/.claude/commands/ccodex/<name>.md` (= `/ccodex:<name>`). `install.ps1` deletes the
  destination's `*.md` before copying so a renamed/removed template never leaves a ghost
  command (also a Codex review finding).

## Worktree continuation pitfalls (F3, 2026-07-16)

- A resumed implement job always gets a **new** worktree seeded from the parent's recorded
  `snapshot_commit`; never use the parent's live `HEAD` or mutate/reuse its worktree. The parent
  directory is positive WIP evidence, while `snapshot_commit` is positive finalization evidence.
- Keep `base_commit` as the child worktree's own seed. `series_base_commit` is a separate,
  append-only cumulative range root inherited as `parent.series_base_commit ?? parent.base_commit`.
  Conflating them makes grandchildren omit ancestor work from `diff`/`apply`.
- `diff`/`apply` resolve both ends from status: base = `series_base_commit ?? base_commit`, endpoint
  = `snapshot_commit ?? HEAD`. The endpoint fallback exists only for pre-F3 jobs; using live HEAD
  for a newly finalized job reopens post-terminal mutation races.
- Sync `resume` and async `submit --resume` must both go through
  `Initialize-CcodexResumeJob`. Any failure after `git worktree add` must tear down the child
  worktree and either leave terminal `status.json` + `worker-complete.json` evidence or roll back
  the reservation/index completely.
- Async resumed workers must build `Build-CcodexResumeArgs -RepoRoot` from `worktree_repo` when
  present, not status `repo` (the main repo). The relocation envelope in child `prompt.md` is also
  load-bearing: the resumed thread remembers obsolete parent paths.
- A descendant patch is cumulative. Apply only the newest accepted descendant, never an ancestor
  and then the descendant. Merge commits remain a documented limitation because `format-patch`
  omits them; the ancestor check rejects clearly broken histories but does not linearize merges.

## Known accepted minors (deliberately not fixed)

From the Phase 1 final review; re-fixing them is not required, but don't accidentally make them
worse:

- Empty positional task text is treated as "no prompt source" (falsiness in
  `lib/PromptSource.ps1`) rather than a distinct usage error.
- `lib/StdinTimeout.ps1` abandons its `ReadAsync` task on timeout (harmless; process exits).
- A missing worker-prompt template exits `12` before any `status.json` exists (no job dir yet to
  write into).
- Completion-evidence files (`worker-complete.json`, `exit_code.txt`, `result.md`) are not
  backend-scoped: on the (currently unreachable) foreign-backend-takeover path the terminal
  status write is guarded, but evidence files are not. Deferred from the 2026-07-07 codex final
  gate with rationale: no code path launches a second worker for one job id today (`resume`
  creates a new job dir). Revisit if Phase 4/5 ever share job directories between workers.
