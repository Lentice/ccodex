# tests/Worker.tests.ps1
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-worker-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

function New-CcodexTestJob {
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$PromptContent = 'test worker prompt body',
        [int]$HardTimeoutSec = 0
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $PromptContent
    $statusParams = @{ JobId = $jobId; Status = 'created'; Mode = $Mode; Access = $Access; Repo = $targetRepo; CreatedAt = $createdAt }
    if ($HardTimeoutSec -gt 0) { $statusParams['HardTimeoutSec'] = $HardTimeoutSec }
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject @statusParams)
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

# --- (a) successful in-process worker run ---

Write-Host "Invoke-CcodexWorker: success path stamps native backend and reaches done"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'WORKER RESULT OK'
$jobA = New-CcodexTestJob
$resultA = Invoke-CcodexWorker -JobId $jobA.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultA.WrapperExitCode 0 'wrapper exit code is 0 on success'

$statusA = Get-Content -LiteralPath (Join-Path $jobA.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusA.status 'done' 'final status is done'
Assert-Equal $statusA.backend 'native' 'backend is stamped native'
Assert-True (-not [string]::IsNullOrEmpty($statusA.backend_id)) 'backend_id is set'
Assert-True (Test-CcodexWorkerAlive -BackendId $statusA.backend_id) 'backend_id matches the current (still-running) process'
Assert-True (-not [string]::IsNullOrEmpty($statusA.started_at)) 'started_at is set'
Assert-True (-not [string]::IsNullOrEmpty($statusA.finished_at)) 'finished_at is set'

$resultMdA = Get-Content -LiteralPath (Join-Path $jobA.JobDir 'result.md') -Raw
Assert-True ($resultMdA -like '*WORKER RESULT OK*') 'result.md carries the fixture result content'

# --- (b) fake codex exit 3 -> wrapper 10, terminal failed ---

Write-Host "Invoke-CcodexWorker: nonzero codex exit -> wrapper 10, status failed"
$env:CCODEX_FAKE_EXIT_CODE = '3'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$jobB = New-CcodexTestJob
$resultB = Invoke-CcodexWorker -JobId $jobB.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultB.WrapperExitCode 10 'wrapper exit code is 10 when codex exits nonzero'
$statusB = Get-Content -LiteralPath (Join-Path $jobB.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusB.status 'failed' 'final status is failed'
Assert-Equal $statusB.backend 'native' 'backend is stamped native on the failure path too'

# --- (b2) hard_timeout_sec in status.json -> worker kills the tree, wrapper 24, terminal timed_out ---

Write-Host "Invoke-CcodexWorker: hard_timeout_sec exceeded -> wrapper 24, status timed_out, no exit_code.txt"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_DELAY_MS = '8000'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$jobT = New-CcodexTestJob -HardTimeoutSec 1
$resultT = Invoke-CcodexWorker -JobId $jobT.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultT.WrapperExitCode 24 'worker exits 24 when hard_timeout_sec is exceeded'
$statusT = Get-Content -LiteralPath (Join-Path $jobT.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusT.status 'timed_out' 'worker reaches terminal timed_out status'
Assert-True ($null -eq $statusT.codex_exit_code) 'codex_exit_code stays null on a worker hard timeout'
Assert-Equal $statusT.wrapper_exit_code 24 'worker timeout records wrapper_exit_code 24'
Assert-True (-not [string]::IsNullOrEmpty($statusT.terminated_at)) 'worker timeout stamps terminated_at'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobT.JobDir 'exit_code.txt') -PathType Leaf)) 'no exit_code.txt on a worker hard timeout'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue

# --- (c) unknown job id -> wrapper 3 ---

Write-Host "Invoke-CcodexWorker: unknown job id -> wrapper 3"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$resultC = Invoke-CcodexWorker -JobId 'does-not-exist-12345' -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultC.WrapperExitCode 3 'wrapper exit code is 3 for an unknown job id'

# --- (d) shell-level: pwsh -File ccodex.ps1 worker --job-id ... ---

