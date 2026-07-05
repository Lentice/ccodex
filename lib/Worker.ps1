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

    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject `
        -JobId $JobId -Status 'running' -Mode $status.mode -Access $status.access -Repo $status.repo `
        -CreatedAt $status.created_at -Backend 'native' -BackendId $backendId -StartedAt $startedAt)

    $coreResult = Invoke-CcodexJobExecution -JobDir $jobDir -RepoRoot $status.repo -Mode $status.mode `
        -Access $status.access -WorkerPrompt $workerPrompt -CodexPath $CodexPath -CreatedAt $status.created_at `
        -Backend 'native' -BackendId $backendId -StartedAt $startedAt

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Message = $coreResult.Message }
}
