# tests/CancelCommand.tests.ps1
#
# Invoke-CcodexCancelCommand (design: "cancel <job_id>", Phase 2b Task 4) plus the
# `cancelled` mappings it activates in wait/read/status. Follows the same
# dot-source-ccodex.ps1-with-ImportOnly pattern StatusWaitRead.tests.ps1/SubmitCommand.tests.ps1
# use so the real dispatcher functions (and everything they route through: the per-job
# lock, orphan reconciliation, Stop-CcodexProcessTree) are exercised directly.
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
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')
. (Join-Path $PSScriptRoot '..\lib\Detach.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-cancelcommand-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $targetRepo -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$fabricatedDeadBackendId = '999999;2020-01-01T00:00:00.0000000Z'
$currentProc = Get-Process -Id $PID
$aliveBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime $currentProc.StartTime

function New-CcodexTestJobWithStatus {
    # Seeds a job dir via the real reservation/index path so Get-CcodexJobRecord (which
    # Invoke-CcodexCancelCommand calls first) finds it, then overwrites status.json with
    # the given shape so every cancel branch can be exercised deterministically.
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$Status = 'created',
        [string]$BackendId = $null,
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [switch]$WithExitCodeEvidence,
        [int]$EvidenceExitCode = 0,
        [switch]$WithResultFile
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content 'test worker prompt body'
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status $Status -Mode $Mode -Access $Access -Repo $targetRepo -CreatedAt $createdAt -BackendId $BackendId -CodexExitCode $CodexExitCode -WrapperExitCode $WrapperExitCode
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    if ($WithExitCodeEvidence) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'exit_code.txt') -Content "$EvidenceExitCode"
    }
    if ($WithResultFile) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'result.md') -Content 'the result'
    }
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

function Wait-CcodexTestRunningStatus {
    # Polls status.json until the (native-backend) worker has stamped `running` with a
    # non-empty backend_id, or the timeout elapses.
    param([Parameter(Mandatory)][string]$JobDir, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $status = Read-CcodexStatusFile -JobDir $JobDir
        if ($status -and $status.status -eq 'running' -and $status.backend_id) { return $status }
        if ((Get-Date) -ge $deadline) { return $status }
        Start-Sleep -Milliseconds 200
    }
}

# ============================================================
# (a) unknown job id -> exit 3
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: unknown job id -> exit 3"
$resultUnknown = Invoke-CcodexCancelCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultUnknown.Message)) 'unknown job id returns a diagnostic message'

# ============================================================
# (b) already-terminal job -> no-op message, exit 0, status.json unchanged
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: already-done job -> no-op 'already done', exit 0, status unchanged"
$jobDone = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$beforeDone = (Get-Item (Join-Path $jobDone.JobDir 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDone = Invoke-CcodexCancelCommand -JobId $jobDone.JobId -StateRoot $localAppData
Assert-Equal $resultDone.WrapperExitCode 0 'cancelling an already-done job exits 0'
Assert-Equal $resultDone.Stdout "$($jobDone.JobId) already done" 'no-op message names the existing terminal status'
$afterDone = (Get-Item (Join-Path $jobDone.JobDir 'status.json')).LastWriteTimeUtc
Assert-Equal $afterDone $beforeDone 'status.json was not rewritten for an already-terminal job'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobDone.JobDir '.lock'))) 'the per-job lock is released after the no-op'

Write-Host "Invoke-CcodexCancelCommand: already-cancelled job -> no-op 'already cancelled', exit 0"
$jobAlreadyCancelled = New-CcodexTestJobWithStatus -Status 'cancelled'
$resultAlreadyCancelled = Invoke-CcodexCancelCommand -JobId $jobAlreadyCancelled.JobId -StateRoot $localAppData
Assert-Equal $resultAlreadyCancelled.WrapperExitCode 0 'cancelling an already-cancelled job exits 0'
Assert-Equal $resultAlreadyCancelled.Stdout "$($jobAlreadyCancelled.JobId) already cancelled" 'no-op message names cancelled'

