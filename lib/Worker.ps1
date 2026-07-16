# lib/Worker.ps1
#
# Invoke-CcodexWorker is the internal entrypoint run by `ccodex worker --job-id <id>`.
# It is invoked from inside an already-detached (or, in tests, directly spawned) process
# that owns exactly one job: it never receives task text on the command line, only the
# job id and (test-support only) state-root/codex-path overrides. Everything it needs
# (mode/access/repo/prompt) is read back out of the job directory that `submit`/`run`
# already prepared.
function Invoke-CcodexWorker {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA,
        [string]$CodexPath,
        # Optional --model/--effort passthrough, received on the worker launch command line
        # (status.json deliberately never carries them) and forwarded to the execution core's
        # Build-CcodexCodexArgs call.
        [string]$Model = $null,
        [string]$Effort = $null
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir

    $status = Read-CcodexStatusFile -JobDir $jobDir
    if ($null -eq $status) {
        $message = "ccodex: internal error: job '$JobId' has no readable status.json.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Message = $message }
    }

    $promptPath = Join-Path $jobDir 'prompt.md'
    if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
        $message = "ccodex: internal error: job '$JobId' has no prompt.md to execute.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Message = $message }
    }
    # Read under try/catch: prompt.md passed the existence check above, but a delete/lock racing
    # in between (or any IO error) must fail as a clean internal error (exit 12) rather than let
    # the exception escape and leave the job stuck at 'created' with a dead worker.
    try {
        $workerPrompt = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8
    } catch {
        $message = "ccodex: internal error: job '$JobId' prompt.md could not be read: $($_.Exception.Message)`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Message = $message }
    }

    $currentProcess = Get-Process -Id $PID
    $backendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime $currentProcess.StartTime
    $startedAt = (Get-Date).ToString('o')

    # The job-level hard timeout is data on the job, written into status.json by
    # `submit` (`--hard-timeout-sec <n>`); the worker picks it up here rather than
    # from the command line. Absent/0 means never kill.
    $hardTimeoutSec = if ($status.hard_timeout_sec) { [int]$status.hard_timeout_sec } else { 0 }
    $hardTimeoutSecOrNull = if ($hardTimeoutSec -gt 0) { $hardTimeoutSec } else { $null }

    # Phase 4: worktree jobs carry main_repo/worktree_repo/base_commit on their `created`
    # status.json (written by Initialize-CcodexJob). Read them back so the worker's own
    # created->running write preserves them (append-only) and the execution core targets the
    # worktree with `-C` and snapshots it afterward. Null/absent for non-worktree jobs.
    $mainRepo = $status.main_repo
    $worktreeRepo = $status.worktree_repo
    $baseCommit = $status.base_commit
    $seriesBaseCommit = $status.series_base_commit
    $group = $status.group
    $label = $status.label
    $parentJobId = $status.parent_job_id
    $fallbackCodexThreadId = $status.codex_thread_id
    $isResumedJob = -not [string]::IsNullOrEmpty($parentJobId) -and -not [string]::IsNullOrEmpty($fallbackCodexThreadId)

    $statusPath = Join-Path $jobDir 'status.json'
    $runningStatusObject = New-CcodexStatusObject `
        -JobId $JobId -Status 'running' -Mode $status.mode -Access $status.access -Repo $status.repo `
        -CreatedAt $status.created_at -Backend 'native' -BackendId $backendId -StartedAt $startedAt -HardTimeoutSec $hardTimeoutSecOrNull `
        -MainRepo $mainRepo -WorktreeRepo $worktreeRepo -BaseCommit $baseCommit -SeriesBaseCommit $seriesBaseCommit -CodexThreadId $fallbackCodexThreadId `
        -ParentJobId $parentJobId -Group $group -Label $label

    # The created->running transition is a status.json WRITE, so it goes through the
    # per-job lock like every other writer AND re-reads status under the lock before
    # writing: a cancel that raced in first (marking this never-started job `cancelled`)
    # must not be resurrected to `running`. Outcomes:
    #   Proceed=$true            -> job was still `created`; running written; run codex.
    #   Proceed=$false, code 0   -> job already moved off `created` (e.g. cancelled);
    #                               leave that status intact and exit without running codex.
    #   Proceed=$false, code 12  -> could not acquire the lock, OR the re-read under the
    #                               lock came back null/unreadable (unknown state); fail
    #                               terminally with evidence rather than dying silently or
    #                               writing `running` over state we cannot account for
    #                               (Complete-CcodexInternalFailure, mirroring
    #                               Invoke-CcodexJobExecution).
    $startResult = Start-CcodexWorkerRunning -JobDir $jobDir -StatusPath $statusPath -JobId $JobId -RunningStatusObject $runningStatusObject
    if (-not $startResult.Proceed) {
        if ($startResult.WrapperExitCode -eq 12) {
            $failResult = Complete-CcodexInternalFailure -JobDir $jobDir -JobId $JobId -Mode $status.mode `
                -Access $status.access -RepoRoot $status.repo -CreatedAt $status.created_at -Backend 'native' `
                -BackendId $backendId -StartedAt $startedAt -ResultPath (Join-Path $jobDir 'result.md') `
                -EventsPath (Join-Path $jobDir 'codex-events.jsonl') -StderrPath (Join-Path $jobDir 'stderr.log') `
                -MainRepo $mainRepo -WorktreeRepo $worktreeRepo -BaseCommit $baseCommit -SeriesBaseCommit $seriesBaseCommit -Group $group -Label $label `
                -ParentJobId $parentJobId -FallbackCodexThreadId $fallbackCodexThreadId `
                -Message $startResult.Message
            return [pscustomobject]@{ WrapperExitCode = $failResult.WrapperExitCode; Message = $failResult.Message }
        }
        return [pscustomobject]@{ WrapperExitCode = $startResult.WrapperExitCode; Message = $startResult.Message }
    }

    # Liveness heartbeat: while Codex runs (which can be many minutes), periodically
    # re-stamp status.json's last_heartbeat_at under the per-job lock, preserving every
    # other field. Readers derive health=ok|stale from this (Get-CcodexJobHealth). It is
    # best-effort — Invoke-CcodexCodexProcess swallows any exception — and a lock it cannot
    # acquire is skipped rather than blocking the run. GetNewClosure captures $jobDir/
    # $statusPath/$backendId so the block works when invoked from inside the codex-process
    # wait loop. Update-CcodexHeartbeat re-reads status INSIDE the lock and only bumps a
    # job still `running` under this backend, so it can never resurrect a status a
    # concurrent cancel/terminal/reconcile writer already changed.
    $onHeartbeat = {
        Update-CcodexHeartbeat -JobDir $jobDir -StatusPath $statusPath -BackendId $backendId
    }.GetNewClosure()

    # SkipRunningWrite: the worker already stamped its own `running` status.json (with the
    # backend_id/started_at above) immediately before this call, so the execution core must
    # not overwrite it with a redundant second `running` write of the same content.
    if ($isResumedJob) {
        $codexTargetRepo = if ($worktreeRepo) { $worktreeRepo } else { $status.repo }
        $resumeArgs = Build-CcodexResumeArgs -RepoRoot $codexTargetRepo -ResultPath (Join-Path $jobDir 'result.md') `
            -ThreadId $fallbackCodexThreadId -Access $status.access -Model $Model -Effort $Effort
        $coreResult = Invoke-CcodexJobExecution -JobDir $jobDir -RepoRoot $status.repo -Mode $status.mode `
            -Access $status.access -WorkerPrompt $workerPrompt -CodexPath $CodexPath -CreatedAt $status.created_at `
            -Backend 'native' -BackendId $backendId -StartedAt $startedAt -HardTimeoutSec $hardTimeoutSec -SkipRunningWrite `
            -OnHeartbeat $onHeartbeat -MainRepo $mainRepo -WorktreeRepo $worktreeRepo -BaseCommit $baseCommit -SeriesBaseCommit $seriesBaseCommit -Group $group -Label $label `
            -Model $Model -Effort $Effort -CodexArgs $resumeArgs -ParentJobId $parentJobId -FallbackCodexThreadId $fallbackCodexThreadId
    } else {
        $coreResult = Invoke-CcodexJobExecution -JobDir $jobDir -RepoRoot $status.repo -Mode $status.mode `
            -Access $status.access -WorkerPrompt $workerPrompt -CodexPath $CodexPath -CreatedAt $status.created_at `
            -Backend 'native' -BackendId $backendId -StartedAt $startedAt -HardTimeoutSec $hardTimeoutSec -SkipRunningWrite `
            -OnHeartbeat $onHeartbeat -MainRepo $mainRepo -WorktreeRepo $worktreeRepo -BaseCommit $baseCommit -Group $group -Label $label `
            -Model $Model -Effort $Effort
    }

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Message = $coreResult.Message }
}

function Start-CcodexWorkerRunning {
    # Performs the worker's created->running status transition under the per-job lock,
    # re-reading status INSIDE the lock so a cancel that already moved the job off
    # `created` is never resurrected to `running`. Returns a result with:
    #   { Proceed = $true }                                 -> caller runs codex
    #   { Proceed = $false; WrapperExitCode = 0;  Message } -> job already terminal; exit clean
    #   { Proceed = $false; WrapperExitCode = 12; Message } -> lock could not be acquired, OR
    #                                                           the re-read under the lock came
    #                                                           back null/unreadable -- treated
    #                                                           as unknown state, never as
    #                                                           permission to write `running`.
    # Mirrors Write-CcodexStatusUnderLock's "one retry then give up" contract for the lock,
    # and releases the lock before returning in every case (codex then runs lock-free; the
    # heartbeat re-acquires the lock per beat).
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)]$RunningStatusObject,
        [int]$LockTimeoutSec = 10
    )
    $acquired = $false
    try {
        Lock-CcodexJob -JobDir $JobDir -TimeoutSec $LockTimeoutSec -CommandName 'native' | Out-Null
        $acquired = $true
    } catch {
        try {
            Lock-CcodexJob -JobDir $JobDir -TimeoutSec $LockTimeoutSec -CommandName 'native' | Out-Null
            $acquired = $true
        } catch {
            $acquired = $false
        }
    }
    if (-not $acquired) {
        return [pscustomobject]@{ Proceed = $false; WrapperExitCode = 12; Message = 'could not acquire the job lock to record the running status' }
    }
    try {
        $current = Read-CcodexStatusFile -JobDir $JobDir
        if ($null -eq $current) {
            # A re-read that comes back null (missing/unreadable) under the lock is NOT
            # evidence that the job is still safely `created` -- it is unknown state (a
            # mid-write, a corrupt file, a status.json that vanished). Writing `running`
            # over that would risk clobbering whatever a concurrent writer is doing to it.
            # Fail conservatively instead: WrapperExitCode 12 routes the caller
            # (Invoke-CcodexWorker) through Complete-CcodexInternalFailure, which stamps
            # its OWN terminal status.json rather than leaving the job non-terminal.
            return [pscustomobject]@{ Proceed = $false; WrapperExitCode = 12; Message = "ccodex: internal error: job $JobId has no readable status.json under the lock; refusing to write running over unknown state.`n  job dir: $JobDir" }
        }
        if ($current.status -ne 'created') {
            return [pscustomobject]@{ Proceed = $false; WrapperExitCode = 0; Message = "ccodex: job $JobId is '$($current.status)'; worker exiting without running codex.`n  job dir: $JobDir" }
        }
        Write-CcodexJsonFileAtomic -Path $StatusPath -Object $RunningStatusObject
    } finally {
        Unlock-CcodexJob -JobDir $JobDir
    }
    return [pscustomobject]@{ Proceed = $true; WrapperExitCode = 0; Message = $null }
}

