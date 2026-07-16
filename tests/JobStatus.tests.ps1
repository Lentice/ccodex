# tests/JobStatus.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\lib\FailureClassify.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobstatus-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-TestJobDir {
    param([string]$Name)
    $dir = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-TestStatusObject {
    param(
        [string]$JobId = 'job1',
        [string]$Status = 'running',
        [string]$BackendId = $null
    )
    return [ordered]@{
        schema_version    = 1
        ccodex_version    = '0.1.0'
        job_id            = $JobId
        status            = $Status
        mode              = 'review'
        access            = 'read-only'
        backend           = 'background'
        backend_id        = $BackendId
        repo              = 'D:\Repo'
        created_at        = '2026-07-03T00:00:00Z'
        started_at        = '2026-07-03T00:00:01Z'
        finished_at        = $null
        codex_exit_code   = $null
        wrapper_exit_code = $null
        error             = $null
    }
}

# --- Read-CcodexStatusFile ---

Write-Host "Read-CcodexStatusFile reads an existing status.json"
$dir1 = New-TestJobDir 'read-ok'
Write-CcodexJsonFileAtomic -Path (Join-Path $dir1 'status.json') -Object (New-TestStatusObject)
$read1 = Read-CcodexStatusFile -JobDir $dir1
Assert-True ($null -ne $read1) 'reads status.json when present'
Assert-Equal $read1.job_id 'job1' 'round-trips job_id'

Write-Host "Read-CcodexStatusFile returns null after retries when file is missing"
$dir2 = New-TestJobDir 'read-missing'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$read2 = Read-CcodexStatusFile -JobDir $dir2
$sw.Stop()
Assert-Equal $read2 $null 'returns null when status.json never appears'
Assert-True ($sw.ElapsedMilliseconds -ge 150) 'retried across the 100ms x 3 attempt window'

Write-Host "Read-CcodexStatusFile returns null on unparseable JSON after retries"
$dir3 = New-TestJobDir 'read-corrupt'
Write-CcodexTextFile -Path (Join-Path $dir3 'status.json') -Content '{ not valid json'
$read3 = Read-CcodexStatusFile -JobDir $dir3
Assert-Equal $read3 $null 'returns null when status.json is unparseable'

# --- ConvertTo-CcodexBackendId ---

Write-Host "ConvertTo-CcodexBackendId formats pid + UTC start time as ISO 'o'"
$fixedTime = [DateTime]::Parse('2026-07-03T15:30:13+08:00')
$backendId = ConvertTo-CcodexBackendId -ProcessId 4242 -StartTime $fixedTime
Assert-Equal $backendId "4242;$($fixedTime.ToUniversalTime().ToString('o'))" 'formats as <pid>;<UTC start time o>'

# --- Test-CcodexWorkerAlive ---

Write-Host "Test-CcodexWorkerAlive: null/empty/unparseable backend id -> false"
Assert-Equal (Test-CcodexWorkerAlive -BackendId $null) $false 'null backend id is not alive'
Assert-Equal (Test-CcodexWorkerAlive -BackendId '') $false 'empty backend id is not alive'
Assert-Equal (Test-CcodexWorkerAlive -BackendId 'not-a-backend-id') $false 'unparseable backend id is not alive'

Write-Host "Test-CcodexWorkerAlive: fabricated dead pid/time -> false"
Assert-Equal (Test-CcodexWorkerAlive -BackendId '999999;2020-01-01T00:00:00.0000000Z') $false 'dead/nonexistent pid is not alive'

Write-Host "Test-CcodexWorkerAlive: current process pid + real start time -> true"
$currentProc = Get-Process -Id $PID
$aliveBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime $currentProc.StartTime
Assert-Equal (Test-CcodexWorkerAlive -BackendId $aliveBackendId) $true 'current process with correct start time is alive'

