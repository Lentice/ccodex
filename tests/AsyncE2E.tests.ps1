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

function New-CcodexAsyncResumeParent {
    param([string]$ThreadId = 'thread-async-parent')
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode 'brainstorm' -Root $localAppData
    $indexPath = Get-CcodexIndexPath -JobId $reservation.JobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $reservation.JobId; repo_key = $repoKey; job_dir = $reservation.JobDir })
    Write-CcodexJsonFileAtomic -Path (Join-Path $reservation.JobDir 'status.json') -Object (New-CcodexStatusObject -JobId $reservation.JobId -Status 'done' -Mode 'brainstorm' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'sync' -CodexThreadId $ThreadId -Group 'async-group' -Label 'async-label')
    return [pscustomobject]@{ JobId = $reservation.JobId; JobDir = $reservation.JobDir }
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
    # (a2) async follow-up: submit --resume -> wait -> read, with lineage in JSON status.
    # ============================================================

    Write-Host "shim: submit --resume -> wait/read preserves exact submit stdout and lineage"
    $resumeParent = New-CcodexAsyncResumeParent
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'ASYNC FOLLOW-UP RESULT'
    $submitResume = Invoke-CcodexShim -Arguments @('submit', 'continue this thread', '--resume', $resumeParent.JobId, '--model', 'gpt-5-codex', '--effort', 'high', '--state-root', $localAppData, '--detach-mechanism', 'startprocess')
    Assert-Equal $submitResume.ExitCode 0 'submit --resume exits 0 after detached launch'
    Assert-Equal $submitResume.Lines.Count 2 'submit --resume stdout is exactly child id plus child dir'
    Assert-Equal @($submitResume.Stdout -split "`n").Count 2 'submit --resume raw stdout remains exactly two lines'
    $resumeChildId = $submitResume.Lines[0]
    $resumeChildDir = $submitResume.Lines[1]
    Assert-True ($resumeChildId -ne $resumeParent.JobId) 'submit --resume creates a distinct child job id'
    $waitResume = Invoke-CcodexShim -Arguments @('wait', $resumeChildId, '--state-root', $localAppData)
    Assert-Equal $waitResume.ExitCode 0 'wait on async follow-up exits 0'
    Assert-Equal $waitResume.Stdout 'ASYNC FOLLOW-UP RESULT' 'wait prints async follow-up result only'
    $readResume = Invoke-CcodexShim -Arguments @('read', $resumeChildId, '--state-root', $localAppData)
    Assert-Equal $readResume.ExitCode 0 'read on async follow-up exits 0'
    Assert-Equal $readResume.Stdout 'ASYNC FOLLOW-UP RESULT' 'read prints the same async follow-up result'
    $statusResumeJson = Invoke-CcodexShim -Arguments @('status', $resumeChildId, '--json', '--state-root', $localAppData)
    Assert-Equal $statusResumeJson.ExitCode 0 'status --json on async follow-up exits 0'
    $resumeEnvelope = $statusResumeJson.Stdout | ConvertFrom-Json
    Assert-Equal $resumeEnvelope.parent_job_id $resumeParent.JobId 'status --json envelope exposes async parent_job_id'
    $resumeChildStatus = Read-CcodexStatusFile -JobDir $resumeChildDir
    Assert-Equal $resumeChildStatus.codex_thread_id 'thread-async-parent' 'async follow-up remains resumable using the inherited thread id fallback'
    Assert-Equal $resumeChildStatus.group 'async-group' 'async follow-up preserves inherited group through terminal status'
    Assert-Equal $resumeChildStatus.label 'async-label' 'async follow-up preserves inherited label through terminal status'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $resumeChildDir 'prompt.md'))) 'continue this thread' 'submit --resume accepts positional follow-up text like plain submit'
    $resumeCommand = Get-Content -LiteralPath (Join-Path $resumeChildDir 'command.txt') -Raw
    Assert-True ($resumeCommand -like '*-m gpt-5-codex -c model_reasoning_effort=high resume thread-async-parent -*') 'submit --resume accepts model/effort and the worker preserves resume argv ordering'
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

    Write-Host "shim: submit --resume Codex session-not-found failure -> wait 10, thread_expired"
    $expiredParent = New-CcodexAsyncResumeParent -ThreadId 'thread-expired-parent'
    $env:CCODEX_FAKE_EXIT_CODE = '1'
    $env:CCODEX_FAKE_STDERR = 'session not found'
    $submitExpired = Invoke-CcodexShim -Arguments @('submit', '--resume', $expiredParent.JobId, '--state-root', $localAppData, '--detach-mechanism', 'startprocess') -StdinText 'continue expired thread'
    Assert-Equal $submitExpired.ExitCode 0 'thread-expired async submit still exits 0 after launch'
    $waitExpired = Invoke-CcodexShim -Arguments @('wait', $submitExpired.Lines[0], '--state-root', $localAppData)
    Assert-Equal $waitExpired.ExitCode 10 'wait on thread-expired async follow-up exits 10'
    $expiredStatus = Read-CcodexStatusFile -JobDir $submitExpired.Lines[1]
    Assert-Equal $expiredStatus.failure_reason 'thread_expired' 'async resumed worker classifies session-not-found as thread_expired'
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_STDERR -ErrorAction SilentlyContinue

    # ============================================================
    # (c) still-sleeping job: read -> 4, timed wait -> 20 (lifecycle unchanged), then a
    # no-timeout wait -> 0 once the fixture delay elapses.
    # ============================================================

    Write-Host "shim: still-sleeping job -> read exits 4, wait --wait-timeout-sec 1 exits 20, final wait exits 0"
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'SLOW E2E RESULT'
    # The job must still be running when the 1s wait-timeout fires, i.e. the fixture sleep has
    # to outlive TWO intermediate shim spawns (read + wait) plus the timeout itself. pwsh
    # cold-starts reached 3-7s each on a loaded desktop (2026-07-13) and flaked this at 4000ms,
    # so the sleep is generous — the final no-timeout wait below absorbs whatever remains of it.
    $env:CCODEX_FAKE_DELAY_MS = '20000'

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

    # ============================================================
    # (g) quota/rate-limit stderr signature + exit 1 -> wait exits 10, status.json
    # carries failure_reason "quota_or_rate_limit" (Failure-mode handling amendment).
    # ============================================================

    Write-Host "shim: quota/rate-limit stderr signature + exit 1 -> wait exits 10, failure_reason quota_or_rate_limit"
    $env:CCODEX_FAKE_EXIT_CODE = '1'
    $env:CCODEX_FAKE_STDERR = 'Rate limit exceeded (429)'
    Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

    $submitQuota = Invoke-CcodexShim -Arguments @('submit', '--mode', 'review', '--repo', $targetRepo, '--state-root', $localAppData, '--detach-mechanism', 'startprocess') -StdinText 'trigger a quota failure'
    Assert-Equal $submitQuota.ExitCode 0 'quota-failure submit still exits 0 (submit only reserves/launches)'
    $jobIdQuota = $submitQuota.Lines[0]

    $pollQuota = Wait-CcodexShimStatus -JobId $jobIdQuota -TimeoutSec 20
    Assert-Equal $pollQuota.Seen[$pollQuota.Seen.Count - 1] 'failed' 'status polling through the shim eventually reports failed'

    $waitQuota = Invoke-CcodexShim -Arguments @('wait', $jobIdQuota, '--state-root', $localAppData)
    Assert-Equal $waitQuota.ExitCode 10 'wait on the quota-failed job exits 10'

    $jobDirQuota = Get-CcodexJobDir -RepoKey (Get-CcodexRepoKey -RepoRoot $targetRepo) -JobId $jobIdQuota -Root $localAppData
    $statusQuota = Read-CcodexStatusFile -JobDir $jobDirQuota
    Assert-Equal $statusQuota.failure_reason 'quota_or_rate_limit' 'status.json carries failure_reason quota_or_rate_limit'

    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_STDERR -ErrorAction SilentlyContinue

    # ============================================================
    # (h) --hard-timeout-sec 1 against a sleeping fixture -> worker marks timed_out,
    # wait exits 24, the codex child process is dead, artifacts are preserved.
    # ============================================================

    Write-Host "shim: --hard-timeout-sec 1 -> worker marks timed_out, wait exits 24, codex child killed, artifacts preserved"
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_DELAY_MS = '8000'
    Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
    $timeoutPidFile = Join-Path $tempRoot 'timeout-fake.pid'
    $env:CCODEX_FAKE_PIDFILE = $timeoutPidFile

    $submitTimeout = Invoke-CcodexShim -Arguments @('submit', '--mode', 'review', '--repo', $targetRepo, '--state-root', $localAppData, '--detach-mechanism', 'startprocess', '--hard-timeout-sec', '1') -StdinText 'trigger a hard timeout'
    Assert-Equal $submitTimeout.ExitCode 0 'hard-timeout submit exits 0'
    $jobIdTimeout = $submitTimeout.Lines[0]
    $jobDirTimeout = Get-CcodexJobDir -RepoKey (Get-CcodexRepoKey -RepoRoot $targetRepo) -JobId $jobIdTimeout -Root $localAppData

    $timeoutDeadline = (Get-Date).AddSeconds(20)
    $statusTimeout = $null
    while ((Get-Date) -lt $timeoutDeadline) {
        $statusTimeout = Read-CcodexStatusFile -JobDir $jobDirTimeout
        if ($statusTimeout.status -eq 'timed_out') { break }
        Start-Sleep -Milliseconds 250
    }
    Assert-Equal $statusTimeout.status 'timed_out' 'the worker eventually marks the job timed_out'
    Assert-True ($null -ne $statusTimeout.timeout_reason) 'status.json carries a timeout_reason'
    Assert-True ($null -ne $statusTimeout.terminated_at) 'status.json carries a terminated_at'
    Assert-True ($null -eq $statusTimeout.codex_exit_code) 'codex_exit_code stays null on a hard timeout'

    $waitTimeout = Invoke-CcodexShim -Arguments @('wait', $jobIdTimeout, '--state-root', $localAppData)
    Assert-Equal $waitTimeout.ExitCode 24 'wait on the timed_out job exits 24'

    Assert-True (Test-Path -LiteralPath $timeoutPidFile -PathType Leaf) 'the fixture recorded its pid before the hard timeout killed it'
    $timeoutChildPid = [int]((Get-Content -LiteralPath $timeoutPidFile -Raw).Trim())
    $timeoutAliveDeadline = (Get-Date).AddSeconds(5)
    $timeoutAlive = $true
    while ((Get-Date) -lt $timeoutAliveDeadline) {
        if (-not (Get-Process -Id $timeoutChildPid -ErrorAction SilentlyContinue)) { $timeoutAlive = $false; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-True (-not $timeoutAlive) 'the fake-codex child process is dead after the hard timeout'

    foreach ($artifact in @('prompt.md', 'codex-events.jsonl', 'status.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $jobDirTimeout $artifact) -PathType Leaf) "artifact $artifact is preserved after a hard timeout"
    }

    Remove-Item Env:\CCODEX_FAKE_DELAY_MS, Env:\CCODEX_FAKE_PIDFILE -ErrorAction SilentlyContinue

    # ============================================================
    # (i) shim-level `run` with an auth-signature stderr + exit 1 -> failure message
    # contains the `codex login` hint (run has no --state-root flag, so LOCALAPPDATA
    # is overridden directly, matching RealInvocation.tests.ps1's pattern for `run`).
    # ============================================================

    Write-Host "shim: run with an auth-signature stderr + exit 1 -> exit 10, failure message hints codex login"
    $savedLocalAppDataForRun = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $localAppData
    $env:CCODEX_FAKE_EXIT_CODE = '1'
    $env:CCODEX_FAKE_STDERR = 'Authentication failed (401): please run codex login'
    Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
    try {
        $runAuth = Invoke-CcodexShim -Arguments @('run', '--mode', 'review', '--repo', $targetRepo) -StdinText 'trigger an auth failure'
        Assert-Equal $runAuth.ExitCode 10 'run against an auth-signature failure exits 10'
        Assert-True ($runAuth.Stdout -like '*codex login*') 'the failure message printed by run contains the codex login hint'
    } finally {
        $env:LOCALAPPDATA = $savedLocalAppDataForRun
    }
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_STDERR -ErrorAction SilentlyContinue
} finally {
    $env:PATH = $savedPath
    $env:APPDATA = $savedAppData
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_RESULT = $savedResult
    $env:CCODEX_FAKE_DELAY_MS = $savedDelay
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

Complete-CcodexTests
