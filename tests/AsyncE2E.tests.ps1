# tests/AsyncE2E.tests.ps1
#
# End-to-end regression for the async result channel (submit/status/wait/read) at the
# same shim level RealInvocation.tests.ps1 uses for `run`: a temp bin directory stages a
# fake `codex.cmd` (fake-codex fixture) ALONGSIDE a decoy `codex.ps1` (npm-shaped PATH,
# per the codex-resolution defect RealInvocation guards), plus a `ccodex.cmd` shim that
# mirrors the installed PATH shim exactly and invokes this repo's ccodex.ps1. Every
# assertion below goes through that shim (`& $ccodexCmd submit|status|wait|read ...`)
# with `--state-root` (temp, never the real LOCALAPPDATA) and `--detach-mechanism
# startprocess` (env inherits under startprocess, matching the fixture's env-var
# contract; production defaults to `cim`, exercised elsewhere in Detach.tests.ps1).
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
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fakePs = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-asynce2e-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$binDir = Join-Path $tempRoot 'bin'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $binDir, $targetRepo, (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$exitLine = 'exit /' + 'b %ERRORLEVEL%'  # split literal to keep it plain text
# codex.cmd on PATH resolves to the fake-codex fixture.
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), "@echo off`r`npwsh -NoProfile -File `"$fakePs`" %*`r`n$exitLine", $utf8NoBom)
# npm-shaped PATH collision guard (mirrors RealInvocation.tests.ps1): a decoy codex.ps1
# ranks ABOVE codex.cmd in PowerShell command precedence. This body deliberately exits
# nonzero WITHOUT writing result.md, so if the async path (submit -> worker -> codex
# resolution) ever resolves to it instead of codex.cmd, the terminal-status/result
# assertions below break loudly instead of silently.
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.ps1'), "param() Write-Error 'ccodex resolved codex.ps1 instead of codex.cmd'; exit 3`r`n", $utf8NoBom)
# ccodex.cmd shim mirrors the installed PATH shim exactly.
[System.IO.File]::WriteAllText((Join-Path $binDir 'ccodex.cmd'), "@echo off`r`nsetlocal`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ccodexPs`" %*`r`n$exitLine", $utf8NoBom)
$ccodexCmd = Join-Path $binDir 'ccodex.cmd'

function Invoke-CcodexShim {
    # Invokes the staged ccodex.cmd shim exactly like a real PATH lookup would, capturing
    # stdout lines and exit code together. Piping $StdinText (when given) exercises the
    # same OS-level redirected-stdin path RealInvocation.tests.ps1 exercises for `run`.
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$StdinText = $null)
    if ($null -ne $StdinText) {
        $out = $StdinText | & $ccodexCmd @Arguments
    } else {
        $out = & $ccodexCmd @Arguments
    }
    $exit = $LASTEXITCODE
    $allText = ($out -join "`n")
    $nonEmptyLines = @($out | Where-Object { $_ -ne $null -and $_ -ne '' })
    return [pscustomobject]@{ ExitCode = $exit; Stdout = $allText; Lines = $nonEmptyLines }
}

function Wait-CcodexShimStatus {
    # Polls `ccodex status <id>` THROUGH THE SHIM (not a direct status.json read) until
    # a terminal word appears in the printed line, or the timeout elapses. Returns the
    # sequence of distinct status words observed along the way, so callers can assert the
    # created/running -> done transition was actually witnessed through the real command.
    param([Parameter(Mandatory)][string]$JobId, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $seen = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $result = Invoke-CcodexShim -Arguments @('status', $JobId, '--state-root', $localAppData)
        $word = if ($result.Lines.Count -gt 0) { ($result.Lines[0] -split ' ')[1] } else { $null }
        if ($word -and ($seen.Count -eq 0 -or $seen[$seen.Count - 1] -ne $word)) { $seen.Add($word) }
        if ($word -in @('done', 'failed')) { return [pscustomobject]@{ Seen = $seen; Final = $result } }
        if ((Get-Date) -ge $deadline) { return [pscustomobject]@{ Seen = $seen; Final = $result } }
        Start-Sleep -Milliseconds 250
    }
}