Write-Host "Test-CcodexWorkerAlive: current process pid but mismatched start time -> false"
$wrongBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime ([DateTime]::Parse('2000-01-01T00:00:00Z'))
Assert-Equal (Test-CcodexWorkerAlive -BackendId $wrongBackendId) $false 'pid alive but start time mismatch (pid reuse) is not alive'

# --- Update-CcodexOrphanStatus ---

$fabricatedDeadBackendId = '999999;2020-01-01T00:00:00.0000000Z'

Write-Host "Update-CcodexOrphanStatus: missing status.json"
$dirMissing = New-TestJobDir 'orphan-missing-status'
$resultMissing = Update-CcodexOrphanStatus -JobDir $dirMissing
Assert-Equal $resultMissing.Status $null 'missing status.json -> Status null'
Assert-Equal $resultMissing.Reconciled $false 'missing status.json -> not reconciled'
Assert-Equal $resultMissing.PossiblyStale $true 'missing status.json -> possibly stale'

Write-Host "Update-CcodexOrphanStatus: status is not running -> pass through, no write"
$dirDone = New-TestJobDir 'orphan-done'
$doneStatus = New-TestStatusObject -Status 'done'
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDone 'status.json') -Object $doneStatus
$beforeWrite = (Get-Item (Join-Path $dirDone 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDone = Update-CcodexOrphanStatus -JobDir $dirDone
Assert-Equal $resultDone.Status 'done' 'non-running status passes through'
Assert-Equal $resultDone.Reconciled $false 'non-running status is not reconciled'
Assert-Equal $resultDone.PossiblyStale $false 'non-running status is not possibly stale'
$afterWrite = (Get-Item (Join-Path $dirDone 'status.json')).LastWriteTimeUtc
Assert-Equal $afterWrite $beforeWrite 'non-running status.json was not rewritten'

Write-Host "Update-CcodexOrphanStatus: running + worker alive -> no write"
$dirAlive = New-TestJobDir 'orphan-alive'
$aliveStatus = New-TestStatusObject -Status 'running' -BackendId $aliveBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirAlive 'status.json') -Object $aliveStatus
$beforeAlive = (Get-Item (Join-Path $dirAlive 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultAlive = Update-CcodexOrphanStatus -JobDir $dirAlive
Assert-Equal $resultAlive.Status 'running' 'alive worker keeps running status'
Assert-Equal $resultAlive.Reconciled $false 'alive worker is not reconciled'
Assert-Equal $resultAlive.PossiblyStale $false 'alive worker is not possibly stale'
$afterAlive = (Get-Item (Join-Path $dirAlive 'status.json')).LastWriteTimeUtc
Assert-Equal $afterAlive $beforeAlive 'alive worker status.json was not rewritten'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + no exit_code.txt -> no write, possibly stale"
$dirDeadNoEvidence = New-TestJobDir 'orphan-dead-no-evidence'
$deadNoEvidenceStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadNoEvidence 'status.json') -Object $deadNoEvidenceStatus
$beforeDeadNoEvidence = (Get-Item (Join-Path $dirDeadNoEvidence 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadNoEvidence = Update-CcodexOrphanStatus -JobDir $dirDeadNoEvidence
Assert-Equal $resultDeadNoEvidence.Status 'running' 'dead worker w/o evidence keeps running status'
Assert-Equal $resultDeadNoEvidence.Reconciled $false 'dead worker w/o evidence is not reconciled'
Assert-Equal $resultDeadNoEvidence.PossiblyStale $true 'dead worker w/o evidence is possibly stale'
$afterDeadNoEvidence = (Get-Item (Join-Path $dirDeadNoEvidence 'status.json')).LastWriteTimeUtc
Assert-Equal $afterDeadNoEvidence $beforeDeadNoEvidence 'dead worker w/o evidence status.json was not rewritten'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + empty exit_code.txt -> no write, possibly stale, no throw"
$dirDeadEmptyEvidence = New-TestJobDir 'orphan-dead-empty-evidence'
$deadEmptyEvidenceStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadEmptyEvidence 'status.json') -Object $deadEmptyEvidenceStatus
Write-CcodexTextFile -Path (Join-Path $dirDeadEmptyEvidence 'exit_code.txt') -Content ''
$beforeDeadEmptyEvidence = (Get-Item (Join-Path $dirDeadEmptyEvidence 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadEmptyEvidence = $null
try {
    $resultDeadEmptyEvidence = Update-CcodexOrphanStatus -JobDir $dirDeadEmptyEvidence
    Assert-True $true 'empty exit_code.txt does not throw'
} catch {
    Assert-True $false "empty exit_code.txt unexpectedly threw: $($_.Exception.Message)"
}
Assert-Equal $resultDeadEmptyEvidence.Status 'running' 'dead worker w/ empty exit_code.txt keeps running status'
Assert-Equal $resultDeadEmptyEvidence.Reconciled $false 'dead worker w/ empty exit_code.txt is not reconciled'
Assert-Equal $resultDeadEmptyEvidence.PossiblyStale $true 'dead worker w/ empty exit_code.txt is possibly stale'
$afterDeadEmptyEvidence = (Get-Item (Join-Path $dirDeadEmptyEvidence 'status.json')).LastWriteTimeUtc
Assert-Equal $afterDeadEmptyEvidence $beforeDeadEmptyEvidence 'dead worker w/ empty exit_code.txt status.json was not rewritten'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + corrupt (non-numeric) exit_code.txt -> no write, possibly stale, no throw"
$dirDeadCorruptEvidence = New-TestJobDir 'orphan-dead-corrupt-evidence'
$deadCorruptEvidenceStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadCorruptEvidence 'status.json') -Object $deadCorruptEvidenceStatus
Write-CcodexTextFile -Path (Join-Path $dirDeadCorruptEvidence 'exit_code.txt') -Content "0`0garbled"
$beforeDeadCorruptEvidence = (Get-Item (Join-Path $dirDeadCorruptEvidence 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadCorruptEvidence = $null
try {
    $resultDeadCorruptEvidence = Update-CcodexOrphanStatus -JobDir $dirDeadCorruptEvidence
    Assert-True $true 'corrupt exit_code.txt does not throw'
} catch {
    Assert-True $false "corrupt exit_code.txt unexpectedly threw: $($_.Exception.Message)"
}
Assert-Equal $resultDeadCorruptEvidence.Status 'running' 'dead worker w/ corrupt exit_code.txt keeps running status'
Assert-Equal $resultDeadCorruptEvidence.Reconciled $false 'dead worker w/ corrupt exit_code.txt is not reconciled'
Assert-Equal $resultDeadCorruptEvidence.PossiblyStale $true 'dead worker w/ corrupt exit_code.txt is possibly stale'
$afterDeadCorruptEvidence = (Get-Item (Join-Path $dirDeadCorruptEvidence 'status.json')).LastWriteTimeUtc
Assert-Equal $afterDeadCorruptEvidence $beforeDeadCorruptEvidence 'dead worker w/ corrupt exit_code.txt status.json was not rewritten'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + exit_code.txt=0 + result.md -> reconcile to done"
$dirDeadSuccess = New-TestJobDir 'orphan-dead-success'
$deadSuccessStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadSuccess 'status.json') -Object $deadSuccessStatus
Write-CcodexTextFile -Path (Join-Path $dirDeadSuccess 'exit_code.txt') -Content '0'
Write-CcodexTextFile -Path (Join-Path $dirDeadSuccess 'result.md') -Content 'the result'
$resultDeadSuccess = Update-CcodexOrphanStatus -JobDir $dirDeadSuccess
Assert-Equal $resultDeadSuccess.Status 'done' 'dead worker w/ success evidence reconciles to done'
Assert-Equal $resultDeadSuccess.Reconciled $true 'dead worker w/ success evidence is reconciled'
Assert-Equal $resultDeadSuccess.PossiblyStale $false 'reconciled done is not possibly stale'
$rewrittenSuccess = Get-Content -LiteralPath (Join-Path $dirDeadSuccess 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $rewrittenSuccess.status 'done' 'rewritten status.json status is done'
Assert-Equal $rewrittenSuccess.codex_exit_code 0 'rewritten status.json codex_exit_code is 0'
Assert-Equal $rewrittenSuccess.wrapper_exit_code 0 'rewritten status.json wrapper_exit_code is 0'
Assert-True ($null -ne $rewrittenSuccess.finished_at) 'rewritten status.json has finished_at set'
Assert-Equal $rewrittenSuccess.error $null 'rewritten status.json error is null for success'
Assert-Equal $rewrittenSuccess.job_id 'job1' 'rewritten status.json preserves job_id'
Assert-Equal $rewrittenSuccess.mode 'review' 'rewritten status.json preserves mode'
Assert-Equal $rewrittenSuccess.access 'read-only' 'rewritten status.json preserves access'
Assert-Equal $rewrittenSuccess.repo 'D:\Repo' 'rewritten status.json preserves repo'
Assert-Equal $rewrittenSuccess.failure_reason $null 'rewritten status.json failure_reason stays null on a successful reconciliation'
Assert-True ($rewrittenSuccess.PSObject.Properties.Name -contains 'failure') 'successful reconciliation includes the failure key'
Assert-Equal $rewrittenSuccess.failure $null 'successful reconciliation keeps failure null'
Assert-Equal $rewrittenSuccess.codex_thread_id $null 'rewritten status.json codex_thread_id is null when no codex-events.jsonl is present'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + exit_code.txt nonzero -> reconcile to failed with error"
$dirDeadFailed = New-TestJobDir 'orphan-dead-failed'
$deadFailedStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadFailed 'status.json') -Object $deadFailedStatus
Write-CcodexTextFile -Path (Join-Path $dirDeadFailed 'exit_code.txt') -Content '1'
$resultDeadFailed = Update-CcodexOrphanStatus -JobDir $dirDeadFailed
Assert-Equal $resultDeadFailed.Status 'failed' 'dead worker w/ failure evidence reconciles to failed'
Assert-Equal $resultDeadFailed.Reconciled $true 'dead worker w/ failure evidence is reconciled'
Assert-Equal $resultDeadFailed.PossiblyStale $false 'reconciled failed is not possibly stale'
$rewrittenFailed = Get-Content -LiteralPath (Join-Path $dirDeadFailed 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $rewrittenFailed.status 'failed' 'rewritten status.json status is failed'
Assert-Equal $rewrittenFailed.codex_exit_code 1 'rewritten status.json codex_exit_code is 1'
Assert-Equal $rewrittenFailed.wrapper_exit_code 10 'rewritten status.json wrapper_exit_code is 10'
Assert-Equal $rewrittenFailed.error 'worker process exited; state reconciled from completion evidence' 'rewritten status.json carries reconciliation error message'
Assert-Equal $rewrittenFailed.job_id 'job1' 'rewritten status.json preserves job_id on failure path'
Assert-Equal $rewrittenFailed.mode 'review' 'rewritten status.json preserves mode on failure path'
Assert-Equal $rewrittenFailed.access 'read-only' 'rewritten status.json preserves access on failure path'
Assert-Equal $rewrittenFailed.repo 'D:\Repo' 'rewritten status.json preserves repo on failure path'
Assert-Equal $rewrittenFailed.failure_reason $null 'rewritten status.json failure_reason stays null when no stderr/events evidence carries a signature'
Assert-Equal $rewrittenFailed.failure $null 'rewritten status.json failure stays null when no signature is present'
Assert-Equal $rewrittenFailed.codex_thread_id $null 'rewritten status.json codex_thread_id is null when no codex-events.jsonl is present'

Write-Host "Update-CcodexOrphanStatus: running + worker dead + failure evidence + stderr/events signatures -> reconciled status carries failure_reason and codex_thread_id"
$dirDeadEvidenceSignals = New-TestJobDir 'orphan-dead-evidence-signals'
$deadEvidenceSignalsStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirDeadEvidenceSignals 'status.json') -Object $deadEvidenceSignalsStatus
Write-CcodexTextFile -Path (Join-Path $dirDeadEvidenceSignals 'exit_code.txt') -Content '1'
Write-CcodexTextFile -Path (Join-Path $dirDeadEvidenceSignals 'stderr.log') -Content 'Rate limit exceeded (HTTP 429)'
Write-CcodexTextFile -Path (Join-Path $dirDeadEvidenceSignals 'codex-events.jsonl') -Content "{`"type`":`"thread.started`",`"thread_id`":`"thread-evidence-999`"}`n{`"type`":`"event`",`"msg`":`"other`"}"
$resultDeadEvidenceSignals = Update-CcodexOrphanStatus -JobDir $dirDeadEvidenceSignals
Assert-Equal $resultDeadEvidenceSignals.Status 'failed' 'dead worker w/ failure evidence + signatures reconciles to failed'
Assert-Equal $resultDeadEvidenceSignals.Reconciled $true 'dead worker w/ failure evidence + signatures is reconciled'
Assert-Equal $resultDeadEvidenceSignals.PossiblyStale $false 'reconciled failed w/ signatures is not possibly stale'
$rewrittenEvidenceSignals = Get-Content -LiteralPath (Join-Path $dirDeadEvidenceSignals 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $rewrittenEvidenceSignals.status 'failed' 'rewritten status.json status is failed (evidence + signatures)'
Assert-Equal $rewrittenEvidenceSignals.failure_reason 'quota_or_rate_limit' 'rewritten status.json carries failure_reason derived from the stderr.log signature'
Assert-Equal $rewrittenEvidenceSignals.failure.reason 'quota_or_rate_limit' 'rewritten status.json carries structured failure reason'
Assert-Equal $rewrittenEvidenceSignals.failure.matched_signal 'rate limit' 'reconciled failure records the winning signal'
Assert-Equal $rewrittenEvidenceSignals.failure.source 'stderr' 'reconciled failure records its source'
Assert-Equal $rewrittenEvidenceSignals.failure.confidence 'high' 'reconciled failure records confidence'
Assert-Equal $rewrittenEvidenceSignals.failure.http_code 429 'reconciled failure extracts the contextual code'
Assert-Equal $rewrittenEvidenceSignals.codex_thread_id 'thread-evidence-999' 'rewritten status.json carries codex_thread_id derived from codex-events.jsonl'
$secondEvidenceReconcile = Update-CcodexOrphanStatus -JobDir $dirDeadEvidenceSignals
Assert-Equal $secondEvidenceReconcile.Reconciled $false 'second reconciliation leaves an already-terminal job untouched'
$secondEvidenceStatus = Get-Content -LiteralPath (Join-Path $dirDeadEvidenceSignals 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $secondEvidenceStatus.failure_reason 'quota_or_rate_limit' 'second reconciliation preserves failure_reason'
Assert-Equal $secondEvidenceStatus.failure.matched_signal 'rate limit' 'second reconciliation preserves structured failure'

# --- Update-CcodexOrphanStatus: writer re-routing through the per-job lock ---

Write-Host "Update-CcodexOrphanStatus: reconciliation still works under the lock and releases it afterward"
$dirLockReconcile = New-TestJobDir 'orphan-lock-reconcile'
$lockReconcileStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirLockReconcile 'status.json') -Object $lockReconcileStatus
Write-CcodexTextFile -Path (Join-Path $dirLockReconcile 'exit_code.txt') -Content '0'
Write-CcodexTextFile -Path (Join-Path $dirLockReconcile 'result.md') -Content 'the result'
$resultLockReconcile = Update-CcodexOrphanStatus -JobDir $dirLockReconcile
Assert-Equal $resultLockReconcile.Status 'done' 'reconciliation under the lock still reconciles to done'
Assert-Equal $resultLockReconcile.Reconciled $true 'reconciliation under the lock is reconciled'
Assert-Equal $resultLockReconcile.PossiblyStale $false 'reconciliation under the lock is not possibly stale'
$rewrittenLockReconcile = Get-Content -LiteralPath (Join-Path $dirLockReconcile 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $rewrittenLockReconcile.status 'done' 'rewritten status.json status is done after locked reconcile'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $dirLockReconcile '.lock'))) 'the per-job lock is released after reconciliation'

Write-Host "Update-CcodexOrphanStatus: a held lock makes reconciliation skip with PossiblyStale rather than throw"
$dirLockHeld = New-TestJobDir 'orphan-lock-held'
$lockHeldStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirLockHeld 'status.json') -Object $lockHeldStatus
Write-CcodexTextFile -Path (Join-Path $dirLockHeld 'exit_code.txt') -Content '0'
Write-CcodexTextFile -Path (Join-Path $dirLockHeld 'result.md') -Content 'the result'
# Hold the lock (owned by this live process, so it is never treated as stale), then
# reconcile with a short timeout: it must not block indefinitely, must not throw, and
# must report the job as possibly-stale while leaving status.json untouched.
Lock-CcodexJob -JobDir $dirLockHeld -CommandName 'test-holder' | Out-Null
$beforeLockHeld = (Get-Item (Join-Path $dirLockHeld 'status.json')).LastWriteTimeUtc
$resultLockHeld = $null
try {
    $resultLockHeld = Update-CcodexOrphanStatus -JobDir $dirLockHeld -LockTimeoutSec 1
    Assert-True $true 'reconciliation with a held lock does not throw'
} catch {
    Assert-True $false "reconciliation with a held lock unexpectedly threw: $($_.Exception.Message)"
}
Assert-Equal $resultLockHeld.Status 'running' 'held-lock reconciliation reports the unchanged running status'
Assert-Equal $resultLockHeld.Reconciled $false 'held-lock reconciliation does not reconcile'
Assert-Equal $resultLockHeld.PossiblyStale $true 'held-lock reconciliation reports possibly-stale'
$afterLockHeld = (Get-Item (Join-Path $dirLockHeld 'status.json')).LastWriteTimeUtc
Assert-Equal $afterLockHeld $beforeLockHeld 'held-lock reconciliation did not rewrite status.json'
Unlock-CcodexJob -JobDir $dirLockHeld

Write-Host "Update-CcodexOrphanStatus: aborts the rewrite when status changes under the lock (re-read guard)"
$dirReReadGuard = New-TestJobDir 'orphan-reread-guard'
$reReadStatus = New-TestStatusObject -Status 'running' -BackendId $fabricatedDeadBackendId
Write-CcodexJsonFileAtomic -Path (Join-Path $dirReReadGuard 'status.json') -Object $reReadStatus
Write-CcodexTextFile -Path (Join-Path $dirReReadGuard 'exit_code.txt') -Content '0'
Write-CcodexTextFile -Path (Join-Path $dirReReadGuard 'result.md') -Content 'the result'
# Simulate a concurrent writer (cancel/terminal/reconcile) moving the job to `cancelled`
# in the window between reconcile's pre-lock read and its post-lock re-read: shadow
# Read-CcodexStatusFile so the 1st call (pre-lock) still reports the running snapshot the
# verdict was computed from, while the 2nd call (the re-read under the lock) reports the
# newer cancelled status. The guard must then abort the rewrite rather than clobber it.
$script:reReadCallCount = 0
$script:reReadOriginalJson = Get-Content -LiteralPath (Join-Path $dirReReadGuard 'status.json') -Raw
function Read-CcodexStatusFile {
    param([Parameter(Mandatory)][string]$JobDir)
    $script:reReadCallCount++
    $obj = $script:reReadOriginalJson | ConvertFrom-Json
    if ($script:reReadCallCount -ge 2) { $obj.status = 'cancelled' }
    return $obj
}
$resultReReadGuard = Update-CcodexOrphanStatus -JobDir $dirReReadGuard
Assert-Equal $resultReReadGuard.Reconciled $false 're-read guard aborts the reconcile when status changed under the lock'
Assert-Equal $resultReReadGuard.Status 'cancelled' 're-read guard reports the newer on-disk status, not the stale done verdict'
Assert-Equal $resultReReadGuard.PossiblyStale $false 're-read guard abort is not possibly-stale (a definite terminal state won)'
$diskAfterReRead = Get-Content -LiteralPath (Join-Path $dirReReadGuard 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $diskAfterReRead.status 'running' 'aborted reconcile left status.json unwritten (never clobbered to done)'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $dirReReadGuard '.lock'))) 'the re-read-guard abort still releases the lock'
# Restore the real Read-CcodexStatusFile for any later tests in this file.
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')

# --- Get-CcodexJobHealth ---

Write-Host "Get-CcodexJobHealth: running + fresh heartbeat -> ok"
$freshHb = (Get-Date).ToUniversalTime().ToString('o')
$healthFresh = Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $freshHb; started_at = $freshHb })
Assert-Equal $healthFresh 'ok' 'running job with a fresh heartbeat is ok'