# ============================================================
# (c) never-started ('created') job -> marked cancelled directly
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: 'created' (never started) job -> marked cancelled directly, exit 0"
$jobCreated = New-CcodexTestJobWithStatus -Status 'created'
$resultCreated = Invoke-CcodexCancelCommand -JobId $jobCreated.JobId -StateRoot $localAppData
Assert-Equal $resultCreated.WrapperExitCode 0 'cancelling a never-started job exits 0'
Assert-Equal $resultCreated.Stdout "$($jobCreated.JobId) cancelled" 'confirmation line names cancelled'
$statusCreatedAfter = Get-Content -LiteralPath (Join-Path $jobCreated.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusCreatedAfter.status 'cancelled' 'status.json status becomes cancelled'
Assert-True ($null -ne $statusCreatedAfter.cancelled_at -and $statusCreatedAfter.cancelled_at -ne '') 'status.json carries a cancelled_at timestamp'
Assert-Equal $statusCreatedAfter.job_id $jobCreated.JobId 'cancelled status.json preserves job_id (append-only fields)'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobCreated.JobDir '.lock'))) 'the per-job lock is released after marking cancelled'

# ============================================================
# (d) running + worker dead + completion evidence -> reconciled (done/failed), NOT cancelled
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: running + dead worker + success evidence -> reconciled to done, not cancelled"
$jobDeadDone = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
$resultDeadDone = Invoke-CcodexCancelCommand -JobId $jobDeadDone.JobId -StateRoot $localAppData
Assert-Equal $resultDeadDone.WrapperExitCode 0 'cancel against a dead-with-evidence job exits 0'
Assert-Equal $resultDeadDone.Stdout "$($jobDeadDone.JobId) done" 'cancel reports the reconciled done status, not cancelled'
$statusDeadDoneAfter = Get-Content -LiteralPath (Join-Path $jobDeadDone.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDeadDoneAfter.status 'done' 'status.json is reconciled to done, never forced to cancelled'
Assert-True ([string]::IsNullOrEmpty($statusDeadDoneAfter.cancelled_at)) 'reconciled-to-done status.json carries no cancelled_at'

Write-Host "Invoke-CcodexCancelCommand: running + dead worker + failure evidence -> reconciled to failed, not cancelled"
$jobDeadFailed = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 1
$resultDeadFailed = Invoke-CcodexCancelCommand -JobId $jobDeadFailed.JobId -StateRoot $localAppData
Assert-Equal $resultDeadFailed.WrapperExitCode 0 'cancel against a dead-with-failure-evidence job exits 0'
Assert-Equal $resultDeadFailed.Stdout "$($jobDeadFailed.JobId) failed" 'cancel reports the reconciled failed status, not cancelled'
$statusDeadFailedAfter = Get-Content -LiteralPath (Join-Path $jobDeadFailed.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDeadFailedAfter.status 'failed' 'status.json is reconciled to failed, never forced to cancelled'

Write-Host "Invoke-CcodexCancelCommand: running + dead worker + no evidence -> stays running, reported possibly-stale, not cancelled"
$jobDeadNoEvidence = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId
$resultDeadNoEvidence = Invoke-CcodexCancelCommand -JobId $jobDeadNoEvidence.JobId -StateRoot $localAppData
Assert-Equal $resultDeadNoEvidence.WrapperExitCode 0 'cancel against a dead-worker-no-evidence job exits 0'
Assert-Equal $resultDeadNoEvidence.Stdout "$($jobDeadNoEvidence.JobId) running" 'cancel reports the still-running (unreconciled) status, not cancelled'
$statusDeadNoEvidenceAfter = Get-Content -LiteralPath (Join-Path $jobDeadNoEvidence.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDeadNoEvidenceAfter.status 'running' 'status.json is left running when there is no completion evidence to reconcile from'

# ============================================================
# (e) live fake worker mid-CCODEX_FAKE_DELAY_MS sleep -> killed, cancelled, artifacts preserved
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: cancel a live fake worker mid-sleep -> process tree dead, cancelled+cancelled_at, artifacts preserved"
$savedDelay = $env:CCODEX_FAKE_DELAY_MS
$savedExit = $env:CCODEX_FAKE_EXIT_CODE
$savedPidFile = $env:CCODEX_FAKE_PIDFILE
$cancelPidFile = Join-Path $tempRoot 'cancel-fake.pid'
try {
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_DELAY_MS = '8000'
    $env:CCODEX_FAKE_PIDFILE = $cancelPidFile

    $submitLive = Invoke-CcodexSubmit -Mode 'review' -Access $null -RepoOverride $targetRepo -PromptFile $null `
        -PositionalTask 'a task to cancel mid-flight' -PipelineExpected $false -PipelineObjects $null `
        -DetachMechanism 'startprocess' -CodexPath $fixtureCmd -LocalAppDataRoot $localAppData -AppDataRoot $appData
    Assert-Equal $submitLive.WrapperExitCode 0 'live-cancel job submits successfully'

    $runningStatus = Wait-CcodexTestRunningStatus -JobDir $submitLive.JobDir -TimeoutSec 20
    Assert-True ($runningStatus -ne $null -and $runningStatus.status -eq 'running') 'the submitted job reaches running with a backend_id before cancel'
    Assert-True (Test-CcodexWorkerAlive -BackendId $runningStatus.backend_id) 'the worker backend is alive right before cancel'

    $fakePidDeadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $cancelPidFile -PathType Leaf) -and (Get-Date) -lt $fakePidDeadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $cancelPidFile -PathType Leaf) 'the fake-codex child recorded its own pid before cancel'
    $fakeChildPid = [int]((Get-Content -LiteralPath $cancelPidFile -Raw).Trim())
    Assert-True ($null -ne (Get-Process -Id $fakeChildPid -ErrorAction SilentlyContinue)) 'the fake-codex child process is alive before cancel'

    $resultLive = Invoke-CcodexCancelCommand -JobId $submitLive.JobId -StateRoot $localAppData
    Assert-Equal $resultLive.WrapperExitCode 0 'cancelling a live worker exits 0'
    Assert-Equal $resultLive.Stdout "$($submitLive.JobId) cancelled" 'confirmation line names cancelled'

    Assert-True (-not (Test-CcodexWorkerAlive -BackendId $runningStatus.backend_id)) 'the worker backend is dead after cancel'

    $childDeadDeadline = (Get-Date).AddSeconds(5)
    $childAlive = $true
    while ((Get-Date) -lt $childDeadDeadline) {
        if (-not (Get-Process -Id $fakeChildPid -ErrorAction SilentlyContinue)) { $childAlive = $false; break }
        Start-Sleep -Milliseconds 100
    }
    Assert-True (-not $childAlive) 'the fake-codex child (grandchild of the worker) is also dead after the tree kill'

    $statusLiveAfter = Get-Content -LiteralPath (Join-Path $submitLive.JobDir 'status.json') -Raw | ConvertFrom-Json
    Assert-Equal $statusLiveAfter.status 'cancelled' 'status.json status becomes cancelled after killing the live worker'
    Assert-True ($null -ne $statusLiveAfter.cancelled_at -and $statusLiveAfter.cancelled_at -ne '') 'status.json carries a cancelled_at timestamp'
    Assert-True ($null -eq $statusLiveAfter.wrapper_exit_code) 'wrapper_exit_code stays untouched (null) for a killed running job'

    foreach ($artifact in @('prompt.md', 'command.txt', 'debug.json', 'status.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $submitLive.JobDir $artifact) -PathType Leaf) "artifact $artifact is preserved after cancel"
    }
} finally {
    $env:CCODEX_FAKE_DELAY_MS = $savedDelay
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_PIDFILE = $savedPidFile
    Remove-Item Env:\CCODEX_FAKE_DELAY_MS, Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_PIDFILE -ErrorAction SilentlyContinue
}

# ============================================================
# (e2) kill fails (best-effort taskkill failure swallowed) + worker stays alive ->
#      cancel must NOT write `cancelled`; report the kill failure and exit 12
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: kill fails and the worker is still alive after the poll -> no cancelled write, exit 12"
$jobKillFails = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
$beforeKillFails = Get-Content -LiteralPath (Join-Path $jobKillFails.JobDir 'status.json') -Raw
# Shadow Stop-CcodexProcessTree as a no-op: it is best-effort in production (it swallows
# taskkill launch/exit failures), so this simulates a kill that silently failed. $aliveBackendId
# names THIS test process itself, which we never actually try to kill, so it stays alive for
# the whole poll window -- exactly the "kill failed, worker still alive" scenario. -KillPollTimeoutSec
# 1 keeps the poll bounded-but-real without slowing the suite by the production 10s default.
function Stop-CcodexProcessTree { param([int]$ProcessId) }
try {
    $resultKillFails = Invoke-CcodexCancelCommand -JobId $jobKillFails.JobId -StateRoot $localAppData -KillPollTimeoutSec 1
} finally {
    # Restore the real Stop-CcodexProcessTree immediately -- (f) below installs its own
    # (throwing) shadow deliberately as the LAST override in this runspace, so this one must
    # not leak into it or into the shell-level tests further down.
    . (Join-Path $repoRoot 'lib\CodexInvoke.ps1')
}
Assert-Equal $resultKillFails.WrapperExitCode 12 'cancel exits 12 when the worker cannot be killed and is still alive after the poll'
Assert-True (-not [string]::IsNullOrEmpty($resultKillFails.Message)) 'the kill-failure result carries a diagnostic message'
Assert-True ($resultKillFails.Message -like '*could not*' -or $resultKillFails.Message -like '*failed to terminate*') 'the kill-failure message names the failure'
$afterKillFails = Get-Content -LiteralPath (Join-Path $jobKillFails.JobDir 'status.json') -Raw
Assert-Equal $afterKillFails $beforeKillFails 'status.json is byte-for-byte untouched (still running) when the kill fails -- never written as cancelled'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobKillFails.JobDir '.lock'))) 'the per-job lock is released after the failed-kill path'
Assert-True (Test-CcodexWorkerAlive -BackendId $aliveBackendId) 'this test process (standing in for the unkillable worker) is still alive, confirming nothing was actually killed'

