# ccodex Adapter Phase 1 (Synchronous CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase 1 `ccodex run` command: a user-level PowerShell CLI that normalizes a task prompt into a job directory, invokes `codex exec` non-interactively, captures its output, and prints only the final result to stdout — following `docs/superpowers/specs/2026-07-03-ccodex-adapter-design.md`.

**Architecture:** A dispatcher script (`ccodex.ps1`) dot-sources small single-responsibility library files under `lib/` (path resolution, repo resolution, job id, prompt-source detection, worker-prompt templating, mode/access validation, job-file writers, process invocation, result validation). Each library file is independently testable via plain PowerShell assertion scripts (no Pester — see Global Constraints). `install.ps1` copies the script tree to a user-level `PATH` directory and the default prompt template to `%APPDATA%\ccodex\templates\`.

**Tech Stack:** PowerShell 7+, `.NET` process/stream APIs (no external PowerShell modules), the `codex` CLI already installed on this machine (`codex-cli 0.142.5`, resolves to `codex.cmd`).

**Repository:** this is a standalone, project-agnostic dev tool — it must not live inside the Quotation/Docker repo. Source of truth is its own independent git repository at `D:\Documents\GitHub\ccodex` (created fresh as part of Task 0 below), separate from the installed copy at `%USERPROFILE%\.local\bin\ccodex\` that `install.ps1` produces. All file paths in this plan (e.g. `lib/Paths.ps1`) are relative to `D:\Documents\GitHub\ccodex`, not to the Quotation/Docker repo. This plan document itself stays in the Quotation/Docker repo's `docs/superpowers/` planning tree since that is where this project's spec/plan workflow lives; only the tool's source code moves out.

## Global Constraints

- Target PowerShell 7+ only for Phase 1 (spec: "target PowerShell 7+ first"). Do not special-case Windows PowerShell 5.1.
- No Pester is available to `pwsh` in this environment (`Get-Module -ListAvailable Pester` returns nothing under `pwsh`; only Windows PowerShell 5.1 has Pester 3.4.0, an old, incompatible syntax). Tests in this plan are plain PowerShell scripts using a small hand-rolled assertion helper (`tests/TestHelpers.ps1`), run directly with `pwsh -NoProfile -File <test>.ps1`, exiting non-zero on any failed assertion. Do not introduce a Pester dependency in Phase 1.
- All wrapper-authored files (`prompt.md`, `command.txt`, `debug.json`, `status.json`, logs, `codex-events.jsonl`) are UTF-8 **without BOM**, written via `[System.IO.File]::WriteAllText` with an explicit `System.Text.UTF8Encoding($false)`.
- Do not set `[Console]::InputEncoding` unconditionally; only touch `[Console]::OutputEncoding` in a guarded best-effort block.
- OS-level redirected stdin bounded timeouts: first byte/EOF within 2000 ms, no-progress timeout 5000 ms while reading (spec "Initial defaults").
- `job_id` format: `YYYYMMDDTHHMMSSZ-<8-char-random>-<mode>`, UTC time, cryptographic random suffix, Windows-path-safe characters only.
- Global state root: `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\` and `%LOCALAPPDATA%\ccodex\index\<job_id>.json`. Default worker-prompt template: `%APPDATA%\ccodex\templates\worker-prompt.md`. Optional project-local override: `<repo>\.ccodex\worker-prompt.md`. Never write job state under a project-local `.ccodex\jobs\`.
- Default access per mode: `review` → `read-only`, `brainstorm` → `read-only`, `test` → no default (caller must pass `--access workspace`), `implement` → not available until Phase 4 (must fail).
- Codex CLI mapping: `codex --ask-for-approval never exec --sandbox <read-only|workspace-write> --json --color never -C <repo> --output-last-message <job_dir>/result.md -`. Raw Codex stdout (JSONL) goes only to `codex-events.jsonl`, never to parent stdout. On success, print only `result.md` content to parent stdout.
- Wrapper exit codes implemented in Phase 1: `0` success, `2` usage/validation error, `10` Codex process exited nonzero, `11` Codex exited zero but `result.md` missing/empty, `12` wrapper internal I/O/serialization failure. Codes `3,4,20,21,22,23,24` belong to Phase 2 commands (`status`/`wait`/`submit`/`cancel`) and must not be produced by Phase 1.
- Phase 1 implements only the `run` subcommand. Any other subcommand name must fail with wrapper exit code `2` and a message that Phase 1 only supports `run`.
- Do not modify `.gitignore` or any repository source file (in whatever repo `--repo`/the caller's cwd points at) as a side effect of running `ccodex run`. This is unrelated to the ccodex tool's own repo, which is committed to normally (see below).
- The Quotation/Docker repo's git policy (`AGENTS.md` "Git Usage": no state-changing git ops without explicit request) governs that repo only. It does not apply inside the new standalone `D:\Documents\GitHub\ccodex` repo — the user has already explicitly asked for that repo to be `git init`-ed and used as the tool's normal source-control home. Inside `D:\Documents\GitHub\ccodex`, each task ends with a normal `git add` + `git commit` step (standard TDD-per-task workflow), not a "do not commit" note.

---

## File Structure

All paths below are relative to the repository root `D:\Documents\GitHub\ccodex` (Task 0 creates this repository; do not create these files inside the Quotation/Docker repo).

```text
D:\Documents\GitHub\ccodex\
|-- ccodex.ps1                  # dispatcher: parses args, captures pipeline input, dot-sources lib/, dispatches `run`
|-- ccodex.cmd                  # PATH shim: forwards to `pwsh -File ccodex.ps1`
|-- install.ps1                 # copies ccodex.ps1+lib/ to %USERPROFILE%\.local\bin\ccodex\, shim, default template
|-- templates/
|   `-- worker-prompt.md        # default worker-prompt contract template (source of truth; installed to %APPDATA%)
|-- lib/
|   |-- Paths.ps1                # state-root path helpers, repo_key hashing
|   |-- Repo.ps1                 # --repo / git rev-parse resolution
|   |-- JobId.ps1                # job id generation + atomic job dir reservation
|   |-- PromptSource.ps1         # explicit-source + PowerShell pipeline prompt detection/precedence
|   |-- StdinTimeout.ps1         # bounded-timeout OS-level redirected stdin reader
|   |-- WorkerPrompt.ps1         # template resolution + contract rendering
|   |-- ModeAccess.ps1           # mode/access validation + codex argument building
|   |-- JobStore.ps1             # text/JSON file writers, status/debug/worker-complete object builders
|   |-- CodexInvoke.ps1          # Win32 argv quoting, cmd-shim launch planning, process invocation
|   `-- ResultValidation.ps1     # result.md validation -> status + wrapper exit code
`-- tests/
    |-- TestHelpers.ps1          # Assert-Equal / Assert-True / Assert-Throws / Complete-CcodexTests
    |-- Paths.tests.ps1
    |-- Repo.tests.ps1
    |-- JobId.tests.ps1
    |-- PromptSource.tests.ps1
    |-- StdinTimeout.tests.ps1
    |-- WorkerPrompt.tests.ps1
    |-- ModeAccess.tests.ps1
    |-- JobStore.tests.ps1
    |-- CodexInvoke.tests.ps1
    |-- ResultValidation.tests.ps1
    |-- RunCommand.tests.ps1
    `-- fixtures/
        |-- fake-codex.ps1       # stand-in for `codex exec`: reads stdin, writes result/events/stderr, controllable exit code
        `-- fake-codex.cmd       # .cmd shim wrapping fake-codex.ps1, mirrors the real `codex.cmd` shape
```

---

### Task 0: Repository bootstrap

**Files:**
- Create: `D:\Documents\GitHub\ccodex\` (new directory, new independent git repository)

**Interfaces:**
- Consumes: nothing.
- Produces: an empty, initialized git repository at `D:\Documents\GitHub\ccodex` that Task 1 onward creates files inside. No PowerShell functions are produced by this task.

This task is one-time repository setup, not TDD work — there is no code to test yet, so it has no test steps. Do not create this directory or any files under it inside `D:\Work\Code\Quotation\Docker` (the Quotation/Docker repo); `D:\Documents\GitHub\ccodex` is a sibling, unrelated repository.

- [ ] **Step 1: Verify prerequisites**

Run:
```powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'
git --version
codex --version
```

Expected: a PowerShell version `7.x`, a `git version ...` line, and a `codex-cli ...` version line. If any command is missing, stop and report to the user instead of proceeding — Phase 1 cannot be implemented or tested without all three.

- [ ] **Step 2: Create the directory and initialize git**

```powershell
New-Item -ItemType Directory -Path 'D:\Documents\GitHub\ccodex' -Force | Out-Null
Set-Location 'D:\Documents\GitHub\ccodex'
git init
```

Expected: `Initialized empty Git repository in D:/Documents/GitHub/ccodex/.git/`.

- [ ] **Step 3: Confirm the working directory for every subsequent task**

Every file path in Task 1 onward (e.g. `lib/Paths.ps1`, `tests/Paths.tests.ps1`) is relative to `D:\Documents\GitHub\ccodex`. Every `pwsh -NoProfile -File ...` test command in this plan must be run with `D:\Documents\GitHub\ccodex` as the current directory (or with that prefix prepended to the path). Do not run any step of this plan from inside `D:\Work\Code\Quotation\Docker`.

---

### Task 1: State-root path helpers and repo-key hashing

**Files:**
- Create: `lib/Paths.ps1`
- Test: `tests/TestHelpers.ps1`
- Test: `tests/Paths.tests.ps1`

**Interfaces:**
- Produces:
  - `Get-CcodexLocalAppDataRoot([string]$Root = $env:LOCALAPPDATA) -> string`
  - `Get-CcodexAppDataRoot([string]$Root = $env:APPDATA) -> string`
  - `Get-CcodexRepoKey([string]$RepoRoot) -> string` (12 lowercase hex chars)
  - `Get-CcodexJobsDir([string]$RepoKey, [string]$Root = $env:LOCALAPPDATA) -> string`
  - `Get-CcodexJobDir([string]$RepoKey, [string]$JobId, [string]$Root = $env:LOCALAPPDATA) -> string`
  - `Get-CcodexIndexPath([string]$JobId, [string]$Root = $env:LOCALAPPDATA) -> string`
  - Test helpers: `Assert-Equal`, `Assert-True`, `Assert-Throws`, `Complete-CcodexTests`

- [ ] **Step 1: Write the test helper file**

```powershell
# tests/TestHelpers.ps1
$script:CcodexTestCount = 0
$script:CcodexTestFailures = 0
$script:CcodexLastError = $null

function Assert-Equal {
    param($Actual, $Expected, [string]$Because = '')
    $script:CcodexTestCount++
    if ($Actual -ceq $Expected) {
        Write-Host "  PASS: expected '$Expected'$(if ($Because) { " ($Because)" })"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: expected '$Expected' but got '$Actual'$(if ($Because) { " ($Because)" })" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:CcodexTestCount++
    if ($Condition) {
        Write-Host "  PASS: $Message"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [string]$Message)
    $script:CcodexTestCount++
    $threw = $false
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true
        $script:CcodexLastError = $_.Exception.Message
    }
    if ($threw) {
        Write-Host "  PASS: $Message (threw: $script:CcodexLastError)"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: $Message (expected to throw, did not)" -ForegroundColor Red
    }
}

