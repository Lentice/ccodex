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
- The **non-resume run path** (`Initialize-CcodexJob`, backlog #23) must mirror this: the post-
  `New-CcodexJobWorktree` steps (artifact dir, template render, prompt/status writes) run inside a
  `try/catch` that best-effort `Remove-CcodexJobWorktree`s (swallowed with `Out-Null` so it never
  masks the original error) and records terminal `failed` evidence via `Complete-CcodexInternalFailure`
  (exit 12). Without the guard, a throw there (disk full, IO error, template render failure) orphans
  BOTH the worktree dir and its `.git/worktrees/<id>` admin entry — the job dir exists, so neither
  the age nor dangling cleanup sweep reclaims it.
- Async resumed workers must build `Build-CcodexResumeArgs -RepoRoot` from `worktree_repo` when
  present, not status `repo` (the main repo). The relocation envelope in child `prompt.md` is also
  load-bearing: the resumed thread remembers obsolete parent paths.
- A descendant patch is cumulative. Apply only the newest accepted descendant, never an ancestor
  and then the descendant. Merge commits remain a documented limitation because `format-patch`
  omits them; the ancestor check rejects clearly broken histories but does not linearize merges.

## Command registry / dispatch (backlog #14, 2026-07-20)

The `switch ($Command)` dispatcher was replaced by a data-driven registry. Know this before adding
or changing a command:

- **Adding a command or flag = edit one handler + one registry line.** Each command is an
  `Invoke-Ccodex*Dispatch` function in `ccodex.ps1` (grouped above the `-ImportOnly` guard so tests
  can dot-source and resolve them). `lib/CommandRegistry.ps1`'s `$script:CcodexCommandHandlers` maps
  the command name to that function. Do NOT reintroduce a `switch` — the registry is the single
  dispatch inventory and the seed for backlog #6–#13.
- **Handler contract:** `param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ref]$ExitCode)`.
  Read pre-bound params from `$Context` (`.Command/.PositionalTask/.Mode/.Access/.Repo/.PromptFile`)
  and leftover flags from `$Context.Args` via the existing `Get-CcodexArgValue*`/`ConvertTo-Ccodex*`
  helpers. Write stdout/stderr with `Write-Output`/`Write-Host` exactly as before; set
  `$ExitCode.Value` and `return`.
- **Why `[ref]`, not a return value (load-bearing):** the dispatcher invokes the handler INLINE and
  UNCAPTURED (`& (Get-Command $name) -Context $ctx -ExitCode ([ref]$e)`) so `Write-Output` flows
  straight to the real stdout, byte-identically to the old arm. A handler that returned its exit
  code would merge it into the success stream; any caller assigning the call would then capture the
  handler's stdout together with the int — swallowing the output and corrupting the exit code
  (verified). Never wrap handler invocation in a value-returning function.
- **`worker` is in the registry but help-hidden** (`Internal=$true`/`VisibleInHelp=$false`), so it
  dispatches while staying out of help and the unknown-command "Supported commands" list. That list
  is still `Get-CcodexCommandNames` (visible only); the registry inventory is a superset.
- **The router does not parse args or reject unknown flags.** Per-command permissiveness (unknown
  flags ignored, extra positionals absorbed, flag-before-id recovery in diff/apply) lives in each
  handler and is pinned by `tests/Characterization.tests.ps1`. `tests/Registry.tests.ps1` guards the
  inventory/metadata/handler-signature contract.

## Read-path reconciliation is zero-wait (backlog #16, 2026-07-20)

The lifecycle polling paths never block on the per-job lock. Know this before touching the
reconciliation call sites:

- **Change the callers, not the default.** `Update-CcodexOrphanStatus`'s `-LockTimeoutSec` default
  stays `10` (other callers — `cancel`'s orphan branch, `cleanup`, the `diff`/`apply` resolver,
  `debug` — legitimately inherit it). The four lifecycle polling paths pass `-LockTimeoutSec 0`
  explicitly: `Invoke-CcodexStatusCommand`, `Invoke-CcodexReadCommand`, both branches of
  `Invoke-CcodexWaitCommand`, and `Test-CcodexJobTerminalState`'s call from
  `Invoke-CcodexWaitAllCommand`. Do NOT lower the function default to 0 — that would silently make
  every writer-adjacent reconcile non-blocking too.
- **`wait`'s deadline iteration reconciles too.** Once reconciliation is zero-wait, the old
  no-reconcile special-case at the deadline (which existed only to avoid a lock-wait overrun) is
  both unnecessary and wrong, so `Invoke-CcodexWaitCommand` now runs the same unconditional
  zero-wait reconcile on every iteration. This keeps `health=possibly-stale` on the timeout line for
  a contended orphan and lets an orphan that just became evidenced reconcile to its terminal status
  on the final poll instead of spuriously returning exit 20 (a Codex review finding; guarded by the
  possibly-stale-at-timeout assertions in `tests/StatusWaitRead.tests.ps1` and
  `tests/WaitAll.tests.ps1`).
- **`-LockTimeoutSec 0` means one acquisition attempt, no wait** (`Lock-CcodexJob` sets its
  deadline to `now`, so a live-contended lock throws immediately; a *stale* lock is still broken and
  retried — that is not a wait on a live owner). The reconcile catches the throw and degrades to
  `possibly-stale`, exactly as the old 10 s timeout path did — only faster.
- **The guarantee is scoped, not universal.** It is "the lifecycle polling paths of
  `status`/`read`/`wait`/`wait --all` never wait on the job lock" — NOT "read-only commands never
  lock". `debug` and the `diff`/`apply` precondition resolver still reconcile with the default wait;
  they were audited and left for a follow-up (changing them is safe but out of #16's scope).
- **Exit 21 was never reachable from these read paths** — the contended reconcile already degraded
  to possibly-stale. #16 removed up-to-10 s of latency, not a failure class; docs must not claim
  otherwise.
- Guards: `tests/JobStatus.tests.ps1` pins the `-LockTimeoutSec 0` function contract (prompt return,
  possibly-stale, no rewrite); `tests/StatusWaitRead.tests.ps1` pins `status`/`read` answering
  promptly under a held lock and converging on a later uncontended call;
  `tests/WaitAll.tests.ps1` pins the same for `wait --all`. Timing bounds are generous (3 s / 6 s)
  and measured around the in-process call, never around a `pwsh` cold start (see the timing note at
  the top of this file). The contention fixture is always `running` + dead backend id + a parsable
  `exit_code.txt`, so reconciliation actually reaches the lock attempt.

## apply flag-parse + rollback honesty (backlog #11/#12 Codex review, 2026-07-20)

A scoped Codex review of the #11/#12 diff surfaced two `apply` gaps; both are fixed and guarded in
`tests/DiffApply.tests.ps1`. Know them before touching the apply dispatch or its failure paths:

- **`apply --message` uses `Get-CcodexRequiredArgValue`, not `Get-CcodexArgValue`.** `--message` is
  a public value-flag, so the same misparse class the `run` handler already guards applies: plain
  `Get-CcodexArgValue` silently returned `$null` for a trailing `--message` (landing the worker's
  default message while the caller believed it was rewritten) and consumed the *next* flag as the
  message for `--message --reset-author`. `Invoke-CcodexApplyDispatch` now calls
  `Get-CcodexRequiredArgValue` in a try/catch → exit `2`. Do NOT revert it to `Get-CcodexArgValue`;
  the trailing/flag-swallow cases are pinned. (Legitimate commit subjects starting with `--` are the
  documented tradeoff shared by every flag routed through the Required helper.)
- **Both apply failure paths verify the rollback via `Get-CcodexApplyRestoreState`.** The failed-`am`
  path and the failed-`--message`/`--reset-author`-amend path both roll the main repo back to
  `$preHead`, then call the shared `Get-CcodexApplyRestoreState` helper (HEAD-equals-preHead **and**
  no working-tree lines beyond the pre-existing untracked set) instead of assuming success. The amend
  path previously claimed "main repo restored to its pre-apply state" unconditionally; it now warns
  and names the actual `HEAD` when the reset did not fully restore. The helper is the single source
  of that check — do not re-inline it. The amend-failure branch is near-unreachable in practice
  (`--reset-author` resolves the author from the committer, so an amend after a successful `am` rarely
  fails), which is why its coverage is the helper's own unit test plus the existing `am`-failure
  integration tests (conflict / apply-twice / hook-conflict) that now exercise the shared helper.

## tail events truncation + oversized-final-line retrieval (backlog #13, #11, 2026-07-21)

`tail`'s `codex-events.jsonl` block is now retrieved and rendered by two dedicated functions in
`ccodex.ps1`, guarded by the `(f)` block in `tests/TailDebug.tests.ps1`. Know these before touching
either:

- **`Get-CcodexTailEventsRecords` replaces `Get-CcodexTailLines` for events only** — `stderr.log`
  (and `debug`'s 5-line stderr peek) still use `Get-CcodexTailLines` and must stay byte-for-byte
  unchanged. The old fixed 64 KB end-window **dropped** an oversized final record: when the whole
  window fell inside one line, the split produced a single partial element that the `seekedMidFile`
  guard then removed → empty. The new function instead scans backward in 16 KB chunks collecting the
  `\n` offsets that begin each retained line, so the last N *complete logical lines* are always
  returned even when one is larger than any window, and it reads only those backward windows plus
  each retained line's own bytes — never the whole file. It returns records `{ ByteLength; Bytes }`
  where `ByteLength` is the line's true full UTF-8 content length and `Bytes` is only the first
  `ReadCap` bytes (the display prefix). Do not "simplify" it back to a single end-window read. A
  trailing CR (CRLF terminator) is excluded from `ByteLength` **up front** (a 1-byte peek at `e-1`
  before the read cap is applied), so an oversized *intermediate* CRLF line's dropped count is not
  inflated by one — a Codex-review finding; do not move the CR strip back to a post-read `readN==len`
  check, which misses read-capped lines.
- **`ReadCap` is width-driven and ceiling-clamped.** `Invoke-CcodexTailCommand` passes
  `min(MaxLine + 4, $script:CcodexTailReadCap)` when truncating (all the renderer can need is the
  width plus a few bytes of char-boundary slack) and the ceiling itself for `--max-line 0`. The
  single `$script:CcodexTailReadCap` (16 MB) ceiling bounds the per-line byte-array allocation in
  **every** mode — an enormous `--max-line` cannot force a giant allocation (Codex-review finding),
  and anything past the ceiling surfaces via the marker rather than being read. This is why a 100 KB
  final record costs ~204 bytes of retained memory in the default mode while still reporting the true
  `…(+99800 bytes)` dropped count (dropped is computed from `ByteLength`, not from what was read).
- **`Format-CcodexTailEventsLine` truncates by UTF-8 *bytes*, backing off continuation bytes.** When
  the cut lands inside the held buffer, the point retreats while `Bytes[keep]` is a `10xxxxxx`
  continuation byte; when the whole buffer was itself cut mid-content by the read ceiling, a dangling
  trailing partial sequence is dropped by walking back to the last lead byte and checking its
  expected length. Either way a multi-byte sequence — hence any surrogate pair (one astral code point
  is a single 4-byte UTF-8 sequence) — is never split, and the decoded prefix never contains a
  `U+FFFD`. The dropped count uses UTF-8 byte length, never `String.Length`; the `…(+N bytes)` marker
  is appended *outside* the width budget. **Verbatim (`--max-line 0`) is honest, not silent:** if a
  line exceeds the read ceiling it is still shown as a prefix + marker (Codex-review finding) rather
  than quietly losing the tail. The surrogate-pair guards are pinned by the emoji (`U+1F600`) tests
  (both the display-width cut and the read-ceiling cut) — do not switch the truncation to a
  `.Substring`/char-index basis.
- **`--max-line` is presence-aware** via `Get-CcodexRequiredArgValue` + `ConvertTo-CcodexMaxLineWidth`
  (0 is a legal value distinct from an absent flag; valueless/negative/non-integer → exit `2`). A
  very large positive width is accepted, not rejected — the ceiling clamp above makes it safe, and
  the line renders full-or-prefix+marker as appropriate. Unknown-flag permissiveness is unchanged —
  the `tail` Characterization test still asserts a bogus flag does not alter output or exit code, so
  do NOT add unknown-flag rejection here.

## Launch-failure orphans + PID-reuse-safe liveness (backlog #24, 2026-07-21)

Two lifecycle-hardening fixes designed together; guarded by `tests/Detach.tests.ps1`,
`tests/SubmitCommand.tests.ps1`, `tests/JobStatus.tests.ps1`, and the reconciliation assertions in
`tests/StatusWaitRead.tests.ps1` / `tests/CancelCommand.tests.ps1`. Know these before touching the
startup sentinel or `Update-CcodexOrphanStatus`:

- **Sentinel liveness is identity-based, never a bare PID.** `Wait-CcodexWorkerLaunch` takes a
  `-BackendId` (`<pid>;<UTC start time>`, captured right after launch by `Get-CcodexProcessIdentity`)
  and checks it via `Test-CcodexWorkerAlive`, which matches the pid **and** the start time. A bare
  `Get-Process -Id` was defeated by PID reuse: after the worker died its pid could be reassigned to an
  unrelated live process, so the ~500 ms dead-worker fast-fail never fired and the caller waited the
  full 120 s window. Do NOT revert `Wait-CcodexWorkerLaunch` to a `-ProcessId` + `Get-Process` check.
- **A launch/sentinel failure terminalizes a provably-gone `created` job.** In `Invoke-CcodexSubmit`'s
  catch, if the worker is gone (identity) AND the job is still `created`, it writes a terminal `failed`
  `status.json` + `worker-complete.json` via `Complete-CcodexInternalFailure` (both resume and
  non-resume branches), then still returns exit `23`. This closes the `created`-orphan that has no
  `backend_id` for reconciliation to settle and would hang a later `wait`/`wait --all` forever. A
  still-*alive* slow worker (or one already off `created`) is left untouched — terminalizing would race
  its own `created`→`running` write. Mirror this guard order; do not terminalize unconditionally.
- **Reconciliation distinguishes absent vs present-but-corrupt evidence (`#24c`).** In
  `Update-CcodexOrphanStatus`, once the worker is proven dead: a PARSABLE `exit_code.txt` →
  `Test-CcodexResult` terminal verdict; an **absent** `exit_code.txt` → terminal `failed`
  (`codex_exit_code` null, `wrapper_exit_code` 10) because a dead process can never produce evidence;
  a **present-but** empty/corrupt `exit_code.txt` is mid-finalize → stays `possibly-stale` (NOT raced
  to a fabricated terminal). The alive-check at the top of the function must run first — the
  absent-evidence terminalization is only ever reached for a provably-gone worker. This changed the
  old "no evidence → possibly-stale forever" behavior: `tests/CancelCommand.tests.ps1` and
  `tests/StatusWaitRead.tests.ps1` were updated to expect the reconciled `failed` verdict, while the
  held-lock (contended) and present-but-corrupt cases still assert `possibly-stale`.

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
