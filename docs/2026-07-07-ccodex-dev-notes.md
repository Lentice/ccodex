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

# Full suite (run from repo root; prints a failure count at the end)
$failed = 0
Get-ChildItem tests -Filter *.tests.ps1 | ForEach-Object {
    pwsh -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { $failed++; Write-Host "FAILED: $($_.Name)" }
}
Write-Host "$failed test file(s) failed"
```

As of commit `f8e2fe2`: 23 test files, 601 assertions, all green. Every task must leave the FULL
suite green, not just the new file.

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

## Host and environment facts (this development machine)

- **Codex sandbox cannot spawn child processes here.** Observed signature:
  `CreateProcessWithLogonW failed: 1385`. Consequence: `ccodex review` must be used with
  `--embed-diff` (the wrapper runs `git diff` and embeds it); the self-diff form, where Codex
  runs git itself, fails on this host. This is environmental, not a ccodex bug.
- codex-cli version verified 0.142.5: `codex exec resume <SESSION_ID>` exists (Phase 5
  foundation), and a built-in `codex doctor` exists (Phase 2b's `doctor` delegates to it).
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

## Known accepted minors (deliberately not fixed)

From the Phase 1 final review; re-fixing them is not required, but don't accidentally make them
worse:

- Empty positional task text is treated as "no prompt source" (falsiness in
  `lib/PromptSource.ps1`) rather than a distinct usage error.
- `lib/StdinTimeout.ps1` abandons its `ReadAsync` task on timeout (harmless; process exits).
- A missing worker-prompt template exits `12` before any `status.json` exists (no job dir yet to
  write into).