function Complete-CcodexTests {
    Write-Host ""
    Write-Host "$script:CcodexTestCount assertions, $script:CcodexTestFailures failed"
    if ($script:CcodexTestFailures -gt 0) { exit 1 } else { exit 0 }
}
```

- [ ] **Step 2: Write the failing test for Paths.ps1**

```powershell
# tests/Paths.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-paths-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Get-CcodexLocalAppDataRoot / Get-CcodexAppDataRoot"
Assert-Equal (Get-CcodexLocalAppDataRoot -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex' 'joins Root with ccodex'
Assert-Equal (Get-CcodexAppDataRoot -Root 'C:\Fake\Roaming') 'C:\Fake\Roaming\ccodex' 'joins Root with ccodex'

Write-Host "Get-CcodexRepoKey"
$repoA = Join-Path $tempRoot 'repoA'
$repoB = Join-Path $tempRoot 'repoB'
New-Item -ItemType Directory -Path $repoA -Force | Out-Null
New-Item -ItemType Directory -Path $repoB -Force | Out-Null
$keyA1 = Get-CcodexRepoKey -RepoRoot $repoA
$keyA2 = Get-CcodexRepoKey -RepoRoot $repoA
$keyB = Get-CcodexRepoKey -RepoRoot $repoB
Assert-Equal $keyA1 $keyA2 'repo key is deterministic for the same path'
Assert-True ($keyA1 -ne $keyB) 'different repo paths produce different keys'
Assert-True ($keyA1 -match '^[0-9a-f]{12}$') 'repo key is 12 lowercase hex chars'

Write-Host "Get-CcodexJobsDir / Get-CcodexJobDir / Get-CcodexIndexPath"
Assert-Equal (Get-CcodexJobsDir -RepoKey 'abc123' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\jobs\abc123' 'jobs dir under repo key'
Assert-Equal (Get-CcodexJobDir -RepoKey 'abc123' -JobId 'job1' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\jobs\abc123\job1' 'job dir under repo key/job id'
Assert-Equal (Get-CcodexIndexPath -JobId 'job1' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\index\job1.json' 'index path uses job id as filename'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/Paths.tests.ps1`
Expected: FAIL — dot-sourcing `lib\Paths.ps1` errors because the file does not exist yet.

- [ ] **Step 4: Implement Paths.ps1**

```powershell
# lib/Paths.ps1
function Get-CcodexLocalAppDataRoot {
    param([string]$Root = $env:LOCALAPPDATA)
    return Join-Path $Root 'ccodex'
}

function Get-CcodexAppDataRoot {
    param([string]$Root = $env:APPDATA)
    return Join-Path $Root 'ccodex'
}

function Get-CcodexRepoKey {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $resolved = (Resolve-Path -LiteralPath $RepoRoot).Path
    $normalized = $resolved.TrimEnd('\', '/').ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 12)
}

function Get-CcodexJobsDir {
    param([Parameter(Mandatory)][string]$RepoKey, [string]$Root = $env:LOCALAPPDATA)
    return Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $Root) 'jobs') $RepoKey
}

function Get-CcodexJobDir {
    param([Parameter(Mandatory)][string]$RepoKey, [Parameter(Mandatory)][string]$JobId, [string]$Root = $env:LOCALAPPDATA)
    return Join-Path (Get-CcodexJobsDir -RepoKey $RepoKey -Root $Root) $JobId
}

function Get-CcodexIndexPath {
    param([Parameter(Mandatory)][string]$JobId, [string]$Root = $env:LOCALAPPDATA)
    return Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $Root) 'index') "$JobId.json"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/Paths.tests.ps1`
Expected: `PASS` for every assertion, final line `9 assertions, 0 failed`, exit code `0`.

- [ ] **Step 6: Commit**

```bash
git add lib/Paths.ps1 tests/TestHelpers.ps1 tests/Paths.tests.ps1
git commit -m "feat: add ccodex state-root path helpers and repo-key hashing"
```

---

### Task 2: Repo resolution

**Files:**
- Create: `lib/Repo.ps1`
- Test: `tests/Repo.tests.ps1`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Resolve-CcodexRepo([string]$RepoOverride) -> string` (absolute repo root path). Throws on failure — callers convert the exception message into wrapper exit code `2`.

- [ ] **Step 1: Write the failing test**

```powershell
# tests/Repo.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-repo-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Resolve-CcodexRepo with --repo override"
$overrideDir = Join-Path $tempRoot 'override'
New-Item -ItemType Directory -Path $overrideDir -Force | Out-Null
$resolved = Resolve-CcodexRepo -RepoOverride $overrideDir
Assert-Equal $resolved (Resolve-Path -LiteralPath $overrideDir).Path 'returns the resolved absolute override path'

Assert-Throws { Resolve-CcodexRepo -RepoOverride (Join-Path $tempRoot 'does-not-exist') } 'throws when --repo does not exist'

Write-Host "Resolve-CcodexRepo via git rev-parse"
$gitRepo = Join-Path $tempRoot 'gitrepo'
New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
Push-Location $gitRepo
try {
    & git init --quiet | Out-Null
    $resolvedGit = Resolve-CcodexRepo -RepoOverride $null
    Assert-Equal $resolvedGit (Resolve-Path -LiteralPath $gitRepo).Path 'falls back to git rev-parse --show-toplevel'
} finally {
    Pop-Location
}

Write-Host "Resolve-CcodexRepo outside any git repo"
$nonGitDir = Join-Path $tempRoot 'nongit'
New-Item -ItemType Directory -Path $nonGitDir -Force | Out-Null
Push-Location $nonGitDir
try {
    Assert-Throws { Resolve-CcodexRepo -RepoOverride $null } 'throws when no git repository is found and no --repo given'
} finally {
    Pop-Location
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/Repo.tests.ps1`
Expected: FAIL — `Resolve-CcodexRepo` is not defined.

- [ ] **Step 3: Implement Repo.ps1**

```powershell
# lib/Repo.ps1
function Resolve-CcodexRepo {
    param([string]$RepoOverride)

    if ($RepoOverride) {
        if (-not (Test-Path -LiteralPath $RepoOverride -PathType Container)) {
            throw "ccodex: --repo '$RepoOverride' does not exist or is not a directory."
        }
        return (Resolve-Path -LiteralPath $RepoOverride).Path
    }

    $gitOutput = & git rev-parse --show-toplevel 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: no git repository found in the current directory. Pass --repo <path> or run from inside a git repository."
    }
    $gitPath = ($gitOutput | Select-Object -First 1).ToString().Trim()
    $nativePath = $gitPath -replace '/', '\'
    return (Resolve-Path -LiteralPath $nativePath).Path
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/Repo.tests.ps1`
Expected: all `PASS`, `4 assertions, 0 failed`, exit code `0`. (Requires `git` on `PATH`, already confirmed available.)

- [ ] **Step 5: Commit**

```bash
git add lib/Repo.ps1 tests/Repo.tests.ps1
git commit -m "feat: add ccodex repo resolution"
```

---

### Task 3: Job ID generation and atomic reservation

**Files:**
- Create: `lib/JobId.ps1`
- Test: `tests/JobId.tests.ps1`

**Interfaces:**
- Consumes: `Get-CcodexJobDir` from Task 1 (`lib/Paths.ps1`).
- Produces:
  - `New-CcodexRandomSuffix([int]$Length = 8) -> string`
  - `New-CcodexJobId([string]$Mode) -> string` (format `YYYYMMDDTHHMMSSZ-<suffix>-<mode>`)
  - `Reserve-CcodexJobDir([string]$RepoKey, [string]$Mode, [string]$Root = $env:LOCALAPPDATA, [int]$MaxAttempts = 5) -> [pscustomobject]@{ JobId; JobDir }`

- [ ] **Step 1: Write the failing test**

```powershell
# tests/JobId.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobId.ps1')

Write-Host "New-CcodexRandomSuffix"
$suffix = New-CcodexRandomSuffix -Length 8
Assert-True ($suffix -match '^[a-z0-9]{8}$') 'suffix is 8 lowercase alphanumeric chars'
Assert-True ((New-CcodexRandomSuffix -Length 8) -ne (New-CcodexRandomSuffix -Length 8)) 'two calls produce different suffixes (probabilistic)'

Write-Host "New-CcodexJobId"
$jobId = New-CcodexJobId -Mode 'review'
Assert-True ($jobId -match '^\d{8}T\d{6}Z-[a-z0-9]{8}-review$') 'job id matches YYYYMMDDTHHMMSSZ-suffix-mode'

Write-Host "Reserve-CcodexJobDir"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobid-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$reservation = Reserve-CcodexJobDir -RepoKey 'deadbeef0000' -Mode 'test' -Root $tempRoot
Assert-True (Test-Path -LiteralPath $reservation.JobDir -PathType Container) 'reservation creates the job directory'
Assert-Equal $reservation.JobDir (Get-CcodexJobDir -RepoKey 'deadbeef0000' -JobId $reservation.JobId -Root $tempRoot) 'JobDir matches Get-CcodexJobDir for the returned JobId'

$reservation2 = Reserve-CcodexJobDir -RepoKey 'deadbeef0000' -Mode 'test' -Root $tempRoot
Assert-True ($reservation2.JobId -ne $reservation.JobId) 'a second reservation gets a distinct job id'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/JobId.tests.ps1`
Expected: FAIL — `New-CcodexRandomSuffix` not defined.

- [ ] **Step 3: Implement JobId.ps1**

```powershell
# lib/JobId.ps1
function New-CcodexRandomSuffix {
    param([int]$Length = 8)
    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $result = New-Object System.Text.StringBuilder
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = [byte[]]::new(1)
        while ($result.Length -lt $Length) {
            $rng.GetBytes($buffer)
            $value = $buffer[0]
            if ($value -lt 252) {
                [void]$result.Append($chars[$value % 36])
            }
        }
    } finally {
        $rng.Dispose()
    }
    return $result.ToString()
}

function New-CcodexJobId {
    param([Parameter(Mandatory)][ValidateSet('review', 'brainstorm', 'test', 'implement')][string]$Mode)
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $suffix = New-CcodexRandomSuffix -Length 8
    return "$timestamp-$suffix-$Mode"
}

function Reserve-CcodexJobDir {
    param(
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$Mode,
        [string]$Root = $env:LOCALAPPDATA,
        [int]$MaxAttempts = 5
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $jobId = New-CcodexJobId -Mode $Mode
        $jobDir = Get-CcodexJobDir -RepoKey $RepoKey -JobId $jobId -Root $Root
        try {
            New-Item -ItemType Directory -Path $jobDir -ErrorAction Stop | Out-Null
            return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "ccodex: failed to reserve a unique job directory after $MaxAttempts attempts."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/JobId.tests.ps1`
Expected: all `PASS`, `6 assertions, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/JobId.ps1 tests/JobId.tests.ps1
git commit -m "feat: add ccodex job id generation and atomic reservation"
```

---

### Task 4: Explicit-source and PowerShell-pipeline prompt detection

**Files:**
- Create: `lib/PromptSource.ps1`
- Test: `tests/PromptSource.tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks yet (stdin-timeout piece is added in Task 5 and merged into the same file).
- Produces: `Get-CcodexPromptContent` (full signature finalized in Task 5). This task implements everything except the OS-level redirected-stdin branch, which Task 5 fills in by calling `Read-CcodexStdinWithTimeout` (currently a stub that throws `"not implemented"`).

- [ ] **Step 1: Write the failing test (explicit sources + pipeline only)**

```powershell
# tests/PromptSource.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\PromptSource.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-promptsource-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CcodexTestParams {
    param([hashtable]$Overrides = @{})
    $base = @{
        ExpectingPipelineInput = $false
        PipelineObjects        = $null
        PromptFile             = $null
        PositionalTask         = $null
        StdinStream            = $null
        StdinIsRedirected      = $false
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return $base
}

Write-Host "positional task text"
$p = New-CcodexTestParams -Overrides @{ PositionalTask = 'do the thing' }
Assert-Equal (Get-CcodexPromptContent @p) 'do the thing' 'returns positional task text verbatim'

Write-Host "--prompt-file"
$promptFile = Join-Path $tempRoot 'prompt.txt'
[System.IO.File]::WriteAllText($promptFile, "line one`r`nline two", (New-Object System.Text.UTF8Encoding($false)))
$p = New-CcodexTestParams -Overrides @{ PromptFile = $promptFile }
Assert-True ((Get-CcodexPromptContent @p) -like '*line one*line two*') 'reads --prompt-file content'

Write-Host "missing --prompt-file"
$p = New-CcodexTestParams -Overrides @{ PromptFile = (Join-Path $tempRoot 'missing.txt') }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when --prompt-file does not exist'

Write-Host "both --prompt-file and positional task"
$p = New-CcodexTestParams -Overrides @{ PromptFile = $promptFile; PositionalTask = 'x' }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when both explicit sources are given'

Write-Host "PowerShell pipeline input"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('multi', 'line') }
Assert-Equal (Get-CcodexPromptContent @p) "multi$([Environment]::NewLine)line" 'joins pipeline objects with Environment.NewLine'

Write-Host "empty PowerShell pipeline input"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @() }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when pipeline input is empty'

Write-Host "whitespace-only pipeline input is preserved, not rejected"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('   ') }
Assert-Equal (Get-CcodexPromptContent @p) '   ' 'whitespace pipeline content counts as non-empty'

Write-Host "pipeline input plus an explicit source conflicts"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('x'); PositionalTask = 'y' }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when pipeline and positional task are both present'

Write-Host "explicit source present must not touch stdin stream"
$blockingStream = [System.IO.Stream]::Null  # any non-null marker; function must never call .Read on it in this branch
$p = New-CcodexTestParams -Overrides @{ PositionalTask = 'z'; StdinIsRedirected = $true; StdinStream = $blockingStream }
Assert-Equal (Get-CcodexPromptContent @p) 'z' 'positional task short-circuits before any stdin probing'

Write-Host "no source at all"
$p = New-CcodexTestParams
Assert-Throws { Get-CcodexPromptContent @p } 'throws when nothing is provided and stdin is not redirected'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/PromptSource.tests.ps1`
Expected: FAIL — `Get-CcodexPromptContent` not defined.

- [ ] **Step 3: Implement PromptSource.ps1 (stdin branch calls a stub filled in by Task 5)**

```powershell
# lib/PromptSource.ps1
function Get-CcodexPromptContent {
    param(
        [bool]$ExpectingPipelineInput,
        [object[]]$PipelineObjects,
        [string]$PromptFile,
        [string]$PositionalTask,
        [System.IO.Stream]$StdinStream,
        [bool]$StdinIsRedirected,
        [int]$StdinFirstByteTimeoutMs = 2000,
        [int]$StdinNoProgressTimeoutMs = 5000
    )

    $explicitSources = @()
    if ($PromptFile) { $explicitSources += 'PromptFile' }
    if ($PositionalTask) { $explicitSources += 'PositionalTask' }

    if ($explicitSources.Count -gt 1) {
        throw "ccodex: multiple prompt sources given ($($explicitSources -join ', ')). Provide exactly one of --prompt-file, positional task text, or stdin."
    }

    if ($explicitSources.Count -eq 1 -and $ExpectingPipelineInput) {
        throw "ccodex: prompt source conflict. PowerShell pipeline input was received in addition to $($explicitSources[0])."
    }

    if ($explicitSources -contains 'PromptFile') {
        if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
            throw "ccodex: --prompt-file '$PromptFile' was not found."
        }
        return Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
    }

    if ($explicitSources -contains 'PositionalTask') {
        return $PositionalTask
    }

    if ($ExpectingPipelineInput) {
        $items = @($PipelineObjects)
        $strings = $items | ForEach-Object { [string]$_ }
        $joined = $strings -join [Environment]::NewLine
        if ($joined.Length -eq 0) {
            throw "ccodex: PowerShell pipeline input was empty. Provide task text via the pipeline, --prompt-file, or positional task text."
        }
        return $joined
    }

    if ($StdinIsRedirected) {
        $content = Read-CcodexStdinWithTimeout -Stream $StdinStream -FirstByteTimeoutMs $StdinFirstByteTimeoutMs -NoProgressTimeoutMs $StdinNoProgressTimeoutMs
        if ($content.Length -eq 0) {
            throw "ccodex: redirected stdin produced no data. Provide task text via --prompt-file or positional task text."
        }
        return $content
    }

    throw "ccodex: no prompt source found. Pipe task text, use --prompt-file <path>, or pass positional task text."
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/PromptSource.tests.ps1`
Expected: all `PASS`, `10 assertions, 0 failed`. (No test in this task exercises the `$StdinIsRedirected -eq $true` branch with actual reading — `Read-CcodexStdinWithTimeout` does not exist yet, which is fine since none of these assertions reach it.)

- [ ] **Step 5: Commit**

```bash
git add lib/PromptSource.ps1 tests/PromptSource.tests.ps1
git commit -m "feat: add ccodex prompt-source detection for explicit sources and pipeline input"
```

---

### Task 5: Bounded-timeout OS-level redirected stdin reader

**Files:**
- Create: `lib/StdinTimeout.ps1`
- Modify: `lib/PromptSource.ps1` — no code change needed (already calls `Read-CcodexStdinWithTimeout` by name); dot-sourcing order in `ccodex.ps1` will load `StdinTimeout.ps1` before `PromptSource.ps1` is invoked (both are dot-sourced before any function call happens, so definition order between the two files does not matter).
- Test: `tests/StdinTimeout.tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `Read-CcodexStdinWithTimeout([System.IO.Stream]$Stream, [int]$FirstByteTimeoutMs, [int]$NoProgressTimeoutMs) -> string`, used by `Get-CcodexPromptContent` (Task 4).

- [ ] **Step 1: Write the failing test using a controllable delayed stream**

```powershell
# tests/StdinTimeout.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\StdinTimeout.ps1')

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

public class CcodexTestStream : Stream
{
    private readonly Queue<Tuple<byte[], int>> _chunks;
    public CcodexTestStream(IEnumerable<Tuple<byte[], int>> chunks)
    {
        _chunks = new Queue<Tuple<byte[], int>>(chunks);
    }
    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        if (_chunks.Count == 0) return 0;
        var chunk = _chunks.Dequeue();
        if (chunk.Item2 > 0) await Task.Delay(chunk.Item2, cancellationToken);
        Array.Copy(chunk.Item1, 0, buffer, offset, chunk.Item1.Length);
        return chunk.Item1.Length;
    }
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
}
"@

function New-CcodexChunk([byte[]]$Bytes, [int]$DelayMs = 0) {
    return [Tuple[byte[], int]]::new($Bytes, $DelayMs)
}

$utf8 = New-Object System.Text.UTF8Encoding($false)

Write-Host "reads data then EOF within timeouts"
$chunks = @(
    (New-CcodexChunk $utf8.GetBytes('hello ') 0),
    (New-CcodexChunk $utf8.GetBytes('world') 50),
    (New-CcodexChunk ([byte[]]@()) 0)
)
$stream = [CcodexTestStream]::new($chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result 'hello world' 'concatenates chunks and stops at EOF'

Write-Host "preserves Traditional Chinese text exactly"
$zhText = '請審查這份規格文件'
$chunks = @((New-CcodexChunk $utf8.GetBytes($zhText) 0), (New-CcodexChunk ([byte[]]@()) 0))
$stream = [CcodexTestStream]::new($chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result $zhText 'decodes UTF-8 Traditional Chinese text exactly'

Write-Host "strips a UTF-8 BOM if present"
$bom = [byte[]]@(0xEF, 0xBB, 0xBF)
$chunks = @((New-CcodexChunk ($bom + $utf8.GetBytes('bom test')) 0), (New-CcodexChunk ([byte[]]@()) 0))
$stream = [CcodexTestStream]::new($chunks)
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result 'bom test' 'strips leading UTF-8 BOM before decoding'

Write-Host "empty stdin (immediate EOF) returns empty string, not an error"
$stream = [CcodexTestStream]::new(@((New-CcodexChunk ([byte[]]@()) 0)))
$result = Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 300 -NoProgressTimeoutMs 300
Assert-Equal $result '' 'immediate EOF yields empty string'

Write-Host "first-byte timeout when nothing arrives in time"
$chunks = @((New-CcodexChunk $utf8.GetBytes('late') 600))
$stream = [CcodexTestStream]::new($chunks)
Assert-Throws { Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 200 -NoProgressTimeoutMs 200 } 'throws when first byte/EOF does not arrive within the timeout'

Write-Host "no-progress timeout after some data has already arrived"
$chunks = @((New-CcodexChunk $utf8.GetBytes('start') 0), (New-CcodexChunk $utf8.GetBytes('late') 600))
$stream = [CcodexTestStream]::new($chunks)
Assert-Throws { Read-CcodexStdinWithTimeout -Stream $stream -FirstByteTimeoutMs 200 -NoProgressTimeoutMs 200 } 'throws when a later chunk stalls past the no-progress timeout'

Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/StdinTimeout.tests.ps1`
Expected: FAIL — `Read-CcodexStdinWithTimeout` not defined.

- [ ] **Step 3: Implement StdinTimeout.ps1**

```powershell
# lib/StdinTimeout.ps1
function Read-CcodexStdinWithTimeout {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$FirstByteTimeoutMs,
        [Parameter(Mandatory)][int]$NoProgressTimeoutMs
    )

    $buffer = [byte[]]::new(8192)
    $memory = New-Object System.IO.MemoryStream
    $sawAnyByte = $false

    while ($true) {
        $timeoutMs = if ($sawAnyByte) { $NoProgressTimeoutMs } else { $FirstByteTimeoutMs }
        $readTask = $Stream.ReadAsync($buffer, 0, $buffer.Length)
        if (-not $readTask.Wait($timeoutMs)) {
            if (-not $sawAnyByte) {
                throw "ccodex: redirected stdin produced neither data nor EOF within ${FirstByteTimeoutMs}ms. Pass --prompt-file or positional task text instead."
            } else {
                throw "ccodex: redirected stdin stalled for more than ${NoProgressTimeoutMs}ms without new data. Pass --prompt-file or positional task text instead."
            }
        }
        $bytesRead = $readTask.GetAwaiter().GetResult()
        if ($bytesRead -eq 0) {
            break
        }
        $sawAnyByte = $true
        $memory.Write($buffer, 0, $bytesRead)
    }

    $bytes = $memory.ToArray()
    if ($bytes.Length -eq 0) {
        return ''
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return $encoding.GetString($bytes)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/StdinTimeout.tests.ps1`
Expected: all `PASS`, `6 assertions, 0 failed`. This test takes roughly 1.5 real seconds to run (two induced ~600ms timeouts) — that is expected, not a hang.

- [ ] **Step 5: Re-run PromptSource tests to confirm no regression**

Run: `pwsh -NoProfile -File tests/PromptSource.tests.ps1`
Expected: unchanged, `10 assertions, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/StdinTimeout.ps1 tests/StdinTimeout.tests.ps1
git commit -m "feat: add ccodex bounded-timeout redirected-stdin reader"
```

---

### Task 6: Worker-prompt template resolution and rendering

**Files:**
- Create: `templates/worker-prompt.md`
- Create: `lib/WorkerPrompt.ps1`
- Test: `tests/WorkerPrompt.tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Get-CcodexWorkerPromptTemplatePath([string]$RepoRoot, [string]$AppDataRoot = $env:APPDATA) -> string`
  - `Build-CcodexWorkerPrompt([string]$TemplatePath, [string]$Mode, [string]$Access, [string]$RepoRoot, [string]$ArtifactDir, [string]$TaskContent) -> string`

- [ ] **Step 1: Write the default template**

```markdown
You are a background Codex worker called by Claude.
Answer the requested task directly.
Return only the final useful response in your last message.
Do not ask the user follow-up questions unless the task is impossible without them.
Do not modify files unless the access mode explicitly allows it.
For test tasks before worktree support, write screenshots, traces, caches, and logs only under
the artifact directory shown below. Do not modify repository source files.
Artifact directory: {{ARTIFACT_DIR}}
For review tasks, lead with findings ordered by severity.
For test tasks, include commands/actions run, observed result, evidence, and residual risks.
For brainstorming tasks, include options, trade-offs, and a recommendation.

Mode: {{MODE}}
Access: {{ACCESS}}
Repository: {{REPO_ROOT}}
```

Save as `templates/worker-prompt.md`.

- [ ] **Step 2: Write the failing test**

```powershell
# tests/WorkerPrompt.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\WorkerPrompt.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-workerprompt-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$appDataRoot = Join-Path $tempRoot 'AppData'
New-Item -ItemType Directory -Path (Join-Path $appDataRoot 'ccodex\templates') -Force | Out-Null
$userTemplate = Join-Path $appDataRoot 'ccodex\templates\worker-prompt.md'
[System.IO.File]::WriteAllText($userTemplate, "USER TEMPLATE Mode={{MODE}} Access={{ACCESS}} Repo={{REPO_ROOT}} Artifact={{ARTIFACT_DIR}}", (New-Object System.Text.UTF8Encoding($false)))

$repoRoot = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

Write-Host "falls back to the user-level template when no project override exists"
$path = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $appDataRoot
Assert-Equal $path $userTemplate 'resolves to the user-level template'

Write-Host "prefers a project-local .ccodex/worker-prompt.md override"
New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
$projectTemplate = Join-Path $repoRoot '.ccodex\worker-prompt.md'
[System.IO.File]::WriteAllText($projectTemplate, "PROJECT TEMPLATE {{MODE}}", (New-Object System.Text.UTF8Encoding($false)))
$path2 = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $appDataRoot
Assert-Equal $path2 $projectTemplate 'project-local override wins over the user-level default'

Write-Host "Build-CcodexWorkerPrompt substitutes placeholders and appends task content"
$rendered = Build-CcodexWorkerPrompt -TemplatePath $userTemplate -Mode 'review' -Access 'read-only' -RepoRoot $repoRoot -ArtifactDir $null -TaskContent 'please review this diff'
Assert-True ($rendered -like '*Mode=review*') 'substitutes {{MODE}}'
Assert-True ($rendered -like '*Access=read-only*') 'substitutes {{ACCESS}}'
Assert-True ($rendered -like "*Repo=$repoRoot*") 'substitutes {{REPO_ROOT}}'
Assert-True ($rendered -like '*Artifact=N/A*') 'read-only access renders a not-applicable artifact placeholder'
Assert-True ($rendered -like '*please review this diff*') 'appends the task content'

Write-Host "Build-CcodexWorkerPrompt injects a real artifact dir for workspace access"
$artifactDir = Join-Path $tempRoot 'artifacts'
$rendered2 = Build-CcodexWorkerPrompt -TemplatePath $userTemplate -Mode 'test' -Access 'workspace' -RepoRoot $repoRoot -ArtifactDir $artifactDir -TaskContent 'run the browser test'
Assert-True ($rendered2 -like "*Artifact=$artifactDir*") 'substitutes the absolute artifact directory'

Write-Host "Build-CcodexWorkerPrompt throws when the template is missing"
Assert-Throws { Build-CcodexWorkerPrompt -TemplatePath (Join-Path $tempRoot 'missing.md') -Mode 'review' -Access 'read-only' -RepoRoot $repoRoot -ArtifactDir $null -TaskContent 'x' } 'throws on a missing template file'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/WorkerPrompt.tests.ps1`
Expected: FAIL — functions not defined.

- [ ] **Step 4: Implement WorkerPrompt.ps1**

```powershell
# lib/WorkerPrompt.ps1
function Get-CcodexWorkerPromptTemplatePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$AppDataRoot = $env:APPDATA
    )
    $projectTemplate = Join-Path $RepoRoot '.ccodex\worker-prompt.md'
    if (Test-Path -LiteralPath $projectTemplate -PathType Leaf) {
        return $projectTemplate
    }
    return Join-Path $AppDataRoot 'ccodex\templates\worker-prompt.md'
}

function Build-CcodexWorkerPrompt {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ArtifactDir,
        [Parameter(Mandatory)][string]$TaskContent
    )
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "ccodex: worker prompt template not found at '$TemplatePath'. Run install.ps1 or check .ccodex/worker-prompt.md."
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $artifactText = if ($ArtifactDir) { $ArtifactDir } else { 'N/A (read-only access; no file writes permitted)' }

    $contract = $template.Replace('{{ARTIFACT_DIR}}', $artifactText).Replace('{{MODE}}', $Mode).Replace('{{ACCESS}}', $Access).Replace('{{REPO_ROOT}}', $RepoRoot)

    return "$contract`n`n---`n`n$TaskContent"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/WorkerPrompt.tests.ps1`
Expected: all `PASS`, `8 assertions, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add templates/worker-prompt.md lib/WorkerPrompt.ps1 tests/WorkerPrompt.tests.ps1
git commit -m "feat: add ccodex worker-prompt template resolution and rendering"
```

---

### Task 7: Mode/access validation and Codex argument building

**Files:**
- Create: `lib/ModeAccess.ps1`
- Test: `tests/ModeAccess.tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Resolve-CcodexAccess([string]$Mode, [string]$Access) -> string` (throws on invalid mode/access combos)
  - `ConvertTo-CcodexSandboxFlag([string]$Access) -> string` (`read-only` -> `read-only`, `workspace` -> `workspace-write`)
  - `Build-CcodexCodexArgs([string]$Access, [string]$RepoRoot, [string]$ResultPath) -> string[]`

- [ ] **Step 1: Write the failing test**

```powershell
# tests/ModeAccess.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')

Write-Host "default access per mode"
Assert-Equal (Resolve-CcodexAccess -Mode 'review' -Access $null) 'read-only' 'review defaults to read-only'
Assert-Equal (Resolve-CcodexAccess -Mode 'brainstorm' -Access $null) 'read-only' 'brainstorm defaults to read-only'

Write-Host "test mode requires an explicit access"
Assert-Throws { Resolve-CcodexAccess -Mode 'test' -Access $null } 'test mode has no default access'
Assert-Throws { Resolve-CcodexAccess -Mode 'test' -Access 'read-only' } 'test mode rejects read-only access'
Assert-Equal (Resolve-CcodexAccess -Mode 'test' -Access 'workspace') 'workspace' 'test mode accepts workspace access'

Write-Host "implement mode is blocked in Phase 1"
Assert-Throws { Resolve-CcodexAccess -Mode 'implement' -Access $null } 'implement mode is not available until Phase 4'
Assert-Throws { Resolve-CcodexAccess -Mode 'implement' -Access 'worktree' } 'implement mode is blocked even with an explicit access'

Write-Host "worktree access is blocked in Phase 1"
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'worktree' } 'worktree access is not available until Phase 4'

Write-Host "unknown mode/access"
Assert-Throws { Resolve-CcodexAccess -Mode 'bogus' -Access $null } 'throws on an unknown mode'
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'bogus' } 'throws on an unknown access'

Write-Host "ConvertTo-CcodexSandboxFlag"
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'read-only') 'read-only' 'maps read-only straight through'
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'workspace') 'workspace-write' 'maps workspace to workspace-write'

Write-Host "Build-CcodexCodexArgs"
$args = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md'
Assert-Equal ($args -join '|') (@('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-') -join '|') 'produces the exact codex exec argument shape'

Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/ModeAccess.tests.ps1`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement ModeAccess.ps1**

```powershell
# lib/ModeAccess.ps1
$script:CcodexValidModes = @('review', 'brainstorm', 'test', 'implement')
$script:CcodexValidAccess = @('read-only', 'workspace', 'worktree')
$script:CcodexDefaultAccessByMode = @{
    review     = 'read-only'
    brainstorm = 'read-only'
    test       = $null
    implement  = $null
}

function Resolve-CcodexAccess {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string]$Access
    )
    if ($Mode -notin $script:CcodexValidModes) {
        throw "ccodex: unknown mode '$Mode'. Valid modes: $($script:CcodexValidModes -join ', ')."
    }
    if ($Mode -eq 'implement') {
        throw "ccodex: mode 'implement' is not available until Phase 4 worktree isolation exists."
    }

    if (-not $Access) {
        $default = $script:CcodexDefaultAccessByMode[$Mode]
        if (-not $default) {
            throw "ccodex: mode '$Mode' has no default access. Pass --access explicitly (e.g. --access workspace)."
        }
        return $default
    }

    if ($Access -notin $script:CcodexValidAccess) {
        throw "ccodex: unknown access '$Access'. Valid access modes: $($script:CcodexValidAccess -join ', ')."
    }
    if ($Access -eq 'worktree') {
        throw "ccodex: --access worktree is not available until Phase 4 worktree isolation exists."
    }
    if ($Mode -eq 'test' -and $Access -eq 'read-only') {
        throw "ccodex: mode 'test' cannot use --access read-only. Browser/test tasks need --access workspace before worktree support."
    }

    return $Access
}

function ConvertTo-CcodexSandboxFlag {
    param([Parameter(Mandatory)][ValidateSet('read-only', 'workspace')][string]$Access)
    switch ($Access) {
        'read-only' { return 'read-only' }
        'workspace' { return 'workspace-write' }
    }
}

function Build-CcodexCodexArgs {
    param(
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ResultPath
    )
    $sandbox = ConvertTo-CcodexSandboxFlag -Access $Access
    return @(
        '--ask-for-approval', 'never',
        'exec',
        '--sandbox', $sandbox,
        '--json',
        '--color', 'never',
        '-C', $RepoRoot,
        '--output-last-message', $ResultPath,
        '-'
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/ModeAccess.tests.ps1`
Expected: all `PASS`, `13 assertions, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/ModeAccess.ps1 tests/ModeAccess.tests.ps1
git commit -m "feat: add ccodex mode/access validation and codex argument building"
```

---

### Task 8: Job file writers (text/JSON, atomic status writes, status/debug/worker-complete builders)

**Files:**
- Create: `lib/JobStore.ps1`
- Test: `tests/JobStore.tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Write-CcodexTextFile([string]$Path, [string]$Content) -> void` (UTF-8 no BOM)
  - `Write-CcodexJsonFile([string]$Path, $Object) -> void`
  - `Write-CcodexJsonFileAtomic([string]$Path, $Object) -> void` (temp file + `Move-Item -Force`)
  - `ConvertTo-CcodexCommandLineText([string]$Executable, [string[]]$Arguments) -> string`
  - `New-CcodexStatusObject([string]$JobId, [string]$Status, [string]$Mode, [string]$Access, [string]$Repo, [string]$CreatedAt, [Nullable[int]]$CodexExitCode, [Nullable[int]]$WrapperExitCode, [string]$ErrorMessage) -> [ordered]hashtable`
  - `New-CcodexDebugObject([string]$JobId, [string]$Repo, [string]$JobDir, [string]$Mode, [string]$Access, [string]$CodexPath, [string[]]$CodexArgs) -> [ordered]hashtable`
  - `New-CcodexWorkerCompleteObject([string]$JobId, [string]$StatusCandidate, [Nullable[int]]$CodexExitCode, [Nullable[int]]$WrapperExitCode, [bool]$ResultPresent, [string]$CompletedAt) -> [ordered]hashtable`

- [ ] **Step 1: Write the failing test**

```powershell
# tests/JobStore.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobstore-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Write-CcodexTextFile writes UTF-8 without BOM"
$textPath = Join-Path $tempRoot 'prompt.md'
Write-CcodexTextFile -Path $textPath -Content '請審查'
$bytes = [System.IO.File]::ReadAllBytes($textPath)
Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'no UTF-8 BOM is written'
Assert-Equal ([System.Text.Encoding]::UTF8.GetString($bytes)) '請審查' 'content round-trips exactly'

Write-Host "Write-CcodexJsonFile / Write-CcodexJsonFileAtomic"
$jsonPath = Join-Path $tempRoot 'status.json'
Write-CcodexJsonFileAtomic -Path $jsonPath -Object ([ordered]@{ a = 1; b = 'x' })
$roundTrip = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Assert-Equal $roundTrip.a 1 'atomic JSON write round-trips field a'
Assert-Equal $roundTrip.b 'x' 'atomic JSON write round-trips field b'
$leftoverTemp = Get-ChildItem -LiteralPath $tempRoot -Filter 'status.json.tmp-*'
Assert-Equal $leftoverTemp.Count 0 'no leftover .tmp file after atomic write'

Write-Host "ConvertTo-CcodexCommandLineText"
$cmdText = ConvertTo-CcodexCommandLineText -Executable 'C:\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', 'a b')
Assert-Equal $cmdText 'C:\codex.cmd exec --sandbox read-only "a b"' 'quotes only arguments containing whitespace'

Write-Host "New-CcodexStatusObject"
$status = New-CcodexStatusObject -JobId 'job1' -Status 'running' -Mode 'review' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-03T00:00:00Z'
Assert-Equal $status.job_id 'job1' 'status object carries job_id'
Assert-Equal $status.status 'running' 'status object carries status'
Assert-Equal $status.codex_exit_code $null 'codex_exit_code defaults to null'

Write-Host "New-CcodexDebugObject"
$debugObj = New-CcodexDebugObject -JobId 'job1' -Repo 'D:\Repo' -JobDir 'D:\Job' -Mode 'review' -Access 'read-only' -CodexPath 'C:\codex.cmd' -CodexArgs @('exec')
Assert-Equal $debugObj.backend 'sync' 'debug object records sync backend'
Assert-Equal $debugObj.codex_path 'C:\codex.cmd' 'debug object records resolved codex path'

Write-Host "New-CcodexWorkerCompleteObject"
$complete = New-CcodexWorkerCompleteObject -JobId 'job1' -StatusCandidate 'done' -CodexExitCode 0 -WrapperExitCode 0 -ResultPresent $true -CompletedAt '2026-07-03T00:01:00Z'
Assert-Equal $complete.status_candidate 'done' 'worker-complete records the status candidate'
Assert-Equal $complete.result_present $true 'worker-complete records result presence'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/JobStore.tests.ps1`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement JobStore.ps1**

```powershell
# lib/JobStore.ps1
function Write-CcodexTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-CcodexJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Depth 10
    Write-CcodexTextFile -Path $Path -Content $json
}

function Write-CcodexJsonFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $tempPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    Write-CcodexJsonFile -Path $tempPath -Object $Object
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function ConvertTo-CcodexCommandLineText {
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string[]]$Arguments)
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    return (@($Executable) + $quoted) -join ' '
}