# ============================================================
# (f) leaked-lock regression: an exception in the post-lock body still releases the lock
# ============================================================

Write-Host "Invoke-CcodexCancelCommand: an exception after acquiring the lock still releases it (try/finally)"
$jobLeak = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
# Force the kill branch to throw AFTER the lock is acquired. Shadowing Stop-CcodexProcessTree
# exercises the failure path without actually killing this test process. This shadow persists
# for the rest of the runspace, so it is the LAST in-process cancel test; the wait/read/status
# tests below never call cancel, and the shell-level tests run in separate processes.
function Stop-CcodexProcessTree { param([int]$ProcessId) throw 'simulated taskkill launch failure' }
$leakThrew = $false
try {
    Invoke-CcodexCancelCommand -JobId $jobLeak.JobId -StateRoot $localAppData | Out-Null
} catch {
    $leakThrew = $true
}
Assert-True $leakThrew 'the simulated post-lock failure propagates out of cancel'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobLeak.JobDir '.lock'))) 'the per-job lock is released even when the post-lock body throws (no leaked .lock)'

# ============================================================
# `wait` on a terminal cancelled job -> exit 22
# ============================================================

Write-Host "Invoke-CcodexWaitCommand: cancelled job -> exit 22"
$jobWaitCancelled = New-CcodexTestJobWithStatus -Status 'cancelled'
$resultWaitCancelled = Invoke-CcodexWaitCommand -JobId $jobWaitCancelled.JobId -StateRoot $localAppData
Assert-Equal $resultWaitCancelled.WrapperExitCode 22 'wait on a cancelled job exits 22'
Assert-True ($resultWaitCancelled.Message -like "*$($jobWaitCancelled.JobId)*") 'wait cancelled message includes the job id'
Assert-True ($resultWaitCancelled.Message -like '*cancelled*') 'wait cancelled message names cancelled'