Write-Host "shell-level: ccodex.ps1 worker --job-id <id> --state-root <root> --codex-path <fixture>"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHELL WORKER OK'
$jobD = New-CcodexTestJob
& pwsh -NoLogo -NoProfile -File $ccodexPs worker --job-id $jobD.JobId --state-root $localAppData --codex-path $fixtureCmd
Assert-Equal $LASTEXITCODE 0 'shell-level worker invocation exits 0'
$statusD = Get-Content -LiteralPath (Join-Path $jobD.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusD.status 'done' 'shell-level worker reaches terminal done status'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# --- (e) Start-CcodexWorkerRunning: a job cancelled before the worker starts is not resurrected ---

Write-Host "Invoke-CcodexWorker: a job cancelled before the worker starts is NOT resurrected to running"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHOULD NOT RUN'
$jobCancelledFirst = New-CcodexTestJob
# Simulate a cancel that marked this never-started ('created') job 'cancelled' just before
# the worker got going: overwrite status.json to cancelled (preserving the other fields).
$preCancel = Read-CcodexStatusFile -JobDir $jobCancelledFirst.JobDir
$cancelledStatus = [ordered]@{}
foreach ($p in $preCancel.PSObject.Properties) { $cancelledStatus[$p.Name] = $p.Value }
$cancelledStatus['status'] = 'cancelled'
$cancelledStatus['cancelled_at'] = (Get-Date).ToUniversalTime().ToString('o')
Write-CcodexJsonFileAtomic -Path (Join-Path $jobCancelledFirst.JobDir 'status.json') -Object $cancelledStatus
$resultCancelledFirst = Invoke-CcodexWorker -JobId $jobCancelledFirst.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultCancelledFirst.WrapperExitCode 0 'worker exits 0 (cleanly) when the job was already cancelled'
$statusCancelledFirst = Read-CcodexStatusFile -JobDir $jobCancelledFirst.JobDir
Assert-Equal $statusCancelledFirst.status 'cancelled' 'worker leaves the cancelled status intact (no resurrection to running)'
Assert-True ([string]::IsNullOrEmpty($statusCancelledFirst.backend_id)) 'worker did not stamp its own backend_id over the cancelled job'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobCancelledFirst.JobDir 'result.md'))) 'worker did not run codex (no result.md produced)'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobCancelledFirst.JobDir '.lock'))) 'worker releases the lock after skipping a cancelled job'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# --- (e2) Start-CcodexWorkerRunning: an unreadable re-read under the lock is refused, not treated as `created` ---

Write-Host "Start-CcodexWorkerRunning: status.json missing/unreadable under the lock -> internal failure (exit 12), running never written"
$jobNullStatus = New-CcodexTestJob
$nullStatusPath = Join-Path $jobNullStatus.JobDir 'status.json'
# Simulate the re-read-under-the-lock coming back null (a mid-write/corrupt/vanished file)
# by removing status.json entirely right before calling the function under test directly --
# this isolates Start-CcodexWorkerRunning's OWN re-read from Invoke-CcodexWorker's earlier
# (unrelated) initial read, which would otherwise short-circuit first.
Remove-Item -LiteralPath $nullStatusPath -Force
$nullRunningObj = New-CcodexStatusObject -JobId $jobNullStatus.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId 'should-not-be-written;2026-01-01T00:00:00.0000000Z' -StartedAt ((Get-Date).ToString('o'))
$startResultNull = Start-CcodexWorkerRunning -JobDir $jobNullStatus.JobDir -StatusPath $nullStatusPath -JobId $jobNullStatus.JobId -RunningStatusObject $nullRunningObj
Assert-Equal $startResultNull.Proceed $false 'Start-CcodexWorkerRunning refuses to proceed when the re-read under the lock is null'
Assert-Equal $startResultNull.WrapperExitCode 12 'an unreadable status.json under the lock is an internal failure (exit 12), not permission to run'
Assert-True (-not [string]::IsNullOrEmpty($startResultNull.Message)) 'the internal-failure result carries a diagnostic message'
Assert-True (-not (Test-Path -LiteralPath $nullStatusPath -PathType Leaf)) 'status.json was NOT (re)written as running over the unknown/missing state'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobNullStatus.JobDir '.lock'))) 'the per-job lock is released after the internal-failure path'

# --- (e3) Write-CcodexStatusUnderLock: RequireStatus/RequireBackendId guard the terminal write ---