function New-CcodexStatusObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$CreatedAt,
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [string]$ErrorMessage = $null
    )
    return [ordered]@{
        schema_version    = 1
        ccodex_version    = '0.1.0'
        job_id            = $JobId
        status            = $Status
        mode              = $Mode
        access            = $Access
        repo              = $Repo
        created_at        = $CreatedAt
        codex_exit_code   = $CodexExitCode
        wrapper_exit_code = $WrapperExitCode
        error             = $ErrorMessage
    }
}

function New-CcodexDebugObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$CodexArgs
    )
    return [ordered]@{
        job_id              = $JobId
        powershell_version  = $PSVersionTable.PSVersion.ToString()
        os_description      = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        repo                = $Repo
        job_dir             = $JobDir
        mode                = $Mode
        access              = $Access
        backend             = 'sync'
        codex_path          = $CodexPath
        codex_args          = $CodexArgs
    }
}

function New-CcodexWorkerCompleteObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$StatusCandidate,
        [Nullable[int]]$CodexExitCode,
        [Nullable[int]]$WrapperExitCode,
        [Parameter(Mandatory)][bool]$ResultPresent,
        [Parameter(Mandatory)][string]$CompletedAt
    )
    return [ordered]@{
        job_id            = $JobId
        status_candidate  = $StatusCandidate
        codex_exit_code   = $CodexExitCode
        wrapper_exit_code = $WrapperExitCode
        result_present    = $ResultPresent
        completed_at      = $CompletedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/JobStore.tests.ps1`
Expected: all `PASS`, `10 assertions, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/JobStore.ps1 tests/JobStore.tests.ps1
git commit -m "feat: add ccodex job file writers"
```

---

### Task 9: Codex process invocation (Win32 argv quoting, `.cmd` shim launch planning, stream capture)

**Files:**
- Create: `lib/CodexInvoke.ps1`
- Create: `tests/fixtures/fake-codex.ps1`
- Create: `tests/fixtures/fake-codex.cmd`
- Test: `tests/CodexInvoke.tests.ps1`

**Context:** the real `codex` command on this machine resolves to `codex.cmd` (an npm shim), not a raw `.exe`. `System.Diagnostics.Process` with `UseShellExecute = $false` (required for stream redirection) cannot launch a `.cmd`/`.bat` directly — it must be wrapped through `cmd.exe /d /s /c "<quoted inner command>"`. This task implements that wrapping and verifies it against a fixture shaped exactly like the real `codex.cmd` (a `.cmd` that delegates to a script).

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `ConvertTo-CcodexWin32QuotedArgument([string]$Argument) -> string`
  - `Get-CcodexProcessLaunchPlan([string]$CodexPath, [string[]]$Arguments) -> [pscustomobject]@{ FileName; ArgumentList }`
  - `Invoke-CcodexCodexProcess([string]$CodexPath, [string[]]$Arguments, [string]$PromptContent, [string]$EventsLogPath, [string]$StderrLogPath, [string]$ExitCodeFilePath) -> int`

- [ ] **Step 1: Write the fixture files**

```powershell
# tests/fixtures/fake-codex.ps1
param()
$null = [Console]::In.ReadToEnd()
$argsList = $args
$resultPath = $null
for ($i = 0; $i -lt $argsList.Count; $i++) {
    if ($argsList[$i] -eq '--output-last-message' -and ($i + 1) -lt $argsList.Count) {
        $resultPath = $argsList[$i + 1]
    }
}
Write-Output '{"type":"event","msg":"fake-codex ran"}'
[Console]::Error.WriteLine('fake-codex stderr line')
$exitCode = 0
if ($env:CCODEX_FAKE_EXIT_CODE) { $exitCode = [int]$env:CCODEX_FAKE_EXIT_CODE }
$resultText = if ($env:CCODEX_FAKE_RESULT) { $env:CCODEX_FAKE_RESULT } else { 'FAKE_RESULT_OK' }
if ($resultPath -and $exitCode -eq 0 -and $env:CCODEX_FAKE_SKIP_RESULT -ne '1') {
    [System.IO.File]::WriteAllText($resultPath, $resultText, (New-Object System.Text.UTF8Encoding($false)))
}
exit $exitCode
```

```batch
:: tests/fixtures/fake-codex.cmd
@echo off
pwsh -NoProfile -File "%~dp0fake-codex.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 2: Write the failing test**

```powershell
# tests/CodexInvoke.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')

Write-Host "ConvertTo-CcodexWin32QuotedArgument"
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'plain') 'plain' 'no quoting needed for a plain argument'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a b') '"a b"' 'wraps an argument containing a space'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a"b') '"a\"b"' 'escapes an embedded quote'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument '') '""' 'empty argument becomes an empty quoted pair'

Write-Host "Get-CcodexProcessLaunchPlan for a .cmd target"
$plan = Get-CcodexProcessLaunchPlan -CodexPath 'C:\npm\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', '-C', 'D:\Repo With Space')
Assert-Equal $plan.FileName "$env:SystemRoot\System32\cmd.exe" '.cmd targets launch through cmd.exe'
Assert-Equal $plan.ArgumentList[0] '/d' 'first cmd.exe arg is /d'
Assert-Equal $plan.ArgumentList[1] '/s' 'second cmd.exe arg is /s'
Assert-Equal $plan.ArgumentList[2] '/c' 'third cmd.exe arg is /c'
Assert-True ($plan.ArgumentList[3] -like '*codex.cmd*') 'the wrapped command includes the codex.cmd path'
Assert-True ($plan.ArgumentList[3] -like '*"D:\Repo With Space"*') 'the wrapped command quotes the space-containing repo path'

Write-Host "Get-CcodexProcessLaunchPlan for a non-.cmd target"
$plan2 = Get-CcodexProcessLaunchPlan -CodexPath 'C:\codex.exe' -Arguments @('exec')
Assert-Equal $plan2.FileName 'C:\codex.exe' 'non-.cmd targets launch directly'
Assert-Equal ($plan2.ArgumentList -join '|') 'exec' 'non-.cmd arguments pass through unchanged'

Write-Host "Invoke-CcodexCodexProcess against the fake-codex.ps1 fixture directly"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$eventsPath = Join-Path $tempRoot 'codex-events.jsonl'
$stderrPath = Join-Path $tempRoot 'stderr.log'
$exitCodeFilePath = Join-Path $tempRoot 'exit_code.txt'
$resultPath = Join-Path $tempRoot 'result.md'
$fixturePs1 = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'
$pwshPath = (Get-Command 'pwsh').Source

$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'hello from fake codex'
$exitCode = Invoke-CcodexCodexProcess -CodexPath $pwshPath -Arguments @('-NoProfile', '-File', $fixturePs1, '--output-last-message', $resultPath) -PromptContent 'the prompt' -EventsLogPath $eventsPath -StderrLogPath $stderrPath -ExitCodeFilePath $exitCodeFilePath
Assert-Equal $exitCode 0 'returns the fake process exit code'
Assert-True ((Get-Content -LiteralPath $eventsPath -Raw) -like '*fake-codex ran*') 'captures stdout into the events log'
Assert-True ((Get-Content -LiteralPath $stderrPath -Raw) -like '*fake-codex stderr line*') 'captures stderr into the stderr log'
Assert-Equal (Get-Content -LiteralPath $exitCodeFilePath -Raw) '0' 'writes the raw exit code to exit_code.txt'
Assert-Equal (Get-Content -LiteralPath $resultPath -Raw) 'hello from fake codex' 'the fixture wrote the expected result content'

Write-Host "Invoke-CcodexCodexProcess against the fake-codex.cmd fixture (exercises the cmd.exe wrapping path)"
$env:CCODEX_FAKE_EXIT_CODE = '7'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$resultPath2 = Join-Path $tempRoot 'result2.md'
$eventsPath2 = Join-Path $tempRoot 'codex-events2.jsonl'
$stderrPath2 = Join-Path $tempRoot 'stderr2.log'
$exitCodeFilePath2 = Join-Path $tempRoot 'exit_code2.txt'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'
$exitCode2 = Invoke-CcodexCodexProcess -CodexPath $fixtureCmd -Arguments @('--output-last-message', $resultPath2) -PromptContent 'another prompt' -EventsLogPath $eventsPath2 -StderrLogPath $stderrPath2 -ExitCodeFilePath $exitCodeFilePath2
Assert-Equal $exitCode2 7 'nonzero exit code survives the cmd.exe wrapping path'
Assert-Equal (Get-Content -LiteralPath $exitCodeFilePath2 -Raw) '7' 'exit_code.txt reflects the wrapped process exit code'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/CodexInvoke.tests.ps1`
Expected: FAIL — functions not defined.

- [ ] **Step 4: Implement CodexInvoke.ps1**

```powershell
# lib/CodexInvoke.ps1
function ConvertTo-CcodexWin32QuotedArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$result.Append('\' * (($backslashes * 2) + 1))
            [void]$result.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$result.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$result.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$result.Append('\' * ($backslashes * 2)) }
    [void]$result.Append('"')
    return $result.ToString()
}

function Get-CcodexProcessLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $extension = [System.IO.Path]::GetExtension($CodexPath).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $quotedParts = @($CodexPath) + $Arguments | ForEach-Object { ConvertTo-CcodexWin32QuotedArgument $_ }
        $innerCommand = $quotedParts -join ' '
        return [pscustomobject]@{
            FileName     = "$env:SystemRoot\System32\cmd.exe"
            ArgumentList = @('/d', '/s', '/c', "`"$innerCommand`"")
        }
    }
    return [pscustomobject]@{
        FileName     = $CodexPath
        ArgumentList = $Arguments
    }
}