function Update-CcodexHeartbeat {
    # Best-effort liveness heartbeat. Acquires the per-job lock, RE-READS status.json
    # INSIDE the lock, and stamps last_heartbeat_at ONLY when the job is still `running`
    # under THIS worker's backend_id. Reading inside the lock (never from a snapshot taken
    # before it) is what prevents resurrecting a job a concurrent cancel/terminal/reconcile
    # writer just moved off `running`: a stale pre-lock snapshot would otherwise clobber
    # e.g. `cancelled` back to `running`. Never throws — a lock it cannot acquire, or any
    # read/write error, is swallowed so a missed beat can never derail the codex wait loop.
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)][string]$BackendId,
        [int]$LockTimeoutSec = 10
    )
    try {
        Lock-CcodexJob -JobDir $JobDir -TimeoutSec $LockTimeoutSec -CommandName 'heartbeat' | Out-Null
    } catch {
        return
    }
    try {
        $current = Read-CcodexStatusFile -JobDir $JobDir
        if ($null -eq $current) { return }
        if ($current.status -ne 'running') { return }
        if ([string]$current.backend_id -ne [string]$BackendId) { return }
        $updated = [ordered]@{}
        foreach ($property in $current.PSObject.Properties) { $updated[$property.Name] = $property.Value }
        $updated['last_heartbeat_at'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-CcodexJsonFileAtomic -Path $StatusPath -Object $updated
    } catch {
        # best-effort: swallow read/write errors so a missed beat never derails the run
    } finally {
        Unlock-CcodexJob -JobDir $JobDir
    }
}
