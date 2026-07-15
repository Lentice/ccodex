# lib/JobStatus.ps1
function Read-CcodexStatusFile {
    param([Parameter(Mandatory)][string]$JobDir)

    $statusPath = Join-Path $JobDir 'status.json'
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                $content = Get-Content -LiteralPath $statusPath -Raw
                return $content | ConvertFrom-Json
            }
        } catch {
            # tolerate a mid-rename / mid-write window; retry below
        }
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

function ConvertTo-CcodexHealthUtcDateTime {
    # ConvertFrom-Json auto-deserializes ISO-8601 timestamp strings into [DateTime]
    # objects, so status.json's last_heartbeat_at/started_at can come back as either a
    # [DateTime] or a plain [string]. A naive [string] cast of a DateTime re-renders it
    # in the current culture WITHOUT its zone, so a re-parse would silently shift it by
    # the local offset. Return a correct UTC [DateTime] from either shape, or $null when
    # neither parses (mirrors JobLock's ConvertTo-CcodexLockUtcDateTime, kept local so
    # JobStatus stays independently dot-sourceable).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Get-CcodexJobHealth {
    # Derives a coarse, heartbeat-based health signal for a job from its status object.
    # Returns $null for any non-running job (health is only meaningful while running).
    # For a running job it returns 'ok' when the last worker heartbeat is within
    # $StaleAfterSec, else 'stale'. When no heartbeat has been written yet it falls back
    # to started_at; when neither timestamp is present/parseable the job is 'stale'.
    # This is distinct from reconciliation's 'possibly-stale' verdict (a dead worker with
    # no completion evidence yet) — callers keep that wording for the PossiblyStale case.
    param(
        [pscustomobject]$Status,
        [int]$StaleAfterSec = 90
    )
    if ($null -eq $Status) { return $null }
    if ($Status.status -ne 'running') { return $null }

    $timestampValue = $Status.last_heartbeat_at
    if ([string]::IsNullOrEmpty([string]$timestampValue)) {
        # No heartbeat written yet: fall back to when the worker started running.
        $timestampValue = $Status.started_at
    }
    if ([string]::IsNullOrEmpty([string]$timestampValue)) { return 'stale' }

    $timestampUtc = ConvertTo-CcodexHealthUtcDateTime -Value $timestampValue
    if ($null -eq $timestampUtc) { return 'stale' }

    $ageSec = ((Get-Date).ToUniversalTime() - $timestampUtc).TotalSeconds
    if ($ageSec -gt $StaleAfterSec) { return 'stale' }
    return 'ok'
}

function ConvertTo-CcodexBackendId {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][DateTime]$StartTime
    )
    return "$ProcessId;$($StartTime.ToUniversalTime().ToString('o'))"
}

function Test-CcodexWorkerAlive {
    param([string]$BackendId)

    if ([string]::IsNullOrEmpty($BackendId)) {
        return $false
    }

    $parts = $BackendId.Split(';', 2)
    if ($parts.Count -ne 2) {
        return $false
    }

    $pidText = $parts[0]
    $startTimeText = $parts[1]

    $processId = 0
    if (-not [int]::TryParse($pidText, [ref]$processId)) {
        return $false
    }

    $recordedStartTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
            $startTimeText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$recordedStartTime)) {
        return $false
    }

    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
        $actualStartTimeUtc = $proc.StartTime.ToUniversalTime()
        $recordedStartTimeUtc = $recordedStartTime.ToUniversalTime()
        $delta = ($actualStartTimeUtc - $recordedStartTimeUtc).Duration()
        return $delta.TotalSeconds -le 2
    } catch {
        return $false
    }
}