function Invoke-CcodexCodexProcess {
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptContent,
        [Parameter(Mandatory)][string]$EventsLogPath,
        [Parameter(Mandatory)][string]$StderrLogPath,
        [Parameter(Mandatory)][string]$ExitCodeFilePath
    )
    $plan = Get-CcodexProcessLaunchPlan -CodexPath $CodexPath -Arguments $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $plan.FileName
    foreach ($arg in $plan.ArgumentList) { [void]$psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardInputEncoding = $utf8NoBom
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    $process.StandardInput.Write($PromptContent)
    $process.StandardInput.Close()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    Write-CcodexTextFile -Path $EventsLogPath -Content $stdout
    Write-CcodexTextFile -Path $StderrLogPath -Content $stderr
    Write-CcodexTextFile -Path $ExitCodeFilePath -Content "$($process.ExitCode)"

    return $process.ExitCode
}
```

Note: `Invoke-CcodexCodexProcess` calls `Write-CcodexTextFile`, defined in `lib/JobStore.ps1` (Task 8). The test file above dot-sources only `CodexInvoke.ps1`, so add this line near the top of `CodexInvoke.tests.ps1`, right after the `TestHelpers.ps1` dot-source: `. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')`.

- [ ] **Step 5: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/CodexInvoke.tests.ps1`
Expected: all `PASS`, `15 assertions, 0 failed`. The `.cmd` fixture case proves the `cmd.exe /d /s /c` wrapping actually works end-to-end on this machine before it is trusted against the real `codex.cmd`.

- [ ] **Step 6: Commit**

```bash
git add lib/CodexInvoke.ps1 tests/fixtures/fake-codex.ps1 tests/fixtures/fake-codex.cmd tests/CodexInvoke.tests.ps1
git commit -m "feat: add ccodex process invocation with cmd-shim launch planning"
```

---

### Task 10: Result validation

**Files:**
- Create: `lib/ResultValidation.ps1`
- Test: `tests/ResultValidation.tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Test-CcodexResult([int]$CodexExitCode, [string]$ResultPath) -> [pscustomobject]@{ Status; WrapperExitCode; ResultPresent; ResultContent }`

- [ ] **Step 1: Write the failing test**

```powershell
# tests/ResultValidation.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-resultvalidation-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Host "codex exit 0 with a non-empty result -> done/0"
$resultPath = Join-Path $tempRoot 'result-ok.md'
[System.IO.File]::WriteAllText($resultPath, 'the answer', $utf8NoBom)
$v = Test-CcodexResult -CodexExitCode 0 -ResultPath $resultPath
Assert-Equal $v.Status 'done' 'status is done'
Assert-Equal $v.WrapperExitCode 0 'wrapper exit code is 0'
Assert-Equal $v.ResultPresent $true 'result present is true'
Assert-Equal $v.ResultContent 'the answer' 'result content is returned'