Write-Host "Get-CcodexJobHealth: running + old heartbeat -> stale"
$oldHb = (Get-Date).ToUniversalTime().AddSeconds(-600).ToString('o')
$healthOld = Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $oldHb; started_at = $oldHb })
Assert-Equal $healthOld 'stale' 'running job with an old heartbeat is stale'

Write-Host "Get-CcodexJobHealth: running + no heartbeat, fresh started_at -> ok (started_at fallback)"
$freshStart = (Get-Date).ToUniversalTime().ToString('o')
$healthFallbackFresh = Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $null; started_at = $freshStart })
Assert-Equal $healthFallbackFresh 'ok' 'running job with no heartbeat but a fresh started_at falls back to ok'

Write-Host "Get-CcodexJobHealth: running + no heartbeat, old started_at -> stale"
$oldStart = (Get-Date).ToUniversalTime().AddSeconds(-600).ToString('o')
$healthFallbackOld = Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $null; started_at = $oldStart })
Assert-Equal $healthFallbackOld 'stale' 'running job with no heartbeat and an old started_at is stale'

Write-Host "Get-CcodexJobHealth: running + no timestamps at all -> stale"
$healthNoTs = Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $null; started_at = $null })
Assert-Equal $healthNoTs 'stale' 'running job with no timestamps at all is stale'

Write-Host "Get-CcodexJobHealth: non-running statuses and null -> null"
Assert-Equal (Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'done'; last_heartbeat_at = $freshHb })) $null 'done job has null health regardless of heartbeat'
Assert-Equal (Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'created' })) $null 'created job has null health'
Assert-Equal (Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'timed_out'; last_heartbeat_at = $freshHb })) $null 'timed_out job has null health'
Assert-Equal (Get-CcodexJobHealth -Status $null) $null 'null status object has null health'

Write-Host "Get-CcodexJobHealth: honors a custom StaleAfterSec threshold"
$hb45 = (Get-Date).ToUniversalTime().AddSeconds(-45).ToString('o')
Assert-Equal (Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $hb45 }) -StaleAfterSec 30) 'stale' '45s-old heartbeat is stale under a 30s threshold'
Assert-Equal (Get-CcodexJobHealth -Status ([pscustomobject]@{ status = 'running'; last_heartbeat_at = $hb45 })) 'ok' '45s-old heartbeat is ok under the 90s default threshold'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