function Update-CcodexOrphanStatus {
    # $LockTimeoutSec bounds how long the (write-side) reconciliation will wait for the
    # per-job lock before giving up. Reconciliation is triggered from read-only commands
    # (status/wait/read), so a lock it cannot acquire must never block or throw: it skips
    # the rewrite this pass and reports the job as possibly-stale instead.
    #
    # $DryRun: compute the terminal verdict from completion evidence exactly as normal, but do
    # NOT acquire the lock or write status.json. Returns Reconciled=$true with the computed
    # status object in ReconciledStatus so a caller (cleanup --dry-run) can preview the outcome
    # without mutating on-disk state — a dry run must never change anything.
    param([Parameter(Mandatory)][string]$JobDir, [int]$LockTimeoutSec = 10, [switch]$DryRun)

    $status = Read-CcodexStatusFile -JobDir $JobDir
    if ($null -eq $status) {
        return [pscustomobject]@{ Status = $null; Reconciled = $false; PossiblyStale = $true }
    }

    if ($status.status -ne 'running') {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $false }
    }

    if (Test-CcodexWorkerAlive -BackendId $status.backend_id) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $false }
    }

    $exitCodePath = Join-Path $JobDir 'exit_code.txt'
    if (-not (Test-Path -LiteralPath $exitCodePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
    }

    # Dogfood #2: exit_code.txt can be caught mid-write (empty/partial/corrupt) if the
    # worker died at just the wrong instant. Treat anything that doesn't parse cleanly as
    # a whole integer as no-usable-evidence rather than throwing — the job stays `running`
    # with health=possibly-stale, to be reconciled on a later poll once the file settles.
    $exitCodeRawContent = Get-Content -LiteralPath $exitCodePath -Raw
    $exitCodeText = if ($null -ne $exitCodeRawContent) { $exitCodeRawContent.Trim() } else { '' }
    $codexExitCode = 0
    if (-not [int]::TryParse($exitCodeText, [ref]$codexExitCode)) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
    }
    $resultPath = Join-Path $JobDir 'result.md'
    $verdict = Test-CcodexResult -CodexExitCode $codexExitCode -ResultPath $resultPath

    # Same diagnostics normal completion records (ccodex.ps1's Invoke-CcodexJobExecution):
    # failure_reason only on a failure terminal status (never stamped for a successful
    # run), codex_thread_id whenever present regardless of success/failure. Without this,
    # async crash recovery (this evidence-based reconciliation path) would silently lose
    # both compared to a worker that reached its own terminal status normally.
    $stderrPath = Join-Path $JobDir 'stderr.log'
    $eventsPath = Join-Path $JobDir 'codex-events.jsonl'
    $failureReason = if ($verdict.Status -eq 'failed') { Get-CcodexFailureReason -CodexExitCode $codexExitCode -StderrPath $stderrPath -EventsPath $eventsPath } else { $null }
    $codexThreadId = Get-CcodexCodexThreadId -EventsPath $eventsPath

    $updated = [ordered]@{}
    foreach ($property in $status.PSObject.Properties) {
        $updated[$property.Name] = $property.Value
    }
    $updated['status'] = $verdict.Status
    $updated['codex_exit_code'] = $codexExitCode
    $updated['wrapper_exit_code'] = $verdict.WrapperExitCode
    $updated['finished_at'] = (Get-Date).ToUniversalTime().ToString('o')
    $updated['error'] = if ($verdict.Status -eq 'failed') {
        'worker process exited; state reconciled from completion evidence'
    } else {
        $null
    }
    # Append-only: these keys may not exist on an older status.json (pre-dating failure
    # classification); the indexer assignment below adds them either way.
    $updated['failure_reason'] = $failureReason
    $updated['codex_thread_id'] = $codexThreadId

    if ($DryRun) {
        # Preview only: report the computed terminal verdict WITHOUT taking the lock or writing.
        return [pscustomobject]@{ Status = $verdict.Status; Reconciled = $true; PossiblyStale = $false; ReconciledStatus = [pscustomobject]$updated }
    }

    # The reconciliation rewrite is a status.json WRITE, so it goes through the per-job
    # lock like every other writer. Because the caller is a reader, a lock we cannot
    # acquire must not block or bubble up: skip this pass and report possibly-stale.
    try {
        Lock-CcodexJob -JobDir $JobDir -TimeoutSec $LockTimeoutSec -CommandName 'reconcile' | Out-Null
    } catch {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
    }
    try {
        # Re-read UNDER the lock and abort unless the job is still the exact `running`
        # snapshot we computed the terminal verdict from. Between the pre-lock read above
        # and acquiring the lock, a concurrent cancel, a worker's own terminal write, or
        # another reconcile pass may have moved this job to a terminal status (or a new
        # backend). Writing our stale verdict now would clobber that newer state, so we
        # abandon the rewrite instead and report whatever is on disk.
        $recheck = Read-CcodexStatusFile -JobDir $JobDir
        if ($null -eq $recheck) {
            return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
        }
        if ($recheck.status -ne 'running' -or [string]$recheck.backend_id -ne [string]$status.backend_id) {
            return [pscustomobject]@{ Status = $recheck.status; Reconciled = $false; PossiblyStale = $false }
        }
        Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'status.json') -Object $updated
    } finally {
        Unlock-CcodexJob -JobDir $JobDir
    }

    return [pscustomobject]@{ Status = $verdict.Status; Reconciled = $true; PossiblyStale = $false }
}