Write-Host "codex exit 0 with a missing result -> failed/11"
$missingPath = Join-Path $tempRoot 'does-not-exist.md'
$v2 = Test-CcodexResult -CodexExitCode 0 -ResultPath $missingPath
Assert-Equal $v2.Status 'failed' 'status is failed'
Assert-Equal $v2.WrapperExitCode 11 'wrapper exit code is 11'
Assert-Equal $v2.ResultPresent $false 'result present is false'

Write-Host "codex exit 0 with an empty (whitespace-only) result -> failed/11"
$emptyPath = Join-Path $tempRoot 'result-empty.md'
[System.IO.File]::WriteAllText($emptyPath, "   `n", $utf8NoBom)
$v3 = Test-CcodexResult -CodexExitCode 0 -ResultPath $emptyPath
Assert-Equal $v3.Status 'failed' 'whitespace-only result counts as empty'
Assert-Equal $v3.WrapperExitCode 11 'wrapper exit code is 11 for an empty result'

Write-Host "nonzero codex exit code -> failed/10 regardless of result presence"
$v4 = Test-CcodexResult -CodexExitCode 5 -ResultPath $resultPath
Assert-Equal $v4.Status 'failed' 'status is failed on nonzero codex exit'
Assert-Equal $v4.WrapperExitCode 10 'wrapper exit code is 10'
Assert-Equal $v4.ResultPresent $true 'result presence is still reported accurately'

