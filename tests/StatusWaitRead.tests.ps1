# tests/StatusWaitRead.tests.ps1
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
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')
. (Join-Path $PSScriptRoot '..\lib\Detach.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-statuswaitread-test-$([Guid]::NewGuid().ToString('N'))"
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
    # Seeds a job dir via the real reservation/index path (like Worker.tests.ps1's
    # New-CcodexTestJob), then overwrites status.json with the given shape so every
    # status-command branch can be exercised deterministically.
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$Status = 'created',
        [string]$BackendId = $null,
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [switch]$WithExitCodeEvidence,
        [int]$EvidenceExitCode = 0,
        [switch]$WithResultFile,
        [string]$LastHeartbeatAt = $null,
        [string]$StartedAt = $null,
        [string]$ParentJobId = $null,
        [string]$TimeoutReason = $null
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
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status $Status -Mode $Mode -Access $Access -Repo $targetRepo -CreatedAt $createdAt -BackendId $BackendId -CodexExitCode $CodexExitCode -WrapperExitCode $WrapperExitCode -StartedAt $StartedAt -LastHeartbeatAt $LastHeartbeatAt -ParentJobId $ParentJobId -TimeoutReason $TimeoutReason
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    if ($WithExitCodeEvidence) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'exit_code.txt') -Content "$EvidenceExitCode"
    }
    if ($WithResultFile) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'result.md') -Content 'the result'
    }
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

# --- status: created (non-terminal) ---

Write-Host "Invoke-CcodexStatusCommand: created job -> one line, no health flag, exit 0"
$jobCreated = New-CcodexTestJobWithStatus -Status 'created'
$resultCreated = Invoke-CcodexStatusCommand -JobId $jobCreated.JobId -StateRoot $localAppData
Assert-Equal $resultCreated.WrapperExitCode 0 'created job -> exit 0'
Assert-Equal $resultCreated.Stdout "$($jobCreated.JobId) created" 'created job status line has no codes/health'

# --- status: running + worker alive (non-terminal) ---

