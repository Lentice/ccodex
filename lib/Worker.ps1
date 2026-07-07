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
        [string]$CodexPath
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
    $workerPrompt = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8

    $currentProcess = Get-Process -Id $PID
    $backendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime $currentProcess.StartTime
    $startedAt = (Get-Date).ToString('o')

    # The job-level hard timeout is data on the job, written into status.json by
    # `submit` (`--hard-timeout-sec <n>`); the worker picks it up here rather than
    # from the command line. Absent/0 means never kill.
    $hardTimeoutSec = if ($status.hard_timeout_sec) { [int]$status.hard_timeout_sec } else { 0 }
    $hardTimeoutSecOrNull = if ($hardTimeoutSec -gt 0) { $hardTimeoutSec } else { $null }

    $statusPath = Join-Path $jobDir 'status.json'
    Write-CcodexJsonFileAtomic -Path $statusPath -Object (New-CcodexStatusObject `
        -JobId $JobId -Status 'running' -Mode $status.mode -Access $status.access -Repo $status.repo `
        -CreatedAt $status.created_at -Backend 'native' -BackendId $backendId -StartedAt $startedAt -HardTimeoutSec $hardTimeoutSecOrNull)

    # Liveness heartbeat: while Codex runs (which can be many minutes), periodically
    # re-stamp status.json's last_heartbeat_at under the per-job lock, preserving every
    # other field. Readers derive health=ok|stale from this (Get-CcodexJobHealth). It is
    # best-effort — Invoke-CcodexCodexProcess swallows any exception — and a lock it cannot
    # acquire is skipped rather than blocking the run. GetNewClosure captures $jobDir/
    # $statusPath so the block works when invoked from inside the codex-process wait loop.
    $onHeartbeat = {
        $current = Read-CcodexStatusFile -JobDir $jobDir
        if ($null -eq $current) { return }
        $updated = [ordered]@{}
        foreach ($property in $current.PSObject.Properties) { $updated[$property.Name] = $property.Value }
        $updated['last_heartbeat_at'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-CcodexStatusUnderLock -JobDir $jobDir -CommandName 'heartbeat' -StatusPath $statusPath -StatusObject $updated | Out-Null
    }.GetNewClosure()

    # SkipRunningWrite: the worker already stamped its own `running` status.json (with the
    # backend_id/started_at above) immediately before this call, so the execution core must
    # not overwrite it with a redundant second `running` write of the same content.
    $coreResult = Invoke-CcodexJobExecution -JobDir $jobDir -RepoRoot $status.repo -Mode $status.mode `
        -Access $status.access -WorkerPrompt $workerPrompt -CodexPath $CodexPath -CreatedAt $status.created_at `
        -Backend 'native' -BackendId $backendId -StartedAt $startedAt -HardTimeoutSec $hardTimeoutSec -SkipRunningWrite `
        -OnHeartbeat $onHeartbeat

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Message = $coreResult.Message }
}