$v5 = Test-CcodexResult -CodexExitCode 5 -ResultPath $missingPath
Assert-Equal $v5.WrapperExitCode 10 'nonzero exit code takes precedence over a missing result (still 10, not 11)'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/ResultValidation.tests.ps1`
Expected: FAIL — `Test-CcodexResult` not defined.

- [ ] **Step 3: Implement ResultValidation.ps1**

```powershell
# lib/ResultValidation.ps1
function Test-CcodexResult {
    param(
        [Parameter(Mandatory)][int]$CodexExitCode,
        [Parameter(Mandatory)][string]$ResultPath
    )
    $resultExists = Test-Path -LiteralPath $ResultPath -PathType Leaf
    $resultContent = if ($resultExists) { Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 } else { '' }
    $resultNonEmpty = $resultExists -and $resultContent.Trim().Length -gt 0

    if ($CodexExitCode -ne 0) {
        return [pscustomobject]@{
            Status          = 'failed'
            WrapperExitCode = 10
            ResultPresent   = $resultNonEmpty
            ResultContent   = $resultContent
        }
    }

    if (-not $resultNonEmpty) {
        return [pscustomobject]@{
            Status          = 'failed'
            WrapperExitCode = 11
            ResultPresent   = $false
            ResultContent   = ''
        }
    }

    return [pscustomobject]@{
        Status          = 'done'
        WrapperExitCode = 0
        ResultPresent   = $true
        ResultContent   = $resultContent
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File tests/ResultValidation.tests.ps1`
Expected: all `PASS`, `11 assertions, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/ResultValidation.ps1 tests/ResultValidation.tests.ps1
git commit -m "feat: add ccodex result validation"
```

---

### Task 11: `ccodex.ps1` dispatcher and `Invoke-CcodexRun` orchestration

**Files:**
- Create: `ccodex.ps1`
- Test: `tests/RunCommand.tests.ps1`

**Interfaces:**
- Consumes every function from Tasks 1–10 (`Get-CcodexRepoKey`, `Get-CcodexIndexPath`, `Resolve-CcodexRepo`, `Reserve-CcodexJobDir`, `Get-CcodexPromptContent`, `Get-CcodexWorkerPromptTemplatePath`, `Build-CcodexWorkerPrompt`, `Resolve-CcodexAccess`, `Build-CcodexCodexArgs`, `Write-CcodexTextFile`, `Write-CcodexJsonFileAtomic`, `ConvertTo-CcodexCommandLineText`, `New-CcodexStatusObject`, `New-CcodexDebugObject`, `New-CcodexWorkerCompleteObject`, `Invoke-CcodexCodexProcess`, `Test-CcodexResult`).
- Produces: the `Invoke-CcodexRun` function (importable via dot-sourcing for tests) and the `ccodex.ps1` top-level dispatcher (only exercised through the real CLI entry point, not unit-tested directly — Task 12 covers that).

- [ ] **Step 1: Write the failing test for `Invoke-CcodexRun`, using the fake-codex fixture from Task 9**

```powershell
# tests/RunCommand.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobId.ps1')
. (Join-Path $PSScriptRoot '..\lib\StdinTimeout.ps1')
. (Join-Path $PSScriptRoot '..\lib\PromptSource.ps1')
. (Join-Path $PSScriptRoot '..\lib\WorkerPrompt.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-runcommand-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
New-Item -ItemType Directory -Path $localAppData, $appData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '..\templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$repoRoot = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

function Invoke-CcodexRunForTest {
    param([hashtable]$Overrides = @{})
    $base = @{
        Mode                   = 'review'
        Access                 = $null
        RepoOverride           = $repoRoot
        PromptFile             = $null
        PositionalTask         = 'do the review'
        PipelineExpected       = $false
        PipelineObjects        = $null
        CodexPath              = $fixtureCmd
        LocalAppDataRoot       = $localAppData
        AppDataRoot            = $appData
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return Invoke-CcodexRun @base
}

Write-Host "successful run: exit 0, job files written, only result printed"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'REVIEW: looks fine'
$stdout = $null
$exitCode = $null
$stdout = & { Invoke-CcodexRunForTest } 6>&1 | Tee-Object -Variable capturedOut
# Invoke-CcodexRun returns the wrapper exit code and writes the result via Write-Output;
# capture both by calling it inside a scriptblock and inspecting $LASTEXITCODE-equivalent return value.
$result = Invoke-CcodexRunForTest
Assert-Equal $result.WrapperExitCode 0 'wrapper exit code is 0 on success'
Assert-True ($result.Stdout -like '*REVIEW: looks fine*') 'stdout carries only the fake result content'
Assert-True (-not ($result.Stdout -like '*fake-codex ran*')) 'raw JSONL events never reach stdout'

$jobDir = $result.JobDir
foreach ($file in @('prompt.md', 'command.txt', 'debug.json', 'status.json', 'codex-events.jsonl', 'stderr.log', 'exit_code.txt', 'worker-complete.json', 'result.md')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $jobDir $file) -PathType Leaf) "writes $file"
}
$statusJson = Get-Content -LiteralPath (Join-Path $jobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusJson.status 'done' 'final status.json status is done'
Assert-Equal $statusJson.codex_exit_code 0 'status.json records codex_exit_code separately'
Assert-Equal $statusJson.wrapper_exit_code 0 'status.json records wrapper_exit_code separately'

Write-Host "jobs are written under the global state root, not under the repo"
Assert-True ($jobDir -like "$localAppData*") 'job dir lives under the fake LOCALAPPDATA root'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.ccodex\jobs'))) 'no .ccodex/jobs is created inside the repo'

Write-Host "mode 'test' without --access workspace fails before invoking codex"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$result2 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'test'; Access = $null }
Assert-Equal $result2.WrapperExitCode 2 'exit code 2 for test mode without --access workspace'

Write-Host "mode 'implement' is rejected"
$result3 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'implement' }
Assert-Equal $result3.WrapperExitCode 2 'exit code 2 for implement mode'

Write-Host "mode 'test' with --access workspace creates an artifacts dir and injects it into the prompt"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'artifact test done'
$result4 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'test'; Access = 'workspace'; PositionalTask = 'run the browser test' }
Assert-Equal $result4.WrapperExitCode 0 'workspace access succeeds against the fixture'
Assert-True (Test-Path -LiteralPath (Join-Path $result4.JobDir 'artifacts') -PathType Container) 'creates <job_dir>/artifacts'
$promptContent = Get-Content -LiteralPath (Join-Path $result4.JobDir 'prompt.md') -Raw
Assert-True ($promptContent -like "*$(Join-Path $result4.JobDir 'artifacts')*") 'prompt.md references the absolute artifact directory'