Write-Host "Write-CcodexStatusUnderLock: RequireStatus mismatch (status already moved off 'running') -> write skipped, on-disk status preserved"
$jobGuardCancelled = New-CcodexTestJob
$guardStatusPath = Join-Path $jobGuardCancelled.JobDir 'status.json'
$guardBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime (Get-Process -Id $PID).StartTime
$guardRunning = New-CcodexStatusObject -JobId $jobGuardCancelled.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $guardBackendId -StartedAt ((Get-Date).ToString('o'))
Write-CcodexJsonFileAtomic -Path $guardStatusPath -Object $guardRunning
# A concurrent cancel lands between this run's own running-write and its terminal write.
$guardCancelObj = [ordered]@{}
foreach ($p in (Read-CcodexStatusFile -JobDir $jobGuardCancelled.JobDir).PSObject.Properties) { $guardCancelObj[$p.Name] = $p.Value }
$guardCancelObj['status'] = 'cancelled'
$guardCancelObj['cancelled_at'] = (Get-Date).ToUniversalTime().ToString('o')
Write-CcodexJsonFileAtomic -Path $guardStatusPath -Object $guardCancelObj
$guardTerminalObj = New-CcodexStatusObject -JobId $jobGuardCancelled.JobId -Status 'done' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $guardBackendId -StartedAt ((Get-Date).ToString('o')) -FinishedAt ((Get-Date).ToString('o')) -CodexExitCode 0 -WrapperExitCode 0
$guardResult = Write-CcodexStatusUnderLock -JobDir $jobGuardCancelled.JobDir -StatusPath $guardStatusPath -StatusObject $guardTerminalObj -RequireStatus 'running' -RequireBackendId $guardBackendId
Assert-Equal $guardResult.LockAcquired $true 'the guarded write still acquires the lock even when it ends up skipping the write'
Assert-Equal $guardResult.Written $false 'the terminal write is skipped when the on-disk status already moved off running'
Assert-Equal $guardResult.CurrentStatus.status 'cancelled' 'the returned CurrentStatus reflects what is actually on disk'
$afterGuardCancelled = Read-CcodexStatusFile -JobDir $jobGuardCancelled.JobDir
Assert-Equal $afterGuardCancelled.status 'cancelled' 'status.json on disk still reads cancelled -- the done write never landed'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobGuardCancelled.JobDir '.lock'))) 'the lock is released even when the guarded write is skipped'

Write-Host "Write-CcodexStatusUnderLock: RequireStatus match (still running under the same backend) -> write happens normally"
$jobGuardMatch = New-CcodexTestJob
$guardMatchStatusPath = Join-Path $jobGuardMatch.JobDir 'status.json'
$guardMatchRunning = New-CcodexStatusObject -JobId $jobGuardMatch.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $guardBackendId -StartedAt ((Get-Date).ToString('o'))
Write-CcodexJsonFileAtomic -Path $guardMatchStatusPath -Object $guardMatchRunning
$guardMatchTerminalObj = New-CcodexStatusObject -JobId $jobGuardMatch.JobId -Status 'done' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $guardBackendId -StartedAt ((Get-Date).ToString('o')) -FinishedAt ((Get-Date).ToString('o')) -CodexExitCode 0 -WrapperExitCode 0
$guardMatchResult = Write-CcodexStatusUnderLock -JobDir $jobGuardMatch.JobDir -StatusPath $guardMatchStatusPath -StatusObject $guardMatchTerminalObj -RequireStatus 'running' -RequireBackendId $guardBackendId
Assert-Equal $guardMatchResult.LockAcquired $true 'the guarded write acquires the lock'
Assert-Equal $guardMatchResult.Written $true 'the terminal write happens when the on-disk status still matches the guard'
$afterGuardMatch = Read-CcodexStatusFile -JobDir $jobGuardMatch.JobDir
Assert-Equal $afterGuardMatch.status 'done' 'status.json on disk now reads done -- the guarded write landed'

# --- (e4) Invoke-CcodexJobExecution: a skipped terminal write must route non-terminal
#          guard mismatches to internal failure (exit 12), never to a fabricated
#          success/unknown result. Both scenarios shadow Read-CcodexStatusFile so the
#          RE-READ INSIDE THE LOCK (Write-CcodexStatusUnderLock's guard) sees a different
#          value than what is actually on disk -- the same technique
#          tests/JobStatus.tests.ps1 uses for its own re-read-guard test -- without needing
#          real concurrency. The real on-disk status.json (read via plain Get-Content, never
#          through the shadowed function) is what the assertions below check.