Write-Host "Invoke-CcodexStatusCommand: running + worker alive + fresh heartbeat -> health=ok"
$freshHeartbeat = (Get-Date).ToUniversalTime().ToString('o')
$jobAlive = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId -LastHeartbeatAt $freshHeartbeat
$resultAlive = Invoke-CcodexStatusCommand -JobId $jobAlive.JobId -StateRoot $localAppData
Assert-Equal $resultAlive.WrapperExitCode 0 'running+alive job -> exit 0'
Assert-Equal $resultAlive.Stdout "$($jobAlive.JobId) running health=ok" 'running+alive+fresh-heartbeat status line shows health=ok'
$statusAliveAfter = Get-Content -LiteralPath (Join-Path $jobAlive.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusAliveAfter.status 'running' 'running+alive status.json unchanged'

Write-Host "Invoke-CcodexStatusCommand: running + worker alive + stale heartbeat -> health=stale"
$oldHeartbeat = (Get-Date).ToUniversalTime().AddSeconds(-600).ToString('o')
$jobStaleHb = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId -LastHeartbeatAt $oldHeartbeat
$resultStaleHb = Invoke-CcodexStatusCommand -JobId $jobStaleHb.JobId -StateRoot $localAppData
Assert-Equal $resultStaleHb.WrapperExitCode 0 'running+alive+stale-heartbeat job -> exit 0'
Assert-Equal $resultStaleHb.Stdout "$($jobStaleHb.JobId) running health=stale" 'running+alive+old-heartbeat status line shows health=stale'

# --- status: running + worker dead + exit_code.txt evidence -> reconciled terminal line, file rewritten ---

Write-Host "Invoke-CcodexStatusCommand: running + dead worker + evidence -> reconciled done line, status.json rewritten"
$jobDeadEvidence = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
$beforeRewrite = (Get-Item (Join-Path $jobDeadEvidence.JobDir 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadEvidence = Invoke-CcodexStatusCommand -JobId $jobDeadEvidence.JobId -StateRoot $localAppData
Assert-Equal $resultDeadEvidence.WrapperExitCode 0 'reconciled dead-with-evidence job -> exit 0'
Assert-Equal $resultDeadEvidence.Stdout "$($jobDeadEvidence.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'reconciled line shows terminal done with codes'
$afterRewrite = (Get-Item (Join-Path $jobDeadEvidence.JobDir 'status.json')).LastWriteTimeUtc
Assert-True ($afterRewrite -gt $beforeRewrite) 'status.json was rewritten during reconciliation'
$statusDeadEvidenceAfter = Get-Content -LiteralPath (Join-Path $jobDeadEvidence.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDeadEvidenceAfter.status 'done' 'status.json reflects reconciled done status'

# --- status: running + worker dead + no evidence -> possibly-stale line, file NOT rewritten ---

Write-Host "Invoke-CcodexStatusCommand: running + dead worker + no evidence -> possibly-stale line, no rewrite"
$jobDeadNoEvidence = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId
$beforeNoRewrite = (Get-Item (Join-Path $jobDeadNoEvidence.JobDir 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadNoEvidence = Invoke-CcodexStatusCommand -JobId $jobDeadNoEvidence.JobId -StateRoot $localAppData
Assert-Equal $resultDeadNoEvidence.WrapperExitCode 0 'dead-worker-no-evidence job -> exit 0'
Assert-Equal $resultDeadNoEvidence.Stdout "$($jobDeadNoEvidence.JobId) running health=possibly-stale" 'possibly-stale line appended for dead worker without evidence'
$afterNoRewrite = (Get-Item (Join-Path $jobDeadNoEvidence.JobDir 'status.json')).LastWriteTimeUtc
Assert-Equal $afterNoRewrite $beforeNoRewrite 'status.json was NOT rewritten when there is no completion evidence'

# --- status: contended reconciliation lock -> prompt possibly-stale answer, no lock wait (backlog #16) ---

Write-Host "Invoke-CcodexStatusCommand: a held reconciliation lock answers promptly with possibly-stale, never waiting on the lock"
# Fixture must be reconcilable (running + dead backend + parsable exit-code evidence) so the
# read-path actually reaches the lock attempt; otherwise it returns before any lock is taken and
# the test proves nothing (issue #2 amendment 6). Hold the lock in THIS live process so it is
# never treated as stale, then measure ONLY the in-process command call (issue #2 amendment 5:
# exclude process startup from the stopwatch).
$jobStatusLockHeld = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
$beforeStatusLockHeld = (Get-Item (Join-Path $jobStatusLockHeld.JobDir 'status.json')).LastWriteTimeUtc
Lock-CcodexJob -JobDir $jobStatusLockHeld.JobDir -TimeoutSec 1 -CommandName 'test-holder' | Out-Null
try {
    $statusLockStart = Get-Date
    $resultStatusLockHeld = Invoke-CcodexStatusCommand -JobId $jobStatusLockHeld.JobId -StateRoot $localAppData
    $statusLockElapsed = ((Get-Date) - $statusLockStart).TotalSeconds
} finally {
    Unlock-CcodexJob -JobDir $jobStatusLockHeld.JobDir
}
Assert-Equal $resultStatusLockHeld.WrapperExitCode 0 'contended status still exits 0'
Assert-Equal $resultStatusLockHeld.Stdout "$($jobStatusLockHeld.JobId) running health=possibly-stale" 'contended status reports possibly-stale rather than reconciling'
Assert-True ($statusLockElapsed -lt 3) 'status does not wait on the reconciliation lock (well under the old 10s default)'
$afterStatusLockHeld = (Get-Item (Join-Path $jobStatusLockHeld.JobDir 'status.json')).LastWriteTimeUtc
Assert-Equal $afterStatusLockHeld $beforeStatusLockHeld 'contended status left status.json unwritten'

Write-Host "Invoke-CcodexStatusCommand: once the lock is free, the next status call reconciles to the terminal verdict"
$resultStatusAfterRelease = Invoke-CcodexStatusCommand -JobId $jobStatusLockHeld.JobId -StateRoot $localAppData
Assert-Equal $resultStatusAfterRelease.Stdout "$($jobStatusLockHeld.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'a later uncontended status reconciles the orphan to its terminal status'

# --- status: done (terminal) ---

Write-Host "Invoke-CcodexStatusCommand: already-done job -> terminal line with codes"
$jobDone = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$resultDone = Invoke-CcodexStatusCommand -JobId $jobDone.JobId -StateRoot $localAppData
Assert-Equal $resultDone.WrapperExitCode 0 'done job -> exit 0'
Assert-Equal $resultDone.Stdout "$($jobDone.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'done job status line shows both codes'

# --- status: failed (terminal) ---

Write-Host "Invoke-CcodexStatusCommand: failed job -> terminal line with codes"
$jobFailed = New-CcodexTestJobWithStatus -Status 'failed' -CodexExitCode 1 -WrapperExitCode 10
$resultFailed = Invoke-CcodexStatusCommand -JobId $jobFailed.JobId -StateRoot $localAppData
Assert-Equal $resultFailed.WrapperExitCode 0 'failed job -> exit 0 (printing status is success)'
Assert-Equal $resultFailed.Stdout "$($jobFailed.JobId) failed codex_exit_code=1 wrapper_exit_code=10" 'failed job status line shows both codes'

# --- status: timed_out (terminal) ---

Write-Host "Invoke-CcodexStatusCommand: timed_out job -> lifecycle-only line, exit 0"
$jobTimedOut = New-CcodexTestJobWithStatus -Status 'timed_out' -WrapperExitCode 24
$resultTimedOut = Invoke-CcodexStatusCommand -JobId $jobTimedOut.JobId -StateRoot $localAppData
Assert-Equal $resultTimedOut.WrapperExitCode 0 'timed_out job -> exit 0 (printing status is success)'
Assert-Equal $resultTimedOut.Stdout "$($jobTimedOut.JobId) timed_out" 'timed_out status line is lifecycle-only (no codes, no health)'

# --- status: unknown job id -> 3 ---

Write-Host "Invoke-CcodexStatusCommand: unknown job id -> exit 3"
$resultUnknown = Invoke-CcodexStatusCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultUnknown.Message)) 'unknown job id returns a diagnostic message'

# --- status: parent lineage surfacing ---

Write-Host "Invoke-CcodexStatusCommand: resumed (child) job with parent_job_id -> status line appends parent=<id>"
$jobParentless = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$jobChild = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -ParentJobId $jobParentless.JobId
$resultChild = Invoke-CcodexStatusCommand -JobId $jobChild.JobId -StateRoot $localAppData
Assert-Equal $resultChild.WrapperExitCode 0 'resumed job status -> exit 0'
Assert-Equal $resultChild.Stdout "$($jobChild.JobId) done codex_exit_code=0 wrapper_exit_code=0 parent=$($jobParentless.JobId)" 'resumed job status line appends parent=<parent_job_id>'

Write-Host "Invoke-CcodexStatusCommand: parentless job status line is unchanged (no parent= suffix)"
$resultParentless = Invoke-CcodexStatusCommand -JobId $jobParentless.JobId -StateRoot $localAppData
Assert-Equal $resultParentless.WrapperExitCode 0 'parentless job status -> exit 0'
Assert-Equal $resultParentless.Stdout "$($jobParentless.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'parentless job status line has no parent= suffix'

Write-Host "Invoke-CcodexStatusCommand: non-terminal resumed job also appends parent=<id>"
$jobChildRunning = New-CcodexTestJobWithStatus -Status 'created' -ParentJobId $jobParentless.JobId
$resultChildRunning = Invoke-CcodexStatusCommand -JobId $jobChildRunning.JobId -StateRoot $localAppData
Assert-Equal $resultChildRunning.WrapperExitCode 0 'non-terminal resumed job status -> exit 0'
Assert-Equal $resultChildRunning.Stdout "$($jobChildRunning.JobId) created parent=$($jobParentless.JobId)" 'non-terminal resumed job status line appends parent=<parent_job_id>'

# --- shell-level: pwsh -File ccodex.ps1 status <id> --state-root ... ---

Write-Host "shell-level: ccodex.ps1 status <id> --state-root <root> prints exactly one line, exit 0"
$jobShell = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$shellOut = & pwsh -NoLogo -NoProfile -File $ccodexPs status $jobShell.JobId --state-root $localAppData
$shellExit = $LASTEXITCODE
Assert-Equal $shellExit 0 'shell-level status invocation exits 0'
$shellOutLines = @($shellOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-Equal $shellOutLines.Count 1 'shell-level status prints exactly one line'
Assert-Equal $shellOutLines[0] "$($jobShell.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'shell-level status line matches the terminal format'

# --- status: JSON lifecycle envelope ---

Write-Host "Invoke-CcodexStatusCommand: --json running, terminal, stale, lineage, and unknown envelopes"
$statusRunningJsonResult = Invoke-CcodexStatusCommand -JobId $jobAlive.JobId -Json -StateRoot $localAppData
$statusRunningJson = $statusRunningJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $statusRunningJsonResult.WrapperExitCode 0 'status --json running -> exit 0'
Assert-Equal $statusRunningJson.schema_version 1 'status --json schema version is 1'
Assert-Equal $statusRunningJson.job_id $jobAlive.JobId 'status --json includes job id'
Assert-Equal $statusRunningJson.status 'running' 'status --json includes running status'
Assert-Equal $statusRunningJson.command_exit_code 0 'status --json includes command exit code'
Assert-Equal $statusRunningJson.health 'ok' 'status --json includes derived health'
foreach ($key in @('codex_exit_code', 'wrapper_exit_code', 'parent_job_id')) {
    Assert-True ($statusRunningJson.PSObject.Properties.Name -contains $key) "status --json always includes $key"
}

$statusDoneJson = (Invoke-CcodexStatusCommand -JobId $jobDone.JobId -Json -StateRoot $localAppData).Stdout | ConvertFrom-Json
Assert-Equal $statusDoneJson.codex_exit_code 0 'status --json terminal includes codex exit code'
Assert-Equal $statusDoneJson.wrapper_exit_code 0 'status --json terminal includes wrapper exit code'
Assert-Equal $statusDoneJson.command_exit_code 0 'status --json terminal includes command exit 0'

$statusStaleJson = (Invoke-CcodexStatusCommand -JobId $jobDeadNoEvidence.JobId -Json -StateRoot $localAppData).Stdout | ConvertFrom-Json
Assert-Equal $statusStaleJson.health 'possibly-stale' 'status --json surfaces reconciliation health'

$statusChildJson = (Invoke-CcodexStatusCommand -JobId $jobChild.JobId -Json -StateRoot $localAppData).Stdout | ConvertFrom-Json
Assert-Equal $statusChildJson.parent_job_id $jobParentless.JobId 'status --json surfaces parent lineage'

$statusUnknownJsonResult = Invoke-CcodexStatusCommand -JobId 'does-not-exist-json' -Json -StateRoot $localAppData
$statusUnknownJson = $statusUnknownJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $statusUnknownJsonResult.WrapperExitCode 3 'status --json unknown -> exit 3'
Assert-Equal $statusUnknownJson.status 'unknown' 'status --json unknown has unknown status'
Assert-Equal $statusUnknownJson.command_exit_code 3 'status --json unknown includes command exit 3'
Assert-True (-not [string]::IsNullOrEmpty($statusUnknownJson.error)) 'status --json unknown includes error'

Write-Host "shell-level: status --json emits its envelope on stdout"
$shellStatusJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs status $jobDone.JobId --json --state-root $localAppData
$shellStatusJsonExit = $LASTEXITCODE
$shellStatusJson = ($shellStatusJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellStatusJsonExit 0 'shell-level status --json exits 0'
Assert-Equal $shellStatusJson.command_exit_code 0 'shell-level status --json emits parseable envelope'

$shellStatusRunningJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs status $jobAlive.JobId --json --state-root $localAppData
$shellStatusRunningJsonExit = $LASTEXITCODE
$shellStatusRunningJson = ($shellStatusRunningJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellStatusRunningJsonExit 0 'shell-level status --json running exits 0'
Assert-Equal $shellStatusRunningJson.status 'running' 'shell-level status --json running emits current state'

$shellStatusUnknownJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs status does-not-exist-json --json --state-root $localAppData
$shellStatusUnknownJsonExit = $LASTEXITCODE
$shellStatusUnknownJson = ($shellStatusUnknownJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellStatusUnknownJsonExit 3 'shell-level status --json unknown exits 3'
Assert-Equal $shellStatusUnknownJson.command_exit_code 3 'shell-level status --json unknown exit matches envelope'

function Wait-CcodexTestTerminalStatus {
    param([Parameter(Mandatory)][string]$JobDir, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $status = Read-CcodexStatusFile -JobDir $JobDir
        if ($status -and $status.status -in @('done', 'failed')) { return $status }
        if ((Get-Date) -ge $deadline) { return $status }
        Start-Sleep -Milliseconds 250
    }
}

# ============================================================
# Invoke-CcodexWaitCommand
# ============================================================

# --- (a) already-done job -> result on stdout, exit 0 ---

Write-Host "Invoke-CcodexWaitCommand: already-done job -> result.md content on stdout, exit 0"
$jobWaitDone = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -WithResultFile
$resultWaitDone = Invoke-CcodexWaitCommand -JobId $jobWaitDone.JobId -StateRoot $localAppData
Assert-Equal $resultWaitDone.WrapperExitCode 0 'already-done job -> exit 0'
Assert-Equal $resultWaitDone.Stdout 'the result' 'already-done job -> stdout carries result.md content'

# --- (b) failed job (wrapper 10 recorded) -> exit 10 ---

Write-Host "Invoke-CcodexWaitCommand: failed job with recorded wrapper_exit_code=10 -> exit 10"
$jobWaitFailed = New-CcodexTestJobWithStatus -Status 'failed' -CodexExitCode 1 -WrapperExitCode 10
$resultWaitFailed = Invoke-CcodexWaitCommand -JobId $jobWaitFailed.JobId -StateRoot $localAppData
Assert-Equal $resultWaitFailed.WrapperExitCode 10 'failed job with recorded wrapper_exit_code=10 -> exit 10'
Assert-True (-not [string]::IsNullOrEmpty($resultWaitFailed.Message)) 'failed job returns a diagnostic message'
Assert-True ($resultWaitFailed.Message -like "*$($jobWaitFailed.JobId)*") 'failed job message includes the job id'

# --- (c) done but empty result -> exit 11 ---

Write-Host "Invoke-CcodexWaitCommand: done status but empty/missing result.md -> exit 11"
$jobWaitEmpty = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$resultWaitEmpty = Invoke-CcodexWaitCommand -JobId $jobWaitEmpty.JobId -StateRoot $localAppData
Assert-Equal $resultWaitEmpty.WrapperExitCode 11 'done job with missing result.md -> exit 11'
Assert-True (-not [string]::IsNullOrEmpty($resultWaitEmpty.Message)) 'empty-result job returns a diagnostic message'

Write-Host "Invoke-CcodexWaitCommand: a contended orphan-reconciliation lock never blocks and preserves possibly-stale at the deadline"
# Reconcilable orphan (running + dead backend + parsable exit-code evidence) so the poll actually
# reaches the lock attempt (issue #2 amendment 6). With the lock held for the whole wait, every
# poll (INCLUDING the deadline iteration) reconciles zero-wait, degrades to possibly-stale, and
# the job never resolves -> exit 20 whose status line still carries health=possibly-stale.
$jobWaitLockBudget = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
Lock-CcodexJob -JobDir $jobWaitLockBudget.JobDir -TimeoutSec 1 -CommandName 'test-holder' | Out-Null
try {
    $waitLockBudgetStart = Get-Date
    $waitLockBudgetResult = Invoke-CcodexWaitCommand -JobId $jobWaitLockBudget.JobId -WaitTimeoutSec 1 -PollIntervalMs 50 -StateRoot $localAppData
    $waitLockBudgetElapsed = ((Get-Date) - $waitLockBudgetStart).TotalSeconds
} finally {
    Unlock-CcodexJob -JobDir $jobWaitLockBudget.JobDir
}
Assert-Equal $waitLockBudgetResult.WrapperExitCode 20 'wait returns its timeout when reconciliation cannot acquire the lock'
Assert-True ($waitLockBudgetElapsed -lt 1.75) 'wait does not let orphan reconciliation exceed its remaining timeout budget'
Assert-True ($waitLockBudgetResult.Message -like '*health=possibly-stale*') 'wait timeout on a contended orphan preserves health=possibly-stale (deadline iteration still reconciles zero-wait)'
Assert-Equal (Read-CcodexStatusFile -JobDir $jobWaitLockBudget.JobDir).status 'running' 'contended wait left status.json unreconciled'

# --- (d) slow job: submit via startprocess against a delayed fake-codex, timeout then completion ---

Write-Host "Invoke-CcodexWaitCommand: slow job -> --wait-timeout-sec 1 times out with 20 while sleeping, lifecycle unchanged"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SLOW WAIT RESULT'
$env:CCODEX_FAKE_DELAY_MS = '4000'
$submitSlow = Invoke-CcodexSubmit -Mode 'review' -Access $null -RepoOverride $targetRepo -PromptFile $null `
    -PositionalTask 'slow task' -PipelineExpected $false -PipelineObjects $null -DetachMechanism 'startprocess' `
    -CodexPath $fixtureCmd -LocalAppDataRoot $localAppData -AppDataRoot $appData
Assert-Equal $submitSlow.WrapperExitCode 0 'slow job submits successfully'
try {
    $beforeTimeoutStatus = Read-CcodexStatusFile -JobDir $submitSlow.JobDir
    $resultTimeout = Invoke-CcodexWaitCommand -JobId $submitSlow.JobId -WaitTimeoutSec 1 -PollIntervalMs 200 -StateRoot $localAppData
    Assert-Equal $resultTimeout.WrapperExitCode 20 'wait on a still-sleeping job times out with exit 20'
    Assert-True (-not [string]::IsNullOrEmpty($resultTimeout.Message)) 'timeout returns a diagnostic message'
    Assert-True ($resultTimeout.Message -like "*re-run*wait $($submitSlow.JobId)*") 'timeout message hints at re-running ccodex wait <id>'
    $afterTimeoutStatus = Read-CcodexStatusFile -JobDir $submitSlow.JobDir
    Assert-Equal $afterTimeoutStatus.status $beforeTimeoutStatus.status 'timeout does not change the job status'
    Assert-True ($afterTimeoutStatus.status -notin @('done', 'failed')) 'timed-out job is still non-terminal'

    $terminalSlow = Wait-CcodexTestTerminalStatus -JobDir $submitSlow.JobDir -TimeoutSec 20
    Assert-True ($terminalSlow -ne $null) 'slow job eventually reaches a terminal status object'
    Assert-Equal $terminalSlow.status 'done' 'slow job completes to done after the fixture delay elapses'

    $resultAfterDelay = Invoke-CcodexWaitCommand -JobId $submitSlow.JobId -StateRoot $localAppData
    Assert-Equal $resultAfterDelay.WrapperExitCode 0 'a second wait with no timeout returns 0 once the job is done'
    Assert-True ($resultAfterDelay.Stdout -like '*SLOW WAIT RESULT*') 'second wait returns the fixture result content'
} finally {
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue
}

# --- (d2) timed_out job -> exit 24 (recorded) ---

Write-Host "Invoke-CcodexWaitCommand: timed_out job with recorded wrapper_exit_code=24 -> exit 24"
$jobWaitTimedOut = New-CcodexTestJobWithStatus -Status 'timed_out' -WrapperExitCode 24
$resultWaitTimedOut = Invoke-CcodexWaitCommand -JobId $jobWaitTimedOut.JobId -StateRoot $localAppData
Assert-Equal $resultWaitTimedOut.WrapperExitCode 24 'timed_out job -> exit 24'
Assert-True ($resultWaitTimedOut.Message -like "*$($jobWaitTimedOut.JobId)*") 'timed_out wait message includes the job id'
Assert-True ($resultWaitTimedOut.Message -like '*timed_out*') 'timed_out wait message names the timed_out status'

# --- (e) unknown job id -> exit 3 ---

Write-Host "Invoke-CcodexWaitCommand: unknown job id -> exit 3"
$resultWaitUnknown = Invoke-CcodexWaitCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultWaitUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultWaitUnknown.Message)) 'unknown job id returns a diagnostic message'

# --- shell-level: pwsh -File ccodex.ps1 wait <id> --state-root ... (already-done job) ---

Write-Host "shell-level: ccodex.ps1 wait <id> --state-root <root> prints result.md content, exit 0"
$jobWaitShell = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -WithResultFile
$shellWaitOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitShell.JobId --state-root $localAppData
$shellWaitExit = $LASTEXITCODE
Assert-Equal $shellWaitExit 0 'shell-level wait invocation exits 0'
$shellWaitOutLines = @($shellWaitOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-Equal $shellWaitOutLines.Count 1 'shell-level wait prints exactly one line'
Assert-Equal $shellWaitOutLines[0] 'the result' 'shell-level wait prints the result.md content'

# --- wait: JSON lifecycle envelope ---

Write-Host "Invoke-CcodexWaitCommand: --json terminal envelopes"
$waitDoneJsonResult = Invoke-CcodexWaitCommand -JobId $jobWaitDone.JobId -Json -StateRoot $localAppData
$waitDoneJson = $waitDoneJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $waitDoneJson.schema_version 1 'wait --json schema version is 1'
Assert-Equal $waitDoneJson.result 'the result' 'wait --json done includes result content'
Assert-Equal $waitDoneJson.command_exit_code 0 'wait --json done command exit is 0'

$waitFailedJsonResult = Invoke-CcodexWaitCommand -JobId $jobWaitFailed.JobId -Json -StateRoot $localAppData
$waitFailedJson = $waitFailedJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $waitFailedJsonResult.WrapperExitCode 10 'wait --json failed preserves exit 10'
Assert-Equal $waitFailedJson.command_exit_code 10 'wait --json failed command exit matches invocation'
Assert-Equal $waitFailedJson.codex_exit_code 1 'wait --json failed surfaces codex exit code'

$jobWaitTimedOutJson = New-CcodexTestJobWithStatus -Status 'timed_out' -WrapperExitCode 24 -TimeoutReason 'hard_timeout_sec=30 exceeded'
$waitTimedOutJsonResult = Invoke-CcodexWaitCommand -JobId $jobWaitTimedOutJson.JobId -Json -StateRoot $localAppData
$waitTimedOutJson = $waitTimedOutJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $waitTimedOutJsonResult.WrapperExitCode 24 'wait --json timed_out preserves exit 24'
Assert-Equal $waitTimedOutJson.command_exit_code 24 'wait --json timed_out command exit is 24'
Assert-Equal $waitTimedOutJson.timeout_reason 'hard_timeout_sec=30 exceeded' 'wait --json surfaces timeout reason'

$jobWaitCancelledJson = New-CcodexTestJobWithStatus -Status 'cancelled' -WrapperExitCode 22
$waitCancelledJsonResult = Invoke-CcodexWaitCommand -JobId $jobWaitCancelledJson.JobId -Json -StateRoot $localAppData
$waitCancelledJson = $waitCancelledJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $waitCancelledJsonResult.WrapperExitCode 22 'wait --json cancelled preserves exit 22'
Assert-Equal $waitCancelledJson.command_exit_code 22 'wait --json cancelled command exit is 22'

$jobWaitOwnTimeoutJson = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
$waitOwnTimeoutStatusPath = Join-Path $jobWaitOwnTimeoutJson.JobDir 'status.json'
$waitOwnTimeoutBefore = Get-Content -LiteralPath $waitOwnTimeoutStatusPath -Raw
$waitOwnTimeoutJsonResult = Invoke-CcodexWaitCommand -JobId $jobWaitOwnTimeoutJson.JobId -Json -WaitTimeoutSec 1 -PollIntervalMs 50 -StateRoot $localAppData
$waitOwnTimeoutAfter = Get-Content -LiteralPath $waitOwnTimeoutStatusPath -Raw
$waitOwnTimeoutJson = $waitOwnTimeoutJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $waitOwnTimeoutJsonResult.WrapperExitCode 20 'wait --json own timeout preserves exit 20'
Assert-Equal $waitOwnTimeoutJson.status 'running' 'wait --json own timeout includes current status'
Assert-Equal $waitOwnTimeoutJson.command_exit_code 20 'wait --json own timeout command exit is 20'
Assert-Equal $waitOwnTimeoutAfter $waitOwnTimeoutBefore 'wait --json own timeout does not mutate status.json'

Write-Host "shell-level: wait --json emits envelope on stdout for a nonzero exit"
$shellWaitJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitCancelledJson.JobId --json --state-root $localAppData
$shellWaitJsonExit = $LASTEXITCODE
$shellWaitJson = ($shellWaitJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellWaitJsonExit 22 'shell-level wait --json preserves cancelled exit 22'
Assert-Equal $shellWaitJson.command_exit_code 22 'shell-level wait --json emits nonzero envelope on stdout'

$shellWaitDoneJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitDone.JobId --json --state-root $localAppData
$shellWaitDoneJsonExit = $LASTEXITCODE
$shellWaitDoneJson = ($shellWaitDoneJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellWaitDoneJsonExit 0 'shell-level wait --json done exits 0'
Assert-Equal $shellWaitDoneJson.command_exit_code 0 'shell-level wait --json done exit matches envelope'

$shellWaitFailedJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitFailed.JobId --json --state-root $localAppData
$shellWaitFailedJsonExit = $LASTEXITCODE
$shellWaitFailedJson = ($shellWaitFailedJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellWaitFailedJsonExit 10 'shell-level wait --json failed exits 10'
Assert-Equal $shellWaitFailedJson.command_exit_code 10 'shell-level wait --json failed exit matches envelope'

$shellWaitTimedOutJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitTimedOutJson.JobId --json --state-root $localAppData
$shellWaitTimedOutJsonExit = $LASTEXITCODE
$shellWaitTimedOutJson = ($shellWaitTimedOutJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellWaitTimedOutJsonExit 24 'shell-level wait --json timed_out exits 24'
Assert-Equal $shellWaitTimedOutJson.timeout_reason 'hard_timeout_sec=30 exceeded' 'shell-level wait --json timed_out includes reason'

$shellWaitOwnTimeoutBefore = Get-Content -LiteralPath $waitOwnTimeoutStatusPath -Raw
$shellWaitOwnTimeoutJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs wait $jobWaitOwnTimeoutJson.JobId --json --wait-timeout-sec 1 --state-root $localAppData
$shellWaitOwnTimeoutJsonExit = $LASTEXITCODE
$shellWaitOwnTimeoutAfter = Get-Content -LiteralPath $waitOwnTimeoutStatusPath -Raw
$shellWaitOwnTimeoutJson = ($shellWaitOwnTimeoutJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellWaitOwnTimeoutJsonExit 20 'shell-level wait --json own timeout exits 20'
Assert-Equal $shellWaitOwnTimeoutJson.command_exit_code 20 'shell-level wait --json own timeout exit matches envelope'
Assert-Equal $shellWaitOwnTimeoutAfter $shellWaitOwnTimeoutBefore 'shell-level wait --json own timeout does not mutate status.json'

# ============================================================
# Invoke-CcodexReadCommand
# ============================================================

# --- done-with-result -> exit 0, content printed ---

Write-Host "Invoke-CcodexReadCommand: done job with result.md -> exit 0, content on stdout"
$jobReadDone = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -WithResultFile
$resultReadDone = Invoke-CcodexReadCommand -JobId $jobReadDone.JobId -StateRoot $localAppData
Assert-Equal $resultReadDone.WrapperExitCode 0 'done job with result.md -> exit 0'
Assert-Equal $resultReadDone.Stdout 'the result' 'done job -> stdout carries result.md content'

# --- failed-with-result -> exit 0, content printed (read is the result channel regardless) ---

Write-Host "Invoke-CcodexReadCommand: failed job with result.md -> exit 0, content on stdout"
$jobReadFailed = New-CcodexTestJobWithStatus -Status 'failed' -CodexExitCode 1 -WrapperExitCode 10 -WithResultFile
$resultReadFailed = Invoke-CcodexReadCommand -JobId $jobReadFailed.JobId -StateRoot $localAppData
Assert-Equal $resultReadFailed.WrapperExitCode 0 'failed job with result.md -> exit 0'
Assert-Equal $resultReadFailed.Stdout 'the result' 'failed job -> stdout carries result.md content'

# --- running (non-terminal) -> exit 4 with status+hint, no content ---

Write-Host "Invoke-CcodexReadCommand: running job -> exit 4 with status line and wait hint"
$jobReadRunning = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
$resultReadRunning = Invoke-CcodexReadCommand -JobId $jobReadRunning.JobId -StateRoot $localAppData
Assert-Equal $resultReadRunning.WrapperExitCode 4 'running job -> exit 4'
Assert-True (-not [string]::IsNullOrEmpty($resultReadRunning.Message)) 'running job returns a diagnostic message'
Assert-True ($resultReadRunning.Message -like "*running*") 'running job message includes status'
Assert-True ($resultReadRunning.Message -like "*ccodex wait $($jobReadRunning.JobId)*") 'running job message hints at ccodex wait <job_id>'
Assert-True ([string]::IsNullOrEmpty($resultReadRunning.Stdout)) 'running job returns no stdout content'

# --- created (non-terminal) -> exit 4 ---

Write-Host "Invoke-CcodexReadCommand: created job -> exit 4 with status line and wait hint"
$jobReadCreated = New-CcodexTestJobWithStatus -Status 'created'
$resultReadCreated = Invoke-CcodexReadCommand -JobId $jobReadCreated.JobId -StateRoot $localAppData
Assert-Equal $resultReadCreated.WrapperExitCode 4 'created job -> exit 4'
Assert-True ($resultReadCreated.Message -like "*created*") 'created job message includes status'
Assert-True ($resultReadCreated.Message -like "*ccodex wait $($jobReadCreated.JobId)*") 'created job message hints at ccodex wait <job_id>'

# --- terminal but missing/empty result.md -> exit 11 ---

Write-Host "Invoke-CcodexReadCommand: done job with missing result.md -> exit 11"
$jobReadNoResult = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$resultReadNoResult = Invoke-CcodexReadCommand -JobId $jobReadNoResult.JobId -StateRoot $localAppData
Assert-Equal $resultReadNoResult.WrapperExitCode 11 'done job with missing result.md -> exit 11'
Assert-True (-not [string]::IsNullOrEmpty($resultReadNoResult.Message)) 'missing-result job returns a diagnostic message'
Assert-True ([string]::IsNullOrEmpty($resultReadNoResult.Stdout)) 'missing-result job returns no stdout content'

Write-Host "Invoke-CcodexReadCommand: failed job with empty result.md -> exit 11"
$jobReadFailedEmpty = New-CcodexTestJobWithStatus -Status 'failed' -CodexExitCode 1 -WrapperExitCode 10
Write-CcodexTextFile -Path (Join-Path $jobReadFailedEmpty.JobDir 'result.md') -Content '   '
$resultReadFailedEmpty = Invoke-CcodexReadCommand -JobId $jobReadFailedEmpty.JobId -StateRoot $localAppData
Assert-Equal $resultReadFailedEmpty.WrapperExitCode 11 'failed job with empty result.md -> exit 11'

# --- timed_out (terminal): missing result -> 11, present result -> 0 ---

Write-Host "Invoke-CcodexReadCommand: timed_out job with missing result.md -> exit 11"
$jobReadTimedOut = New-CcodexTestJobWithStatus -Status 'timed_out' -WrapperExitCode 24
$resultReadTimedOut = Invoke-CcodexReadCommand -JobId $jobReadTimedOut.JobId -StateRoot $localAppData
Assert-Equal $resultReadTimedOut.WrapperExitCode 11 'timed_out job with missing result.md -> exit 11'
Assert-True ([string]::IsNullOrEmpty($resultReadTimedOut.Stdout)) 'timed_out-with-no-result read returns no stdout content'

Write-Host "Invoke-CcodexReadCommand: timed_out job with a result.md -> exit 0, content on stdout"
$jobReadTimedOutResult = New-CcodexTestJobWithStatus -Status 'timed_out' -WrapperExitCode 24 -WithResultFile
$resultReadTimedOutResult = Invoke-CcodexReadCommand -JobId $jobReadTimedOutResult.JobId -StateRoot $localAppData
Assert-Equal $resultReadTimedOutResult.WrapperExitCode 0 'timed_out job with result.md -> exit 0 (read is the result channel)'
Assert-Equal $resultReadTimedOutResult.Stdout 'the result' 'timed_out job -> stdout carries result.md content'

# --- read: contended reconciliation lock -> prompt answer, no lock wait (backlog #16) ---

Write-Host "Invoke-CcodexReadCommand: a held reconciliation lock answers promptly (exit 4, possibly-stale), never waiting on the lock"
# Same reconcilable-orphan-with-held-lock fixture as the status contention test: read must not
# stall for the reconciliation lock. It sees the still-running job and returns exit 4 + a wait hint.
$jobReadLockHeld = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
Lock-CcodexJob -JobDir $jobReadLockHeld.JobDir -TimeoutSec 1 -CommandName 'test-holder' | Out-Null
try {
    $readLockStart = Get-Date
    $resultReadLockHeld = Invoke-CcodexReadCommand -JobId $jobReadLockHeld.JobId -StateRoot $localAppData
    $readLockElapsed = ((Get-Date) - $readLockStart).TotalSeconds
} finally {
    Unlock-CcodexJob -JobDir $jobReadLockHeld.JobDir
}
Assert-Equal $resultReadLockHeld.WrapperExitCode 4 'contended read on a still-running orphan exits 4'
Assert-True ($resultReadLockHeld.Message -like '*health=possibly-stale*') 'contended read reports possibly-stale'
Assert-True ($readLockElapsed -lt 3) 'read does not wait on the reconciliation lock (well under the old 10s default)'

# --- unknown job id -> exit 3 ---

Write-Host "Invoke-CcodexReadCommand: unknown job id -> exit 3"
$resultReadUnknown = Invoke-CcodexReadCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultReadUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultReadUnknown.Message)) 'unknown job id returns a diagnostic message'

# --- shell-level: pwsh -File ccodex.ps1 read <id> --state-root ... ---

Write-Host "shell-level: ccodex.ps1 read <id> --state-root <root> on a running job -> exit 4, no result content"
$jobReadShellRunning = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
$shellReadRunningOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read $jobReadShellRunning.JobId --state-root $localAppData
$shellReadRunningExit = $LASTEXITCODE
Assert-Equal $shellReadRunningExit 4 'shell-level read on running job exits 4'
$shellReadRunningLines = @($shellReadRunningOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-True (-not (($shellReadRunningLines -join "`n") -like '*the result*')) 'shell-level read on running job prints no result content'

Write-Host "shell-level: ccodex.ps1 read <id> --state-root <root> prints result.md content, exit 0"
$jobReadShell = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -WithResultFile
$shellReadOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read $jobReadShell.JobId --state-root $localAppData
$shellReadExit = $LASTEXITCODE
Assert-Equal $shellReadExit 0 'shell-level read invocation exits 0'
$shellReadOutLines = @($shellReadOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-Equal $shellReadOutLines.Count 1 'shell-level read prints exactly one line'
Assert-Equal $shellReadOutLines[0] 'the result' 'shell-level read prints the result.md content'

# --- read: JSON lifecycle envelope ---

Write-Host "Invoke-CcodexReadCommand: --json success, unfinished, missing, and unknown envelopes"
$readDoneJsonResult = Invoke-CcodexReadCommand -JobId $jobReadDone.JobId -Json -StateRoot $localAppData
$readDoneJson = $readDoneJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $readDoneJson.schema_version 1 'read --json schema version is 1'
Assert-Equal $readDoneJson.finished $true 'read --json done is finished'
Assert-Equal $readDoneJson.result_present $true 'read --json done has result'
Assert-Equal $readDoneJson.result 'the result' 'read --json includes result content'
Assert-Equal $readDoneJson.command_exit_code 0 'read --json done command exit is 0'

$readRunningJsonResult = Invoke-CcodexReadCommand -JobId $jobReadRunning.JobId -Json -StateRoot $localAppData
$readRunningJson = $readRunningJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $readRunningJsonResult.WrapperExitCode 4 'read --json running preserves exit 4'
Assert-Equal $readRunningJson.finished $false 'read --json running is unfinished'
Assert-Equal $readRunningJson.result_present $false 'read --json running has no result'
Assert-True ($null -eq $readRunningJson.result) 'read --json running result is null'
Assert-Equal $readRunningJson.command_exit_code 4 'read --json running command exit is 4'

$readMissingJsonResult = Invoke-CcodexReadCommand -JobId $jobReadNoResult.JobId -Json -StateRoot $localAppData
$readMissingJson = $readMissingJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $readMissingJsonResult.WrapperExitCode 11 'read --json missing result preserves exit 11'
Assert-Equal $readMissingJson.finished $true 'read --json missing result is terminal'
Assert-Equal $readMissingJson.command_exit_code 11 'read --json missing result command exit is 11'

$readUnknownJsonResult = Invoke-CcodexReadCommand -JobId 'does-not-exist-json' -Json -StateRoot $localAppData
$readUnknownJson = $readUnknownJsonResult.Stdout | ConvertFrom-Json
Assert-Equal $readUnknownJsonResult.WrapperExitCode 3 'read --json unknown preserves exit 3'
Assert-Equal $readUnknownJson.status 'unknown' 'read --json unknown has unknown status'
Assert-Equal $readUnknownJson.command_exit_code 3 'read --json unknown command exit is 3'
Assert-True (-not [string]::IsNullOrEmpty($readUnknownJson.error)) 'read --json unknown includes error'

Write-Host "shell-level: read --json emits envelope on stdout for a nonzero exit"
$shellReadJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read $jobReadRunning.JobId --json --state-root $localAppData
$shellReadJsonExit = $LASTEXITCODE
$shellReadJson = ($shellReadJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellReadJsonExit 4 'shell-level read --json preserves unfinished exit 4'
Assert-Equal $shellReadJson.command_exit_code 4 'shell-level read --json emits nonzero envelope on stdout'

$shellReadDoneJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read $jobReadDone.JobId --json --state-root $localAppData
$shellReadDoneJsonExit = $LASTEXITCODE
$shellReadDoneJson = ($shellReadDoneJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellReadDoneJsonExit 0 'shell-level read --json done exits 0'
Assert-Equal $shellReadDoneJson.result 'the result' 'shell-level read --json done emits result'

$shellReadMissingJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read $jobReadNoResult.JobId --json --state-root $localAppData
$shellReadMissingJsonExit = $LASTEXITCODE
$shellReadMissingJson = ($shellReadMissingJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellReadMissingJsonExit 11 'shell-level read --json missing result exits 11'
Assert-Equal $shellReadMissingJson.command_exit_code 11 'shell-level read --json missing exit matches envelope'

$shellReadUnknownJsonOut = & pwsh -NoLogo -NoProfile -File $ccodexPs read does-not-exist-json --json --state-root $localAppData
$shellReadUnknownJsonExit = $LASTEXITCODE
$shellReadUnknownJson = ($shellReadUnknownJsonOut -join "`n") | ConvertFrom-Json
Assert-Equal $shellReadUnknownJsonExit 3 'shell-level read --json unknown exits 3'
Assert-True (-not [string]::IsNullOrEmpty($shellReadUnknownJson.error)) 'shell-level read --json unknown emits error envelope'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