Write-Host "codex exit nonzero -> wrapper exit code 10, worker-complete.json still written"
$env:CCODEX_FAKE_EXIT_CODE = '3'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$result5 = Invoke-CcodexRunForTest
Assert-Equal $result5.WrapperExitCode 10 'wrapper exit code is 10 when codex exits nonzero'
Assert-True (Test-Path -LiteralPath (Join-Path $result5.JobDir 'worker-complete.json') -PathType Leaf) 'worker-complete.json exists on the failure path too'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
```

Note: the awkward capture in the first scenario (`Tee-Object`/`$capturedOut`) is a leftover exploration line — delete it. The clean version only needs `$result = Invoke-CcodexRunForTest` since `Invoke-CcodexRun` returns a single object carrying `WrapperExitCode`, `Stdout`, and `JobDir` (see Step 3). Fix the test file to remove the stray `$stdout =` / `Tee-Object` lines before running it.

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File tests/RunCommand.tests.ps1`
Expected: FAIL — `ccodex.ps1` does not exist / does not support `-ImportOnly` / `Invoke-CcodexRun` not defined.

- [ ] **Step 3: Implement `ccodex.ps1`**

`Invoke-CcodexRun` returns a `[pscustomobject]` with `WrapperExitCode`, `Stdout` (the exact text that would go to parent stdout), and `JobDir` (for test/debugging convenience) instead of printing directly, so tests can assert on it without scraping console output. The top-level dispatcher (only reached when the script is actually run, not when dot-sourced with `-ImportOnly`) is the piece that prints `Stdout`/failure text to the real console and calls `exit`.

```powershell
# ccodex.ps1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$PositionalTask,

    [string]$Mode,
    [string]$Access,
    [string]$Repo,
    [string]$PromptFile,

    [switch]$ImportOnly
)

$ErrorActionPreference = 'Stop'

$pipelineExpected = $MyInvocation.ExpectingInput
$pipelineObjects = $null
if ($pipelineExpected) {
    $pipelineObjects = @($input)
}

. (Join-Path $PSScriptRoot 'lib\Paths.ps1')
. (Join-Path $PSScriptRoot 'lib\Repo.ps1')
. (Join-Path $PSScriptRoot 'lib\JobId.ps1')
. (Join-Path $PSScriptRoot 'lib\StdinTimeout.ps1')
. (Join-Path $PSScriptRoot 'lib\PromptSource.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkerPrompt.ps1')
. (Join-Path $PSScriptRoot 'lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot 'lib\JobStore.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot 'lib\ResultValidation.ps1')

function Invoke-CcodexRun {
    param(
        [string]$Mode,
        [string]$Access,
        [string]$RepoOverride,
        [string]$PromptFile,
        [string]$PositionalTask,
        [bool]$PipelineExpected,
        [object[]]$PipelineObjects,
        [string]$CodexPath,
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA
    )

    if (-not $Mode -or $Mode -notin @('review', 'brainstorm', 'test', 'implement')) {
        $message = "ccodex: --mode is required and must be one of: review, brainstorm, test, implement."
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; JobDir = $null; Message = $message }
    }

    try {
        $repoRoot = Resolve-CcodexRepo -RepoOverride $RepoOverride
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; JobDir = $null; Message = $_.Exception.Message }
    }

    $repoKey = Get-CcodexRepoKey -RepoRoot $repoRoot
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $LocalAppDataRoot
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    Write-CcodexJsonFileAtomic -Path (Get-CcodexIndexPath -JobId $jobId -Root $LocalAppDataRoot) -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')

    function Complete-CcodexUsageError {
        param([string]$Message, [string]$AccessForStatus)
        $statusObj = New-CcodexStatusObject -JobId $jobId -Status 'failed' -Mode $Mode -Access ($(if ($AccessForStatus) { $AccessForStatus } else { '' })) -Repo $repoRoot -CreatedAt $createdAt -WrapperExitCode 2 -ErrorMessage $Message
        Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; JobDir = $jobDir; Message = "$Message`n  job:      $jobId`n  job dir:  $jobDir" }
    }

    try {
        $resolvedAccess = Resolve-CcodexAccess -Mode $Mode -Access $Access
    } catch {
        return Complete-CcodexUsageError -Message $_.Exception.Message -AccessForStatus $Access
    }

    try {
        $taskContent = Get-CcodexPromptContent `
            -ExpectingPipelineInput $PipelineExpected `
            -PipelineObjects $PipelineObjects `
            -PromptFile $PromptFile `
            -PositionalTask $PositionalTask `
            -StdinStream ([Console]::OpenStandardInput()) `
            -StdinIsRedirected ([Console]::IsInputRedirected)
    } catch {
        return Complete-CcodexUsageError -Message $_.Exception.Message -AccessForStatus $resolvedAccess
    }

    $artifactDir = $null
    if ($resolvedAccess -eq 'workspace') {
        $artifactDir = Join-Path $jobDir 'artifacts'
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }

    $templatePath = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $AppDataRoot
    $workerPrompt = Build-CcodexWorkerPrompt -TemplatePath $templatePath -Mode $Mode -Access $resolvedAccess -RepoRoot $repoRoot -ArtifactDir $artifactDir -TaskContent $taskContent
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $workerPrompt

    $resultPath = Join-Path $jobDir 'result.md'
    $resolvedCodexPath = if ($CodexPath) { $CodexPath } else { (Get-Command 'codex' -ErrorAction Stop).Source }
    $codexArgs = Build-CcodexCodexArgs -Access $resolvedAccess -RepoRoot $repoRoot -ResultPath $resultPath

    Write-CcodexTextFile -Path (Join-Path $jobDir 'command.txt') -Content (ConvertTo-CcodexCommandLineText -Executable $resolvedCodexPath -Arguments $codexArgs)
    Write-CcodexJsonFile -Path (Join-Path $jobDir 'debug.json') -Object (New-CcodexDebugObject -JobId $jobId -Repo $repoRoot -JobDir $jobDir -Mode $Mode -Access $resolvedAccess -CodexPath $resolvedCodexPath -CodexArgs $codexArgs)
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status 'running' -Mode $Mode -Access $resolvedAccess -Repo $repoRoot -CreatedAt $createdAt)

    $eventsPath = Join-Path $jobDir 'codex-events.jsonl'
    $stderrPath = Join-Path $jobDir 'stderr.log'
    $exitCodeFilePath = Join-Path $jobDir 'exit_code.txt'

    $codexExitCode = Invoke-CcodexCodexProcess -CodexPath $resolvedCodexPath -Arguments $codexArgs -PromptContent $workerPrompt -EventsLogPath $eventsPath -StderrLogPath $stderrPath -ExitCodeFilePath $exitCodeFilePath

    $preliminaryComplete = New-CcodexWorkerCompleteObject -JobId $jobId -StatusCandidate $(if ($codexExitCode -eq 0) { 'done' } else { 'failed' }) -CodexExitCode $codexExitCode -WrapperExitCode $null -ResultPresent (Test-Path -LiteralPath $resultPath -PathType Leaf) -CompletedAt (Get-Date).ToString('o')
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'worker-complete.json') -Object $preliminaryComplete

    $validation = Test-CcodexResult -CodexExitCode $codexExitCode -ResultPath $resultPath

    $finalComplete = New-CcodexWorkerCompleteObject -JobId $jobId -StatusCandidate $validation.Status -CodexExitCode $codexExitCode -WrapperExitCode $validation.WrapperExitCode -ResultPresent $validation.ResultPresent -CompletedAt (Get-Date).ToString('o')
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'worker-complete.json') -Object $finalComplete

    $finalStatusObj = New-CcodexStatusObject -JobId $jobId -Status $validation.Status -Mode $Mode -Access $resolvedAccess -Repo $repoRoot -CreatedAt $createdAt -CodexExitCode $codexExitCode -WrapperExitCode $validation.WrapperExitCode
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $finalStatusObj

    if ($validation.WrapperExitCode -eq 0) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; JobDir = $jobDir; Message = $null }
    }

    $failureMessage = "ccodex: job $jobId $($validation.Status) (codex_exit_code=$codexExitCode, wrapper_exit_code=$($validation.WrapperExitCode))`n  job dir: $jobDir`n  result:  $resultPath"
    return [pscustomobject]@{ WrapperExitCode = $validation.WrapperExitCode; Stdout = $null; JobDir = $jobDir; Message = $failureMessage }
}

if ($ImportOnly) { return }

$exitCode = 12
try {
    switch ($Command) {
        'run' {
            $runResult = Invoke-CcodexRun -Mode $Mode -Access $Access -RepoOverride $Repo -PromptFile $PromptFile -PositionalTask $PositionalTask -PipelineExpected $pipelineExpected -PipelineObjects $pipelineObjects
            if ($runResult.WrapperExitCode -eq 0) {
                Write-Output $runResult.Stdout
            } else {
                Write-Host $runResult.Message
            }
            $exitCode = $runResult.WrapperExitCode
        }
        default {
            Write-Host "ccodex: command '$Command' is not implemented in Phase 1. Supported commands: run."
            $exitCode = 2
        }
    }
} catch {
    Write-Host "ccodex: internal error: $($_.Exception.Message)"
    $exitCode = 12
}
exit $exitCode
```