# ============================================================
# `read` on a cancelled job -> existing terminal rules (result present -> 0, absent -> 11)
# ============================================================

Write-Host "Invoke-CcodexReadCommand: cancelled job with result.md -> exit 0, content on stdout"
$jobReadCancelledWithResult = New-CcodexTestJobWithStatus -Status 'cancelled' -WithResultFile
$resultReadCancelledWithResult = Invoke-CcodexReadCommand -JobId $jobReadCancelledWithResult.JobId -StateRoot $localAppData
Assert-Equal $resultReadCancelledWithResult.WrapperExitCode 0 'read on a cancelled job with result.md exits 0'
Assert-Equal $resultReadCancelledWithResult.Stdout 'the result' 'read on a cancelled job prints the result.md content'

Write-Host "Invoke-CcodexReadCommand: cancelled job with no result.md -> exit 11"
$jobReadCancelledNoResult = New-CcodexTestJobWithStatus -Status 'cancelled'
$resultReadCancelledNoResult = Invoke-CcodexReadCommand -JobId $jobReadCancelledNoResult.JobId -StateRoot $localAppData
Assert-Equal $resultReadCancelledNoResult.WrapperExitCode 11 'read on a cancelled job with no result.md exits 11'

# ============================================================
# `status` on a cancelled job -> codes shown as usual
# ============================================================