Write-Host "Invoke-CcodexJobExecution: re-read under the lock is `$null during the terminal write -> exit 12, no success/unknown fabricated"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHOULD NOT BE REPORTED AS SUCCESS'
$jobNullReRead = New-CcodexTestJob
$nullReReadBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime (Get-Process -Id $PID).StartTime
function Read-CcodexStatusFile {
    param([Parameter(Mandatory)][string]$JobDir)
    return $null
}
$nullReReadResult = Invoke-CcodexJobExecution -JobDir $jobNullReRead.JobDir -RepoRoot $targetRepo -Mode 'review' -Access 'read-only' `
    -WorkerPrompt 'test worker prompt body' -CodexPath $fixtureCmd -CreatedAt ((Get-Date).ToString('o')) `
    -Backend 'native' -BackendId $nullReReadBackendId -StartedAt ((Get-Date).ToString('o'))
# Restore the real Read-CcodexStatusFile immediately so every assertion below (and every
# later test in this file) sees real disk state again.
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
Assert-Equal $nullReReadResult.WrapperExitCode 12 'a $null re-read during the terminal write is an internal failure (exit 12), not success'
Assert-Equal $nullReReadResult.Status 'failed' 'the internal-failure result reports status failed'
Assert-True (-not [string]::IsNullOrEmpty($nullReReadResult.Message)) 'the internal-failure result carries a diagnostic message'
$statusNullReRead = Get-Content -LiteralPath (Join-Path $jobNullReRead.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusNullReRead.status 'failed' 'status.json is left with an honest failed status, not a fabricated done/unknown one'
Assert-Equal $statusNullReRead.wrapper_exit_code 12 'status.json records wrapper_exit_code 12 for the unreadable-re-read case'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobNullReRead.JobDir '.lock'))) 'the per-job lock is released after the internal-failure path'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

Write-Host "Invoke-CcodexJobExecution: re-read under the lock shows running with a DIFFERENT backend_id during the terminal write -> exit 12, on-disk status untouched"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHOULD NOT BE REPORTED AS SUCCESS EITHER'
$jobForeignBackend = New-CcodexTestJob
$foreignTestOwnBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime (Get-Process -Id $PID).StartTime
$foreignTestOtherBackendId = '999999;2020-06-15T00:00:00.0000000Z'
function Read-CcodexStatusFile {
    param([Parameter(Mandatory)][string]$JobDir)
    return [pscustomobject]@{ status = 'running'; backend_id = $foreignTestOtherBackendId; wrapper_exit_code = $null }
}
$foreignBackendResult = Invoke-CcodexJobExecution -JobDir $jobForeignBackend.JobDir -RepoRoot $targetRepo -Mode 'review' -Access 'read-only' `
    -WorkerPrompt 'test worker prompt body' -CodexPath $fixtureCmd -CreatedAt ((Get-Date).ToString('o')) `
    -Backend 'native' -BackendId $foreignTestOwnBackendId -StartedAt ((Get-Date).ToString('o'))
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
Assert-Equal $foreignBackendResult.WrapperExitCode 12 'a foreign (mismatched-backend_id) running status during the terminal write is an internal failure (exit 12), not success'
Assert-Equal $foreignBackendResult.Status 'failed' 'the foreign-status result reports status failed to its own caller'
Assert-True (-not [string]::IsNullOrEmpty($foreignBackendResult.Message)) 'the foreign-status result carries a diagnostic message'
$statusForeignBackend = Get-Content -LiteralPath (Join-Path $jobForeignBackend.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusForeignBackend.status 'running' 'status.json on disk is untouched -- still the real running write, not clobbered to failed/done'
Assert-Equal $statusForeignBackend.backend_id $foreignTestOwnBackendId "status.json on disk still carries this run's own backend_id (the real running-write), unaffected by the shadowed foreign re-read"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobForeignBackend.JobDir '.lock'))) 'the per-job lock is released after the foreign-status path'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# --- (f) Update-CcodexHeartbeat: never resurrects a status a concurrent writer changed ---

$hbBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime (Get-Process -Id $PID).StartTime

Write-Host "Update-CcodexHeartbeat: stamps last_heartbeat_at on a still-running job under the same backend"
$jobHbOk = New-CcodexTestJob
$hbOkStatusPath = Join-Path $jobHbOk.JobDir 'status.json'
$hbOkRunning = New-CcodexStatusObject -JobId $jobHbOk.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $hbBackendId -StartedAt ((Get-Date).ToString('o'))
Write-CcodexJsonFileAtomic -Path $hbOkStatusPath -Object $hbOkRunning
Update-CcodexHeartbeat -JobDir $jobHbOk.JobDir -StatusPath $hbOkStatusPath -BackendId $hbBackendId
$afterHbOk = Read-CcodexStatusFile -JobDir $jobHbOk.JobDir
Assert-Equal $afterHbOk.status 'running' 'heartbeat keeps a running job running'
Assert-True (-not [string]::IsNullOrEmpty($afterHbOk.last_heartbeat_at)) 'heartbeat stamps last_heartbeat_at on a running job under the same backend'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobHbOk.JobDir '.lock'))) 'heartbeat releases the lock afterward'

Write-Host "Update-CcodexHeartbeat: does NOT resurrect a job a concurrent cancel moved to cancelled"
$jobHbCancelled = New-CcodexTestJob
$hbCancelledStatusPath = Join-Path $jobHbCancelled.JobDir 'status.json'
$hbCancelledRunning = New-CcodexStatusObject -JobId $jobHbCancelled.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $hbBackendId -StartedAt ((Get-Date).ToString('o'))
Write-CcodexJsonFileAtomic -Path $hbCancelledStatusPath -Object $hbCancelledRunning
# A concurrent cancel writes 'cancelled' between the worker's snapshot and its heartbeat.
$hbCancelObj = [ordered]@{}
foreach ($p in (Read-CcodexStatusFile -JobDir $jobHbCancelled.JobDir).PSObject.Properties) { $hbCancelObj[$p.Name] = $p.Value }
$hbCancelObj['status'] = 'cancelled'
$hbCancelObj['cancelled_at'] = (Get-Date).ToUniversalTime().ToString('o')
Write-CcodexJsonFileAtomic -Path $hbCancelledStatusPath -Object $hbCancelObj
Update-CcodexHeartbeat -JobDir $jobHbCancelled.JobDir -StatusPath $hbCancelledStatusPath -BackendId $hbBackendId
$afterHbCancelled = Read-CcodexStatusFile -JobDir $jobHbCancelled.JobDir
Assert-Equal $afterHbCancelled.status 'cancelled' 'heartbeat does not resurrect a cancelled job back to running'
Assert-True ([string]::IsNullOrEmpty($afterHbCancelled.last_heartbeat_at)) 'heartbeat skips the write entirely on a non-running (cancelled) job (no last_heartbeat_at stamped)'

Write-Host "Update-CcodexHeartbeat: does NOT stamp when backend_id no longer matches (a new backend took over)"
$jobHbMismatch = New-CcodexTestJob
$hbMismatchStatusPath = Join-Path $jobHbMismatch.JobDir 'status.json'
$otherBackendId = '424242;2020-01-01T00:00:00.0000000Z'
$hbMismatchRunning = New-CcodexStatusObject -JobId $jobHbMismatch.JobId -Status 'running' -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'native' -BackendId $otherBackendId -StartedAt ((Get-Date).ToString('o'))
Write-CcodexJsonFileAtomic -Path $hbMismatchStatusPath -Object $hbMismatchRunning
Update-CcodexHeartbeat -JobDir $jobHbMismatch.JobDir -StatusPath $hbMismatchStatusPath -BackendId $hbBackendId
$afterHbMismatch = Read-CcodexStatusFile -JobDir $jobHbMismatch.JobDir
Assert-True ([string]::IsNullOrEmpty($afterHbMismatch.last_heartbeat_at)) 'heartbeat does not stamp a job whose backend_id no longer matches'
Assert-Equal $afterHbMismatch.backend_id $otherBackendId 'heartbeat leaves the other backend_id untouched'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