- [ ] **Step 4: Fix the test file's stray capture lines, then run it**

Edit `RunCommand.tests.ps1`: delete the three lines between `Write-Host "successful run..."` and `$result = Invoke-CcodexRunForTest` (the `$stdout = $null`, `$exitCode = $null`, and `$stdout = & { ... } 6>&1 | Tee-Object ...` lines) — they were exploratory and are superseded by the single `$result = Invoke-CcodexRunForTest` call plus `$result.Stdout` assertions already written below them.

Run: `pwsh -NoProfile -File tests/RunCommand.tests.ps1`
Expected: all `PASS`, `19 assertions, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add ccodex.ps1 tests/RunCommand.tests.ps1
git commit -m "feat: add ccodex run command dispatcher and orchestration"
```

---

### Task 12: Install script and manual end-to-end verification against the real `codex` CLI

**Files:**
- Create: `ccodex.cmd`
- Create: `install.ps1`

**Interfaces:**
- Consumes: the full repository tree from Tasks 1–11.
- Produces: an installed copy under `%USERPROFILE%\.local\bin\ccodex\` + `%USERPROFILE%\.local\bin\ccodex.cmd` + `%APPDATA%\ccodex\templates\worker-prompt.md`, and the manual verification evidence required by the spec's Phase 1 checklist.

- [ ] **Step 1: Write the PATH shim**

```batch
:: ccodex.cmd
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ccodex.ps1" %*
exit /b %ERRORLEVEL%
```

- [ ] **Step 2: Write install.ps1**

```powershell
# install.ps1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [string]$TemplatesDir = (Join-Path $env:APPDATA 'ccodex\templates')
)

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$destScriptDir = Join-Path $InstallDir 'ccodex'

New-Item -ItemType Directory -Path $destScriptDir -Force | Out-Null
Copy-Item -Path (Join-Path $sourceRoot 'ccodex.ps1') -Destination $destScriptDir -Force
Copy-Item -Path (Join-Path $sourceRoot 'lib') -Destination $destScriptDir -Recurse -Force

$shimContent = @"
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$destScriptDir\ccodex.ps1" %*
exit /b %ERRORLEVEL%
"@
$shimPath = Join-Path $InstallDir 'ccodex.cmd'
[System.IO.File]::WriteAllText($shimPath, $shimContent, (New-Object System.Text.UTF8Encoding($false)))

New-Item -ItemType Directory -Path $TemplatesDir -Force | Out-Null
$templateDest = Join-Path $TemplatesDir 'worker-prompt.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\worker-prompt.md') -Destination $templateDest -Force

Write-Host "ccodex installed to $destScriptDir"
Write-Host "shim: $shimPath"
Write-Host "default template: $templateDest"
if (($env:PATH -split ';') -notcontains $InstallDir) {
    Write-Host "WARNING: $InstallDir is not on PATH. Add it to your user PATH to use 'ccodex' from any directory." -ForegroundColor Yellow
}
```

`install.ps1` never edits the system/user `PATH` environment variable itself — it only warns. On this machine `C:\Users\lenticetsai\.local\bin` is already confirmed to be on `PATH`, so no PATH change is required here; do not add one without the user's explicit request.

- [ ] **Step 3: Run install.ps1**

Run: `pwsh -NoProfile -File install.ps1`
Expected: prints the three `ccodex installed...` / `shim:` / `default template:` lines and no PATH warning (since `.local\bin` is already on `PATH` in this environment).

- [ ] **Step 4: Manually verify `ccodex` is callable from two different project directories without copying the source**

Run (from any two unrelated directories, e.g. `D:\` and `D:\Work`):

```powershell
Set-Location D:\
"Reply with exactly the word OK and nothing else." | ccodex run --mode review --repo D:\Work\Code\Quotation\Docker
```

```powershell
Set-Location D:\Work
"Reply with exactly the word OK and nothing else." | ccodex run --mode review --repo D:\Work\Code\Quotation\Docker
```

Expected: both calls print a short Codex reply to stdout, exit code `0` (check with `$LASTEXITCODE` in PowerShell), and neither directory ends up with a copy of `tools\ccodex\` or a `.ccodex\jobs\` folder. This exercises the real `codex` CLI end-to-end (network + auth), unlike every earlier automated test, which used the `fake-codex` fixture — do not automate this step into the regression suite; it costs real API usage and depends on live `codex` auth.

- [ ] **Step 5: Manually verify the OS-level redirected-stdin path with Traditional Chinese and the 2s/5s timeout behavior**

```powershell
"請用一句話總結你能做什麼，並且只回覆這一句話。" | ccodex run --mode brainstorm --repo D:\Work\Code\Quotation\Docker
```

Expected: `job dir\prompt.md` contains the Traditional Chinese text unchanged (open it and confirm no mojibake), and the command completes normally.

```powershell
cmd /c "ccodex run --mode review --repo D:\Work\Code\Quotation\Docker < NUL"
```

Expected: exits quickly (within ~2 seconds) with wrapper exit code `2` and a message about redirected stdin producing no data — this confirms the first-byte timeout path fires instead of hanging.

- [ ] **Step 6: Confirm the whole automated suite still passes together**

Run each of the following in sequence and confirm every one prints `0 failed`:

```powershell
pwsh -NoProfile -File tests/Paths.tests.ps1
pwsh -NoProfile -File tests/Repo.tests.ps1
pwsh -NoProfile -File tests/JobId.tests.ps1
pwsh -NoProfile -File tests/PromptSource.tests.ps1
pwsh -NoProfile -File tests/StdinTimeout.tests.ps1
pwsh -NoProfile -File tests/WorkerPrompt.tests.ps1
pwsh -NoProfile -File tests/ModeAccess.tests.ps1
pwsh -NoProfile -File tests/JobStore.tests.ps1
pwsh -NoProfile -File tests/CodexInvoke.tests.ps1
pwsh -NoProfile -File tests/ResultValidation.tests.ps1
pwsh -NoProfile -File tests/RunCommand.tests.ps1
```

- [ ] **Step 7: Commit**

```bash
git add ccodex.cmd install.ps1
git commit -m "feat: add ccodex install script and PATH shim"
```

---

## Self-Review

**Spec coverage against the Phase 1 verification checklist:**

| Spec Phase 1 verification item | Covered by |
|---|---|
| Callable from `PATH` in ≥2 project dirs without copying the wrapper | Task 12, Steps 3–4 |
| Long multiline prompt via PowerShell pipeline stdin | Task 4 (pipeline join test) |
| OS-level redirected stdin preserves Traditional Chinese exactly | Task 5 (Chinese-text test) + Task 12 Step 5 |
| Explicit source present → never probes OS stdin; inert pipe must not hang | Task 4 ("must not touch stdin stream" test) |
| OS-level stdin enforces 2s/5s timeouts | Task 5 (first-byte + no-progress timeout tests) |
| Timed-out stdin exits 2 with a hint | Task 5 (`Assert-Throws` on both timeout cases) + Task 11 wiring returns 2 |
| Empty stdin/pipeline rejected unless exactly one non-stdin source given | Task 4 (empty pipeline test) |
| `codex exec` receives task, returns a clean response | Task 12 Step 4 (real CLI) |
| `--output-last-message` captured | Task 9 (fixture writes `result.md`) + Task 11 |
| Raw JSONL never printed to Claude | Task 11 (`Stdout` only ever set from `ResultContent`, never from events) |
| Only `result.md` printed on success | Task 11 test assertion `-not ($result.Stdout -like '*fake-codex ran*')` |
| All 9 job files written | Task 11 file-existence loop |
| `worker-complete.json` on success and failure | Task 11 (both success and codex-exit-3 scenarios) |
| review/brainstorm use `--sandbox read-only` | Task 7 (`Build-CcodexCodexArgs` test) |
| `test` without `--access workspace` fails first | Task 7 + Task 11 |
| `test --access workspace` creates `artifacts/` and injects it into the prompt | Task 11 |
| Jobs under global state root, not the repo | Task 11 ("no `.ccodex/jobs` in repo" test) |
| Project-local template override; no `.gitignore`/source mutation | Task 6 (precedence test) + Task 11 (repo untouched) |
| Wrapper exit codes vs `codex_exit_code` stored separately | Task 10 + Task 11 status.json assertions |
| No heartbeat/health/lock/debug/tail/background/tmux | Not implemented anywhere in this plan (by omission, matching the constraint) |

**Placeholder scan:** no `TBD`/`TODO`/"add appropriate error handling" phrases were used; every step includes literal, runnable code. Task 11 Step 4 explicitly names the two exploratory lines to delete rather than leaving vague cleanup language, and gives the corrected line that replaces them.

**Type/signature consistency check:** `Get-CcodexPromptContent`'s full parameter list is introduced across Tasks 4–5 without changing shape once fixed (Task 4 defines it including the stdin parameters up front, so Task 5 only adds the function body it calls, `Read-CcodexStdinWithTimeout`, without touching call sites). `Invoke-CcodexCodexProcess`'s signature declared in Task 9 exactly matches its call site in Task 11 (`CodexPath, Arguments, PromptContent, EventsLogPath, StderrLogPath, ExitCodeFilePath`). `New-CcodexStatusObject` / `New-CcodexWorkerCompleteObject` / `New-CcodexDebugObject` signatures from Task 8 are used identically in Task 11. `Resolve-CcodexAccess` (Task 7) and `Test-CcodexResult` (Task 10) signatures match their Task 11 call sites.

**Known deliberate scope boundary:** this plan implements only `run`. `submit`, `status`, `wait`, `read`, `tail`, `debug`, `cancel`, `doctor`, background backends, locks, and worktree isolation are explicitly out of scope per the user's choice to plan Phase 1 only — they need their own follow-up plans once this one is verified working end-to-end.