Write-Host "Invoke-CcodexStatusCommand: cancelled job -> terminal line with codes, same shape as done/failed"
$jobStatusCancelled = New-CcodexTestJobWithStatus -Status 'cancelled'
$resultStatusCancelled = Invoke-CcodexStatusCommand -JobId $jobStatusCancelled.JobId -StateRoot $localAppData
Assert-Equal $resultStatusCancelled.WrapperExitCode 0 'status on a cancelled job exits 0'
Assert-Equal $resultStatusCancelled.Stdout "$($jobStatusCancelled.JobId) cancelled codex_exit_code=null wrapper_exit_code=null" 'cancelled status line shows codes like done/failed'

# ============================================================
# dispatcher wiring: shell-level `ccodex.ps1 cancel <id> --state-root ...`
# ============================================================

Write-Host "shell-level: ccodex.ps1 cancel <id> --state-root <root> on an already-done job -> no-op line, exit 0"
$jobShellCancel = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$shellCancelOut = & pwsh -NoLogo -NoProfile -File $ccodexPs cancel $jobShellCancel.JobId --state-root $localAppData
$shellCancelExit = $LASTEXITCODE
Assert-Equal $shellCancelExit 0 'shell-level cancel invocation exits 0'
$shellCancelLines = @($shellCancelOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-Equal $shellCancelLines.Count 1 'shell-level cancel prints exactly one line'
Assert-Equal $shellCancelLines[0] "$($jobShellCancel.JobId) already done" 'shell-level cancel line matches the no-op format'

Write-Host "shell-level: ccodex.ps1 cancel with no job id -> exit 2"
$shellCancelNoIdOut = & pwsh -NoLogo -NoProfile -File $ccodexPs cancel --state-root $localAppData
$shellCancelNoIdExit = $LASTEXITCODE
Assert-Equal $shellCancelNoIdExit 2 'shell-level cancel with no job id exits 2'

Write-Host "shell-level: unknown command message names cancel among the supported commands"
$shellUnknownOut = & pwsh -NoLogo -NoProfile -File $ccodexPs bogus-command
$shellUnknownExit = $LASTEXITCODE
Assert-Equal $shellUnknownExit 2 'an unknown command exits 2'
Assert-True ((($shellUnknownOut -join "`n")) -like '*cancel*') 'the supported-commands message now lists cancel'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