$savedPath = $env:PATH
$savedAppData = $env:APPDATA
$savedExit = $env:CCODEX_FAKE_EXIT_CODE
$savedResult = $env:CCODEX_FAKE_RESULT
$savedDelay = $env:CCODEX_FAKE_DELAY_MS
try {
    $env:PATH = "$binDir;$env:PATH"
    $env:APPDATA = $appData

    # ============================================================
    # (a) + (b) + (g): piped multiline prompt -> submit via the shim, then the job
    # runs to completion in the background after the submitting invocation returns.
    # ============================================================

    Write-Host "shim: piped multiline prompt via submit -> exit 0, exactly two stdout lines, no JSONL, no result content"
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'ASYNC E2E RESULT'
    $multilineTask = "Line one of the task.`nLine two of the task.`nLine three: summarize the above in one sentence."

    $submitResult = Invoke-CcodexShim -Arguments @('submit', '--mode', 'review', '--repo', $targetRepo, '--state-root', $localAppData, '--detach-mechanism', 'startprocess') -StdinText $multilineTask
    Assert-Equal $submitResult.ExitCode 0 'piped multiline submit exits 0'
    Assert-Equal $submitResult.Lines.Count 2 'submit stdout is exactly two lines'
    # Dogfood #3 (triaged false positive): -WindowStyle Hidden isolates the detached
    # worker's own stdout/stderr in a separate hidden console, so it can never interleave
    # with submit's stdout. Assert the RAW stdout (not just the non-empty-filtered Lines)
    # is exactly those two lines with nothing else mixed in.
    $submitRawLines = $submitResult.Stdout -split "`n"
    Assert-Equal $submitRawLines.Count 2 'submit raw stdout is exactly two lines, no interleaved worker output'
    Assert-True ($submitResult.Lines[0] -match '^\d{8}T\d{6}Z-[a-z0-9]{8}-review$') 'first line is a Phase-1-shaped job id'
    Assert-True (Test-Path -LiteralPath $submitResult.Lines[1] -PathType Container) 'second line is an existing job dir'
    Assert-True (-not ($submitResult.Stdout -like '*fake-codex ran*')) 'submit stdout never carries raw JSONL'
    Assert-True (-not ($submitResult.Stdout -like '*ASYNC E2E RESULT*')) 'submit stdout never carries result content'
    Assert-True (-not ($submitResult.Stdout -like '*codex.ps1 instead*')) 'submit never resolved the shadowing codex.ps1'

    $jobIdAB = $submitResult.Lines[0]
    $jobDirAB = $submitResult.Lines[1]

    $promptTextAB = [System.IO.File]::ReadAllText((Join-Path $jobDirAB 'prompt.md'), $utf8NoBom)
    Assert-True ($promptTextAB.Contains($multilineTask)) 'prompt.md carries the multiline piped text byte-exact'

    Write-Host "shim: status polling observes running/created -> done, then wait and read agree on the fixture result"
    $poll = Wait-CcodexShimStatus -JobId $jobIdAB -TimeoutSec 20
    Assert-True ($poll.Seen.Count -gt 0) 'at least one status word was observed through the shim'
    Assert-Equal $poll.Seen[$poll.Seen.Count - 1] 'done' 'status polling through the shim eventually reports done'
    Assert-True ($poll.Seen[0] -in @('created', 'running', 'done')) 'first observed status word is a legitimate lifecycle state'
    Assert-Equal $poll.Final.ExitCode 0 'final polled status invocation exits 0'
    Assert-True (-not ($poll.Final.Stdout -like '*fake-codex ran*')) 'status stdout never carries raw JSONL'

    $waitResult = Invoke-CcodexShim -Arguments @('wait', $jobIdAB, '--state-root', $localAppData)
    Assert-Equal $waitResult.ExitCode 0 'wait on the now-done job exits 0'
    Assert-Equal $waitResult.Stdout 'ASYNC E2E RESULT' 'wait prints the fixture result content on stdout'
    Assert-True (-not ($waitResult.Stdout -like '*fake-codex ran*')) 'wait stdout never carries raw JSONL'

    $readResultAB = Invoke-CcodexShim -Arguments @('read', $jobIdAB, '--state-root', $localAppData)
    Assert-Equal $readResultAB.ExitCode 0 'read on the done job exits 0'
    Assert-Equal $readResultAB.Stdout 'ASYNC E2E RESULT' 'read prints the same fixture result content as wait'
    Assert-True (-not ($readResultAB.Stdout -like '*fake-codex ran*')) 'read stdout never carries raw JSONL'

    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

    # ============================================================
    # (c) still-sleeping job: read -> 4, timed wait -> 20 (lifecycle unchanged), then a
    # no-timeout wait -> 0 once the fixture delay elapses.
    # ============================================================

    Write-Host "shim: still-sleeping job -> read exits 4, wait --wait-timeout-sec 1 exits 20, final wait exits 0"
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'SLOW E2E RESULT'
    $env:CCODEX_FAKE_DELAY_MS = '4000'

    $submitSlow = Invoke-CcodexShim -Arguments @('submit', '--mode', 'review', '--repo', $targetRepo, '--state-root', $localAppData, '--detach-mechanism', 'startprocess') -StdinText 'slow task, please wait'
    Assert-Equal $submitSlow.ExitCode 0 'slow-job submit exits 0'
    Assert-Equal $submitSlow.Lines.Count 2 'slow-job submit stdout is exactly two lines'
    $jobIdSlow = $submitSlow.Lines[0]

    $readSlow = Invoke-CcodexShim -Arguments @('read', $jobIdSlow, '--state-root', $localAppData)
    Assert-Equal $readSlow.ExitCode 4 'read against a still-sleeping job exits 4'
    Assert-True (-not ($readSlow.Stdout -like '*SLOW E2E RESULT*')) 'read against a still-sleeping job prints no result content'

    $waitTimeoutSlow = Invoke-CcodexShim -Arguments @('wait', $jobIdSlow, '--wait-timeout-sec', '1', '--state-root', $localAppData)
    Assert-Equal $waitTimeoutSlow.ExitCode 20 'wait --wait-timeout-sec 1 on a still-sleeping job exits 20'
    $jobDirSlow = Get-CcodexJobDir -RepoKey (Get-CcodexRepoKey -RepoRoot $targetRepo) -JobId $jobIdSlow -Root $localAppData
    $statusAfterTimeout = Read-CcodexStatusFile -JobDir $jobDirSlow
    Assert-True ($statusAfterTimeout.status -notin @('done', 'failed')) 'wait timeout leaves the job non-terminal (lifecycle unchanged)'

    $waitFinalSlow = Invoke-CcodexShim -Arguments @('wait', $jobIdSlow, '--state-root', $localAppData)
    Assert-Equal $waitFinalSlow.ExitCode 0 'a final no-timeout wait exits 0 once the fixture delay elapses'
    Assert-Equal $waitFinalSlow.Stdout 'SLOW E2E RESULT' 'the final wait returns the fixture result content'

    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue

    # ============================================================
    # (d) bogus job id -> status/wait/read all exit 3
    # ============================================================

    Write-Host "shim: status/wait/read against a bogus job id all exit 3"
    $bogusId = 'does-not-exist-99999'
    $statusBogus = Invoke-CcodexShim -Arguments @('status', $bogusId, '--state-root', $localAppData)
    Assert-Equal $statusBogus.ExitCode 3 'status on a bogus job id exits 3'
    $waitBogus = Invoke-CcodexShim -Arguments @('wait', $bogusId, '--state-root', $localAppData)
    Assert-Equal $waitBogus.ExitCode 3 'wait on a bogus job id exits 3'
    $readBogus = Invoke-CcodexShim -Arguments @('read', $bogusId, '--state-root', $localAppData)
    Assert-Equal $readBogus.ExitCode 3 'read on a bogus job id exits 3'

    # ============================================================
    # (e) submit with --mode test and no --access -> exit 2, no worker/process launched
    # ============================================================

    Write-Host "shim: submit --mode test without --access exits 2, no worker is ever launched"
    $submitNoAccess = Invoke-CcodexShim -Arguments @('submit', '--mode', 'test', '--repo', $targetRepo, '--state-root', $localAppData, '--detach-mechanism', 'startprocess') -StdinText 'a test-mode task'
    Assert-Equal $submitNoAccess.ExitCode 2 'submit --mode test without --access exits 2'

    # No two-line job id/job dir success shape was printed, but the job dir was still
    # reserved (access failure happens post-reservation) -- recover it from the index
    # rather than the (failure-shaped) stdout.
    $jobsRootE = Join-Path (Get-CcodexLocalAppDataRoot -Root $localAppData) 'jobs'
    $repoKeyE = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservedDirsE = Get-ChildItem -Path (Join-Path $jobsRootE $repoKeyE) -Directory | Where-Object { $_.Name -like '*-test' }
    Assert-True ($reservedDirsE.Count -ge 1) 'a job dir was reserved for the failed test-mode submit'
    $jobDirE = $reservedDirsE[0].FullName
    $statusE = Get-Content -LiteralPath (Join-Path $jobDirE 'status.json') -Raw | ConvertFrom-Json
    Assert-Equal $statusE.status 'failed' 'the test-mode job stays terminal failed, never running'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobDirE 'worker-complete.json'))) 'no worker-complete.json was ever written (no worker ran)'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobDirE 'codex-events.jsonl'))) 'no codex-events.jsonl was ever written (codex was never invoked)'

    # ============================================================
    # (f) all job state landed under the temp state root; the target repo is untouched
    # ============================================================

    Write-Host "shim: all job state lives under the temp state root, the target repo gained no .ccodex"
    foreach ($dir in @($jobDirAB, $jobDirE)) {
        Assert-True ($dir.StartsWith($localAppData, [System.StringComparison]::OrdinalIgnoreCase)) 'job dir is rooted under the temp state root, not the real profile'
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $targetRepo '.ccodex'))) 'the target repo gained no .ccodex directory'
    $repoContents = Get-ChildItem -Path $targetRepo -Force
    Assert-Equal $repoContents.Count 0 'the target repo directory remains empty end-to-end'
} finally {
    $env:PATH = $savedPath
    $env:APPDATA = $savedAppData
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_RESULT = $savedResult
    $env:CCODEX_FAKE_DELAY_MS = $savedDelay
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

Complete-CcodexTests
