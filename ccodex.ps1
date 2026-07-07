# ccodex.ps1
#
# NOTE: This is a plain `param()` script on purpose — it is NOT an advanced
# ([CmdletBinding()]) script, and it deliberately never references the automatic
# `$input` variable. Both choices are load-bearing for redirected-stdin handling:
#
#   * The tool is only ever launched as `pwsh -NoProfile -File ccodex.ps1 ...`
#     (via the ccodex.cmd PATH shim). Piping a task (`"text" | ccodex run ...`)
#     therefore reaches the script as OS-level redirected stdin.
#   * If this were an advanced script, PowerShell would attempt to bind that
#     redirected stdin to a pipeline parameter before the body runs; with no
#     ValueFromPipeline parameter the bind fails, the stdin bytes are consumed
#     and discarded, and the OS-stream reader below sees 0 bytes.
#   * Merely referencing `$input` (even in a plain script) makes PowerShell route
#     stdin into the pipeline enumerator, again draining the OS console stream.
#
# By staying a plain script and leaving `$input` untouched, redirected stdin
# remains fully readable via [Console]::OpenStandardInput(), so
# Read-CcodexStdinWithTimeout (dot-sourced from lib/StdinTimeout.ps1) can read the
# raw bytes and decode them as UTF-8 exactly — which the PowerShell `$input`
# path cannot guarantee (it depends on [Console]::InputEncoding, which we must
# not force). Task 12 Steps 4/5 (piped task + Traditional Chinese) depend on this.
param(
    [string]$Command,
    [string]$PositionalTask,
    [string]$Mode,
    [string]$Access,
    [string]$Repo,
    [string]$PromptFile,
    [switch]$ImportOnly
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Paths.ps1')
. (Join-Path $PSScriptRoot 'lib\Repo.ps1')
. (Join-Path $PSScriptRoot 'lib\JobId.ps1')
. (Join-Path $PSScriptRoot 'lib\StdinTimeout.ps1')
. (Join-Path $PSScriptRoot 'lib\PromptSource.ps1')
. (Join-Path $PSScriptRoot 'lib\WorkerPrompt.ps1')
. (Join-Path $PSScriptRoot 'lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot 'lib\JobStore.ps1')
. (Join-Path $PSScriptRoot 'lib\FailureClassify.ps1')
. (Join-Path $PSScriptRoot 'lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot 'lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot 'lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot 'lib\JobLock.ps1')
. (Join-Path $PSScriptRoot 'lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot 'lib\Worker.ps1')
. (Join-Path $PSScriptRoot 'lib\Detach.ps1')
. (Join-Path $PSScriptRoot 'lib\ReviewPrompt.ps1')
. (Join-Path $PSScriptRoot 'lib\UserConfig.ps1')
. (Join-Path $PSScriptRoot 'lib\Cleanup.ps1')

function Complete-CcodexInternalFailure {
    # A wrapper-internal failure after the job dir is reserved (codex path
    # resolution, or the launch/process step itself in the execution core, or
    # codex-path resolution inside `submit` before any worker is launched)
    # must still leave the design's completion evidence: a worker-complete.json
    # and a terminal failed status.json, both stamped wrapper_exit_code=12.
    # codex_exit_code stays null because Codex never produced one. A job must
    # never remain at a non-terminal status (e.g. `created`) after this runs.
    # Shared by the execution core and `submit`; each caller is the sole
    # active writer for JobDir at the point it calls this, so writing
    # status.json/worker-complete.json here is single-writer-safe.
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CreatedAt,
        [Parameter(Mandatory)][string]$Message,
        [string]$Backend = 'sync',
        [string]$BackendId = $null,
        [string]$StartedAt = $null,
        [string]$ResultPath = $null,
        [string]$EventsPath = $null,
        [string]$StderrPath = $null
    )
    $completedAt = (Get-Date).ToString('o')
    $resultPresent = $false
    if ($ResultPath) {
        try { $resultPresent = Test-Path -LiteralPath $ResultPath -PathType Leaf } catch { $resultPresent = $false }
    }
    $completeObj = New-CcodexWorkerCompleteObject -JobId $JobId -StatusCandidate 'failed' -CodexExitCode $null -WrapperExitCode 12 -ResultPresent $resultPresent -CompletedAt $completedAt
    Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'worker-complete.json') -Object $completeObj

    $failureReason = Get-CcodexFailureReason -CodexExitCode $null -StderrPath $StderrPath -EventsPath $EventsPath
    $codexThreadId = Get-CcodexCodexThreadId -EventsPath $EventsPath
    $hintLine = Get-CcodexFailureHintLine -FailureReason $failureReason
    $hintedMessage = if ($hintLine) { "$Message`n  $hintLine" } else { $Message }

    $statusObj = New-CcodexStatusObject -JobId $JobId -Status 'failed' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -WrapperExitCode 12 -ErrorMessage $hintedMessage -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -FinishedAt $completedAt -FailureReason $failureReason -CodexThreadId $codexThreadId
    Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'status.json') -Object $statusObj
    return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = "ccodex: internal error: $hintedMessage`n  job dir: $JobDir"; CodexExitCode = $null; Status = 'failed' }
}

function Write-CcodexStatusUnderLock {
    # Serializes a single status.json write behind the per-job lock so a concurrent
    # writer (cancel, cleanup, or read-side reconciliation) can never clobber it. The
    # lock is held only for the duration of this one write and released immediately
    # (try/finally), so it is free again while the long-running Codex process executes
    # between the `running` and terminal writes. Returns $true when the write happened;
    # $false when the lock could not be acquired even after a single retry, leaving the
    # caller to decide how to force a terminal failure (it must not die silently).
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)]$StatusObject,
        [string]$CommandName = 'worker',
        [int]$TimeoutSec = 10
    )
    $acquired = $false
    try {
        Lock-CcodexJob -JobDir $JobDir -TimeoutSec $TimeoutSec -CommandName $CommandName | Out-Null
        $acquired = $true
    } catch {
        try {
            Lock-CcodexJob -JobDir $JobDir -TimeoutSec $TimeoutSec -CommandName $CommandName | Out-Null
            $acquired = $true
        } catch {
            $acquired = $false
        }
    }
    if (-not $acquired) { return $false }
    try {
        Write-CcodexJsonFileAtomic -Path $StatusPath -Object $StatusObject
    } finally {
        Unlock-CcodexJob -JobDir $JobDir
    }
    return $true
}

function Invoke-CcodexJobExecution {
    # Shared execution core for both the synchronous `run` path and the
    # (future) native worker path. Covers everything from codex-path
    # resolution through the final status write. Callers must already have:
    # reserved the job dir, written the index entry, resolved access, and
    # rendered/written prompt.md. `run` is the sole caller today; behavior of
    # `run` must not change as a result of this extraction.
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$WorkerPrompt,
        [string]$CodexPath,
        [Parameter(Mandatory)][string]$CreatedAt,
        [string]$Backend = 'sync',
        [string]$BackendId = $null,
        [string]$StartedAt = $null,
        [int]$HardTimeoutSec = 0,
        # 2a review minor: the native worker path already stamps its own `running`
        # status.json (with its own backend_id/started_at) before calling into this core;
        # without this switch the core's own running-write below duplicates that stamp with
        # identical content. `run` never passes this switch, so its behavior is unchanged.
        [switch]$SkipRunningWrite,
        # Best-effort heartbeat callback forwarded to Invoke-CcodexCodexProcess. The native
        # worker supplies one (it refreshes last_heartbeat_at in status.json); `run` (sync)
        # passes none, so the caller — which is actively watching — keeps its old behavior.
        [scriptblock]$OnHeartbeat = $null
    )

    $jobId = Split-Path -Leaf $JobDir
    $resultPath = Join-Path $JobDir 'result.md'
    $eventsPath = Join-Path $JobDir 'codex-events.jsonl'
    $stderrPath = Join-Path $JobDir 'stderr.log'
    $exitCodeFilePath = Join-Path $JobDir 'exit_code.txt'
    $hardTimeoutSecOrNull = if ($HardTimeoutSec -gt 0) { $HardTimeoutSec } else { $null }

    $internalFailureParams = @{
        JobDir = $JobDir; JobId = $jobId; Mode = $Mode; Access = $Access; RepoRoot = $RepoRoot
        CreatedAt = $CreatedAt; Backend = $Backend; BackendId = $BackendId; StartedAt = $StartedAt
        ResultPath = $resultPath; EventsPath = $eventsPath; StderrPath = $stderrPath
    }

    try {
        $resolvedCodexPath = if ($CodexPath) { $CodexPath } else { Resolve-CcodexCodexPath }
    } catch {
        return Complete-CcodexInternalFailure @internalFailureParams -Message $_.Exception.Message
    }
    $codexArgs = Build-CcodexCodexArgs -Access $Access -RepoRoot $RepoRoot -ResultPath $resultPath

    Write-CcodexTextFile -Path (Join-Path $JobDir 'command.txt') -Content (ConvertTo-CcodexCommandLineText -Executable $resolvedCodexPath -Arguments $codexArgs)
    Write-CcodexJsonFile -Path (Join-Path $JobDir 'debug.json') -Object (New-CcodexDebugObject -JobId $jobId -Repo $RepoRoot -JobDir $JobDir -Mode $Mode -Access $Access -CodexPath $resolvedCodexPath -CodexArgs $codexArgs -Backend $Backend)
    if (-not $SkipRunningWrite) {
        $wroteRunning = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend `
            -StatusPath (Join-Path $JobDir 'status.json') `
            -StatusObject (New-CcodexStatusObject -JobId $jobId -Status 'running' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -HardTimeoutSec $hardTimeoutSecOrNull)
        if (-not $wroteRunning) {
            return Complete-CcodexInternalFailure @internalFailureParams -Message 'could not acquire the job lock to record the running status'
        }
    }

    try {
        $codexExitCode = Invoke-CcodexCodexProcess -CodexPath $resolvedCodexPath -Arguments $codexArgs -PromptContent $WorkerPrompt -EventsLogPath $eventsPath -StderrLogPath $stderrPath -ExitCodeFilePath $exitCodeFilePath -HardTimeoutMs ($HardTimeoutSec * 1000) -OnHeartbeat $OnHeartbeat
    } catch {
        return Complete-CcodexInternalFailure @internalFailureParams -Message $_.Exception.Message
    }

    if ($null -eq $codexExitCode) {
        # Hard-timeout sentinel: Invoke-CcodexCodexProcess killed the process tree
        # after $HardTimeoutSec elapsed. Codex never produced an exit code, so
        # codex_exit_code stays null; the job goes terminal `timed_out` with
        # wrapper exit 24, a timeout_reason, and terminated_at. Artifacts kept.
        $terminatedAt = (Get-Date).ToString('o')
        $timeoutReason = "hard_timeout_sec=$HardTimeoutSec exceeded"
        $resultPresent = Test-Path -LiteralPath $resultPath -PathType Leaf

        $timeoutComplete = New-CcodexWorkerCompleteObject -JobId $jobId -StatusCandidate 'timed_out' -CodexExitCode $null -WrapperExitCode 24 -ResultPresent $resultPresent -CompletedAt $terminatedAt
        Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'worker-complete.json') -Object $timeoutComplete

        $codexThreadId = Get-CcodexCodexThreadId -EventsPath $eventsPath
        $timeoutStatusObj = New-CcodexStatusObject -JobId $jobId -Status 'timed_out' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -CodexExitCode $null -WrapperExitCode 24 -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -CodexThreadId $codexThreadId -HardTimeoutSec $HardTimeoutSec -TimeoutReason $timeoutReason -TerminatedAt $terminatedAt
        $wroteTimeout = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend -StatusPath (Join-Path $JobDir 'status.json') -StatusObject $timeoutStatusObj
        if (-not $wroteTimeout) {
            return Complete-CcodexInternalFailure @internalFailureParams -Message 'could not acquire the job lock to record the timed_out status'
        }

        $timeoutMessage = "ccodex: job $jobId timed_out ($timeoutReason)`n  job dir: $JobDir"
        return [pscustomobject]@{ WrapperExitCode = 24; Stdout = $null; Message = $timeoutMessage; CodexExitCode = $null; Status = 'timed_out' }
    }

    $preliminaryComplete = New-CcodexWorkerCompleteObject -JobId $jobId -StatusCandidate $(if ($codexExitCode -eq 0) { 'done' } else { 'failed' }) -CodexExitCode $codexExitCode -WrapperExitCode $null -ResultPresent (Test-Path -LiteralPath $resultPath -PathType Leaf) -CompletedAt (Get-Date).ToString('o')
    Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'worker-complete.json') -Object $preliminaryComplete

    $validation = Test-CcodexResult -CodexExitCode $codexExitCode -ResultPath $resultPath

    $finishedAt = (Get-Date).ToString('o')
    $finalComplete = New-CcodexWorkerCompleteObject -JobId $jobId -StatusCandidate $validation.Status -CodexExitCode $codexExitCode -WrapperExitCode $validation.WrapperExitCode -ResultPresent $validation.ResultPresent -CompletedAt $finishedAt
    Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'worker-complete.json') -Object $finalComplete

    # failure_reason is only ever stamped on a failure terminal status (never
    # on a successful run); codex_thread_id is stamped whenever present,
    # regardless of success/failure (design: "stamp codex_thread_id on BOTH
    # success and failure whenever present").
    $failureReason = if ($validation.Status -eq 'failed') { Get-CcodexFailureReason -CodexExitCode $codexExitCode -StderrPath $stderrPath -EventsPath $eventsPath } else { $null }
    $codexThreadId = Get-CcodexCodexThreadId -EventsPath $eventsPath

    $finalStatusObj = New-CcodexStatusObject -JobId $jobId -Status $validation.Status -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -CodexExitCode $codexExitCode -WrapperExitCode $validation.WrapperExitCode -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -FinishedAt $finishedAt -FailureReason $failureReason -CodexThreadId $codexThreadId -HardTimeoutSec $hardTimeoutSecOrNull
    $wroteFinal = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend -StatusPath (Join-Path $JobDir 'status.json') -StatusObject $finalStatusObj
    if (-not $wroteFinal) {
        return Complete-CcodexInternalFailure @internalFailureParams -Message 'could not acquire the job lock to record the terminal status'
    }

    if ($validation.WrapperExitCode -eq 0) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null; CodexExitCode = $codexExitCode; Status = $validation.Status }
    }

    $hintLine = Get-CcodexFailureHintLine -FailureReason $failureReason
    $failureMessage = "ccodex: job $jobId $($validation.Status) (codex_exit_code=$codexExitCode, wrapper_exit_code=$($validation.WrapperExitCode))`n  job dir: $JobDir`n  result:  $resultPath"
    if ($hintLine) { $failureMessage += "`n  $hintLine" }
    return [pscustomobject]@{ WrapperExitCode = $validation.WrapperExitCode; Stdout = $null; Message = $failureMessage; CodexExitCode = $codexExitCode; Status = $validation.Status }
}

function Initialize-CcodexJob {
    # Shared job-preparation core for both `run` (sync) and `submit` (native/detached).
    # Covers everything from mode/access validation through prompt rendering and the
    # initial status.json write. Callers receive JobId/JobDir/RepoRoot/ResolvedAccess/
    # WorkerPrompt/CreatedAt on success (WrapperExitCode 0); usage-error paths return
    # WrapperExitCode 2 with the exact same messages/status side effects as before this
    # extraction (mode/repo failures precede job-dir reservation and touch no job state;
    # access/prompt-source failures happen after reservation and write a terminal failed
    # status.json, matching Complete-CcodexUsageError's prior behavior).
    param(
        [string]$Mode,
        [string]$Access,
        [string]$RepoOverride,
        [string]$PromptFile,
        [string]$PositionalTask,
        [bool]$PipelineExpected,
        [object[]]$PipelineObjects,
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA,
        [string]$InitialStatus = 'created',
        [string]$Backend = 'sync',
        [int]$HardTimeoutSec = 0
    )

    function Complete-CcodexInitFailure {
        param([Nullable[int]]$WrapperExitCode = 2, [string]$Message)
        return [pscustomobject]@{ WrapperExitCode = $WrapperExitCode; JobId = $null; JobDir = $null; RepoRoot = $null; ResolvedAccess = $null; WorkerPrompt = $null; CreatedAt = $null; Message = $Message }
    }

    if (-not $Mode -or $Mode -notin @('review', 'brainstorm', 'test', 'implement')) {
        $message = "ccodex: --mode is required and must be one of: review, brainstorm, test, implement."
        return Complete-CcodexInitFailure -Message $message
    }

    try {
        $repoRoot = Resolve-CcodexRepo -RepoOverride $RepoOverride
    } catch {
        return Complete-CcodexInitFailure -Message $_.Exception.Message
    }

    $repoKey = Get-CcodexRepoKey -RepoRoot $repoRoot
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $LocalAppDataRoot
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $LocalAppDataRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')

    function Complete-CcodexUsageError {
        param([string]$Message, [string]$AccessForStatus)
        $statusObj = New-CcodexStatusObject -JobId $jobId -Status 'failed' -Mode $Mode -Access ($(if ($AccessForStatus) { $AccessForStatus } else { 'unknown' })) -Repo $repoRoot -CreatedAt $createdAt -WrapperExitCode 2 -ErrorMessage $Message -Backend $Backend
        Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
        return [pscustomobject]@{ WrapperExitCode = 2; JobId = $jobId; JobDir = $jobDir; RepoRoot = $repoRoot; ResolvedAccess = $AccessForStatus; WorkerPrompt = $null; CreatedAt = $createdAt; Message = "$Message`n  job:      $jobId`n  job dir:  $jobDir" }
    }

    try {
        $resolvedAccess = Resolve-CcodexAccess -Mode $Mode -Access $Access
    } catch {
        return Complete-CcodexUsageError -Message $_.Exception.Message -AccessForStatus $Access
    }

    try {
        $taskContent = Get-CcodexPromptContent `
            -ExpectingPipelineInput $PipelineExpected `
            -PipelineObjects $PipelineObjects `
            -PromptFile $PromptFile `
            -PositionalTask $PositionalTask `
            -StdinStream ([Console]::OpenStandardInput()) `
            -StdinIsRedirected ([Console]::IsInputRedirected)
    } catch {
        return Complete-CcodexUsageError -Message $_.Exception.Message -AccessForStatus $resolvedAccess
    }

    $artifactDir = $null
    if ($resolvedAccess -eq 'workspace') {
        $artifactDir = Join-Path $jobDir 'artifacts'
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }

    $templatePath = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $AppDataRoot
    $workerPrompt = Build-CcodexWorkerPrompt -TemplatePath $templatePath -Mode $Mode -Access $resolvedAccess -RepoRoot $repoRoot -ArtifactDir $artifactDir -TaskContent $taskContent
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $workerPrompt

    $hardTimeoutSecOrNull = if ($HardTimeoutSec -gt 0) { $HardTimeoutSec } else { $null }
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status $InitialStatus -Mode $Mode -Access $resolvedAccess -Repo $repoRoot -CreatedAt $createdAt -Backend $Backend -HardTimeoutSec $hardTimeoutSecOrNull)

    return [pscustomobject]@{ WrapperExitCode = 0; JobId = $jobId; JobDir = $jobDir; RepoRoot = $repoRoot; ResolvedAccess = $resolvedAccess; WorkerPrompt = $workerPrompt; CreatedAt = $createdAt; Message = $null }
}

function Invoke-CcodexRun {
    param(
        [string]$Mode,
        [string]$Access,
        [string]$RepoOverride,
        [string]$PromptFile,
        [string]$PositionalTask,
        [bool]$PipelineExpected,
        [object[]]$PipelineObjects,
        [string]$CodexPath,
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA,
        [int]$HardTimeoutSec = 0
    )

    $init = Initialize-CcodexJob -Mode $Mode -Access $Access -RepoOverride $RepoOverride -PromptFile $PromptFile `
        -PositionalTask $PositionalTask -PipelineExpected $PipelineExpected -PipelineObjects $PipelineObjects `
        -LocalAppDataRoot $LocalAppDataRoot -AppDataRoot $AppDataRoot -InitialStatus 'created' -Backend 'sync' -HardTimeoutSec $HardTimeoutSec

    if ($init.WrapperExitCode -ne 0) {
        return [pscustomobject]@{ WrapperExitCode = $init.WrapperExitCode; Stdout = $null; JobDir = $init.JobDir; Message = $init.Message }
    }

    $coreResult = Invoke-CcodexJobExecution -JobDir $init.JobDir -RepoRoot $init.RepoRoot -Mode $Mode -Access $init.ResolvedAccess -WorkerPrompt $init.WorkerPrompt -CodexPath $CodexPath -CreatedAt $init.CreatedAt -HardTimeoutSec $HardTimeoutSec

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Stdout = $coreResult.Stdout; JobDir = $init.JobDir; Message = $coreResult.Message }
}

function Invoke-CcodexSubmit {
    # Asynchronous counterpart to Invoke-CcodexRun: prepares the job exactly as `run`
    # does (backend 'native', initial status 'created'), writes command.txt/debug.json
    # pre-launch so the job is diagnosable even if the worker never starts, then hands
    # off to a detached `ccodex.ps1 worker --job-id <id>` process. Never invokes Codex
    # itself and never passes prompt text on the launch command line — the worker reads
    # prompt.md back out of the prepared job directory.
    param(
        [string]$Mode,
        [string]$Access,
        [string]$RepoOverride,
        [string]$PromptFile,
        [string]$PositionalTask,
        [bool]$PipelineExpected,
        [object[]]$PipelineObjects,
        [ValidateSet('cim', 'startprocess')][string]$DetachMechanism = 'cim',
        [string]$CodexPath,
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA,
        [int]$StartupTimeoutSec = 20,
        [int]$HardTimeoutSec = 0,
        # Test-support only: the production path always launches the currently-running
        # ccodex.ps1 (via $PSCommandPath, which resolves to this file regardless of the
        # caller's own script, since PowerShell binds it per script-defining file). Tests
        # that need to force a deterministic startup-sentinel timeout (exit 23) without
        # depending on a race against a real worker process point this at a stub script.
        [string]$WorkerScriptPath = $PSCommandPath
    )

    $init = Initialize-CcodexJob -Mode $Mode -Access $Access -RepoOverride $RepoOverride -PromptFile $PromptFile `
        -PositionalTask $PositionalTask -PipelineExpected $PipelineExpected -PipelineObjects $PipelineObjects `
        -LocalAppDataRoot $LocalAppDataRoot -AppDataRoot $AppDataRoot -InitialStatus 'created' -Backend 'native' -HardTimeoutSec $HardTimeoutSec

    if ($init.WrapperExitCode -ne 0) {
        return [pscustomobject]@{ WrapperExitCode = $init.WrapperExitCode; Stdout = $null; JobDir = $init.JobDir; JobId = $init.JobId; Message = $init.Message }
    }

    $jobId = $init.JobId
    $jobDir = $init.JobDir
    $resultPath = Join-Path $jobDir 'result.md'

    try {
        $resolvedCodexPath = if ($CodexPath) { $CodexPath } else { Resolve-CcodexCodexPath }
        # An explicit -CodexPath override is trusted verbatim by the sync `run`
        # path (which discovers a bad path via the process-launch failure once
        # it tries to invoke Codex). `submit` never invokes Codex itself — it
        # only hands off to a detached worker — so a bad codex path must be
        # caught HERE, before that hand-off, or the job would launch a worker
        # doomed to fail asynchronously while `submit` itself reports success.
        if (-not (Test-Path -LiteralPath $resolvedCodexPath -PathType Leaf)) {
            throw "could not find an executable codex at path: $resolvedCodexPath"
        }
    } catch {
        # Dogfood finding #1: a job must never remain at `created` after a
        # known-fatal internal failure. Write terminal failure evidence
        # (status.json + worker-complete.json) before returning — submit is
        # the sole active writer for jobDir at this point (no worker has been
        # launched yet), so this is single-writer-safe.
        $failure = Complete-CcodexInternalFailure -JobDir $jobDir -JobId $jobId -Mode $Mode -Access $init.ResolvedAccess `
            -RepoRoot $init.RepoRoot -CreatedAt $init.CreatedAt -Message $_.Exception.Message -Backend 'native' -ResultPath $resultPath
        $message = "$($failure.Message)`n  job:      $jobId"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; JobDir = $jobDir; JobId = $jobId; Message = $message }
    }

    $codexArgs = Build-CcodexCodexArgs -Access $init.ResolvedAccess -RepoRoot $init.RepoRoot -ResultPath $resultPath
    Write-CcodexTextFile -Path (Join-Path $jobDir 'command.txt') -Content (ConvertTo-CcodexCommandLineText -Executable $resolvedCodexPath -Arguments $codexArgs)
    Write-CcodexJsonFile -Path (Join-Path $jobDir 'debug.json') -Object (New-CcodexDebugObject -JobId $jobId -Repo $init.RepoRoot -JobDir $jobDir -Mode $Mode -Access $init.ResolvedAccess -CodexPath $resolvedCodexPath -CodexArgs $codexArgs -Backend 'native')

    $stateRootOverride = if ($PSBoundParameters.ContainsKey('LocalAppDataRoot')) { $LocalAppDataRoot } else { $null }
    $codexPathOverride = if ($PSBoundParameters.ContainsKey('CodexPath')) { $CodexPath } else { $null }

    try {
        Start-CcodexDetachedWorker -ScriptPath $WorkerScriptPath -JobId $jobId -WorkingDirectory $init.RepoRoot `
            -StateRoot $stateRootOverride -CodexPath $codexPathOverride -Mechanism $DetachMechanism | Out-Null
        Wait-CcodexWorkerLaunch -JobDir $jobDir -TimeoutSec $StartupTimeoutSec | Out-Null
    } catch {
        # Do NOT rewrite status.json here: a slow-but-alive worker may still be starting,
        # and the job must stay diagnosable in its current ('created') state.
        $message = "ccodex: $($_.Exception.Message)`n  job:      $jobId`n  job dir:  $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 23; Stdout = $null; JobDir = $jobDir; JobId = $jobId; Message = $message }
    }

    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$jobId`n$jobDir"; JobDir = $jobDir; JobId = $jobId; Message = $null }
}

function Invoke-CcodexStatusCommand {
    # Read-only lifecycle report for a job id, callable from any directory. Reconciles
    # a narrowly-gated orphan (dead worker + completion evidence) via
    # Update-CcodexOrphanStatus before composing the line; never writes otherwise.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $reconciliation = Update-CcodexOrphanStatus -JobDir $record.JobDir
    $statusObj = Read-CcodexStatusFile -JobDir $record.JobDir

    $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    if ($statusText -in @('done', 'failed', 'cancelled')) {
        $codexExitText = if ($null -eq $statusObj.codex_exit_code) { 'null' } else { $statusObj.codex_exit_code }
        $wrapperExitText = if ($null -eq $statusObj.wrapper_exit_code) { 'null' } else { $statusObj.wrapper_exit_code }
        $line = "$JobId $statusText codex_exit_code=$codexExitText wrapper_exit_code=$wrapperExitText"
    } else {
        $line = "$JobId $statusText"
        if ($reconciliation.PossiblyStale) {
            # Reconciliation verdict (dead worker, no completion evidence yet) keeps its
            # own wording; it takes precedence over the heartbeat-derived signal.
            $line += ' health=possibly-stale'
        } else {
            # Heartbeat-derived health for a live running job: ok|stale (null for
            # non-running statuses like created/timed_out, which append nothing).
            $health = Get-CcodexJobHealth -Status $statusObj
            if ($health) { $line += " health=$health" }
        }
    }

    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $line; Message = $null }
}

function Invoke-CcodexWaitCommand {
    # Blocks (by default indefinitely; bounded when -WaitTimeoutSec > 0) until a job
    # reaches a terminal status, polling Update-CcodexOrphanStatus + a status re-read on
    # each iteration so a dead-but-evidenced worker is reconciled along the way exactly as
    # `status` would. On terminal `done` it validates result.md via Test-CcodexResult using
    # the recorded codex exit code and returns that content on stdout; on terminal `failed`
    # it returns a concise failure line, mapping the recorded wrapper_exit_code through
    # ({10,11,12} else 10). A timeout prints the current (Task 7-format) status line and
    # returns 20 WITHOUT writing status.json — the job's lifecycle is untouched by waiting.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [int]$WaitTimeoutSec = 0,
        [int]$PollIntervalMs = 1000,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $resultPath = Join-Path $jobDir 'result.md'
    $deadline = if ($WaitTimeoutSec -gt 0) { (Get-Date).AddSeconds($WaitTimeoutSec) } else { $null }

    while ($true) {
        $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
        $statusObj = Read-CcodexStatusFile -JobDir $jobDir
        $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
        if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

        if ($statusText -eq 'done') {
            $recordedCodexExitCode = if ($statusObj -and $null -ne $statusObj.codex_exit_code) { [int]$statusObj.codex_exit_code } else { 0 }
            $validation = Test-CcodexResult -CodexExitCode $recordedCodexExitCode -ResultPath $resultPath
            if ($validation.WrapperExitCode -eq 0) {
                return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null }
            }
            $failureMessage = "ccodex: job $JobId done but result.md is missing or empty (codex_exit_code=$recordedCodexExitCode)`n  job dir: $jobDir`n  result:  $resultPath"
            return [pscustomobject]@{ WrapperExitCode = 11; Stdout = $null; Message = $failureMessage }
        }

        if ($statusText -eq 'failed') {
            $codexExitText = if ($statusObj -and $null -ne $statusObj.codex_exit_code) { $statusObj.codex_exit_code } else { 'null' }
            $recordedWrapperExitCode = if ($statusObj) { $statusObj.wrapper_exit_code } else { $null }
            $wrapperExitText = if ($null -eq $recordedWrapperExitCode) { 'null' } else { $recordedWrapperExitCode }
            $exitCodeToReturn = if ($recordedWrapperExitCode -in @(10, 11, 12)) { $recordedWrapperExitCode } else { 10 }
            $failureMessage = "ccodex: job $JobId failed codex_exit_code=$codexExitText wrapper_exit_code=$wrapperExitText`n  job dir: $jobDir`n  result:  $resultPath"
            return [pscustomobject]@{ WrapperExitCode = $exitCodeToReturn; Stdout = $null; Message = $failureMessage }
        }

        if ($statusText -eq 'timed_out') {
            # Terminal hard-timeout: return the recorded wrapper exit code (24).
            $recordedWrapperExitCode = if ($statusObj -and $null -ne $statusObj.wrapper_exit_code) { [int]$statusObj.wrapper_exit_code } else { 24 }
            $timeoutReasonText = if ($statusObj -and $statusObj.timeout_reason) { " ($($statusObj.timeout_reason))" } else { '' }
            $timeoutMessage = "ccodex: job $JobId timed_out$timeoutReasonText`n  job dir: $jobDir"
            return [pscustomobject]@{ WrapperExitCode = $recordedWrapperExitCode; Stdout = $null; Message = $timeoutMessage }
        }

        if ($statusText -eq 'cancelled') {
            # Terminal cancellation (Task 4): concise status line, wrapper exit 22.
            $cancelledMessage = "ccodex: job $JobId cancelled`n  job dir: $jobDir"
            return [pscustomobject]@{ WrapperExitCode = 22; Stdout = $null; Message = $cancelledMessage }
        }

        if ($deadline -and (Get-Date) -ge $deadline) {
            $line = "$JobId $statusText"
            if ($reconciliation.PossiblyStale) { $line += ' health=possibly-stale' }
            $message = "$line`nccodex: wait timed out after ${WaitTimeoutSec}s; re-run ``ccodex wait $JobId`` to keep waiting."
            return [pscustomobject]@{ WrapperExitCode = 20; Stdout = $null; Message = $message }
        }

        Start-Sleep -Milliseconds $PollIntervalMs
    }
}

function Invoke-CcodexReadCommand {
    # Result-channel accessor: unlike `wait`, this never blocks. Reconciles a
    # narrowly-gated orphan (dead worker + completion evidence) via
    # Update-CcodexOrphanStatus once, same as `status`/`wait`, then branches on the
    # (possibly-reconciled) status. Non-terminal -> exit 4 with a status line + a
    # `ccodex wait <job_id>` hint, no result content. Terminal (done OR failed) with
    # a non-empty result.md -> print it, exit 0 (read is the result channel
    # regardless of which terminal status produced it). Terminal with a
    # missing/empty result.md -> a concise failure, exit 11.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $resultPath = Join-Path $jobDir 'result.md'

    $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
    $statusObj = Read-CcodexStatusFile -JobDir $jobDir
    $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    if ($statusText -notin @('done', 'failed', 'timed_out', 'cancelled')) {
        $line = "$JobId $statusText"
        if ($reconciliation.PossiblyStale) { $line += ' health=possibly-stale' }
        $message = "$line`nccodex: job $JobId is not finished yet; run ``ccodex wait $JobId`` to block until it completes."
        return [pscustomobject]@{ WrapperExitCode = 4; Stdout = $null; Message = $message }
    }

    # 2a review minor: reuse Test-CcodexResult's exists/non-empty logic instead of
    # duplicating it here. `read` doesn't care about codex_exit_code (a terminal `failed`
    # job with a non-empty result.md still prints it, exit 0) so CodexExitCode is forced to
    # 0 purely to select the "exists+non-empty -> ResultPresent" branch; only
    # ResultPresent/ResultContent are used below, matching the prior duplicated logic exactly.
    $validation = Test-CcodexResult -CodexExitCode 0 -ResultPath $resultPath

    if ($validation.ResultPresent) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null }
    }

    $failureMessage = "ccodex: job $JobId $statusText but result.md is missing or empty`n  job dir: $jobDir`n  result:  $resultPath"
    return [pscustomobject]@{ WrapperExitCode = 11; Stdout = $null; Message = $failureMessage }
}

function Invoke-CcodexCancelCommand {
    # Identity-checked process-tree termination (design: "cancel <job_id>", Phase 2b Task 4).
    # Every branch that mutates status.json does so under the per-job lock (acquired once,
    # up front); branches that only need to READ current state release the lock again
    # before doing so, since Update-CcodexOrphanStatus (the dead-worker-with-evidence path)
    # acquires its own lock internally and must never be called while this command still
    # holds it (that would deadlock the lock's own retry loop against itself).
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $terminalStatuses = @('done', 'failed', 'timed_out', 'cancelled')

    try {
        Lock-CcodexJob -JobDir $jobDir -TimeoutSec 10 -CommandName 'cancel' | Out-Null
    } catch {
        $message = "ccodex: could not acquire the job lock to cancel job '$JobId' within 10s.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 21; Stdout = $null; Message = $message }
    }

    $status = Read-CcodexStatusFile -JobDir $jobDir
    if ($null -eq $status) {
        Unlock-CcodexJob -JobDir $jobDir
        $message = "ccodex: internal error: job '$JobId' has no readable status.json.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
    }

    $statusText = $status.status

    if ($statusText -in $terminalStatuses) {
        # No-op: already terminal (whichever terminal status). Nothing to mutate.
        Unlock-CcodexJob -JobDir $jobDir
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId already $statusText"; Message = $null }
    }

    if ($statusText -eq 'running' -and -not (Test-CcodexWorkerAlive -BackendId $status.backend_id)) {
        # The recorded worker identity is dead: this is not a live job to kill, it is an
        # orphan. Release the lock and defer to the same evidence-based reconciliation
        # `status`/`wait`/`read` already perform, rather than forcing `cancelled` over a
        # job that actually completed (or failed) before the cancel request arrived.
        Unlock-CcodexJob -JobDir $jobDir
        $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
        $reconciledStatus = Read-CcodexStatusFile -JobDir $jobDir
        $finalStatusText = if ($reconciledStatus) { $reconciledStatus.status } else { $reconciliation.Status }
        if ([string]::IsNullOrEmpty($finalStatusText)) { $finalStatusText = 'unknown' }
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId $finalStatusText"; Message = $null }
    }

    if ($statusText -eq 'running') {
        # Worker identity verified alive: force-kill the whole process tree (the worker
        # process itself AND whatever codex child it spawned), then poll for actual death
        # -- taskkill returns once the kill request is issued, not once the process tree
        # has actually exited.
        $backendParts = $status.backend_id.Split(';', 2)
        $workerPid = [int]$backendParts[0]
        Stop-CcodexProcessTree -ProcessId $workerPid
        $killDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $killDeadline -and (Test-CcodexWorkerAlive -BackendId $status.backend_id)) {
            Start-Sleep -Milliseconds 200
        }
    }

    # Reached for `running` (worker just force-killed above) or `created` (never started):
    # mark the job cancelled directly, preserving every existing field (append-only) and
    # stamping cancelled_at. wrapper_exit_code is left exactly as it was (null for a job
    # that never reached a terminal codex exit code).
    $cancelledAt = (Get-Date).ToUniversalTime().ToString('o')
    $updated = [ordered]@{}
    foreach ($property in $status.PSObject.Properties) {
        $updated[$property.Name] = $property.Value
    }
    $updated['status'] = 'cancelled'
    $updated['cancelled_at'] = $cancelledAt
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $updated
    Unlock-CcodexJob -JobDir $jobDir

    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId cancelled"; Message = $null }
}

function Get-CcodexTailLines {
    # Reads at most the last 64 KB of $Path via a stream seek from the end (never the
    # whole file), decodes it as UTF-8, and returns the last $Lines lines as a string
    # array. Returns $null when $Path does not exist (the caller renders that as the
    # `(absent)` placeholder) and an empty array (never $null) for an existing-but-empty
    # file. When the seek lands mid-file, the first decoded line is a partial line
    # (split across the seek boundary) and is dropped rather than shown truncated.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Lines
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $maxTailBytes = 64KB
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $length = $stream.Length
        $seekLength = [Math]::Min($length, [long]$maxTailBytes)
        $seekedMidFile = $seekLength -lt $length
        if ($seekLength -gt 0) { $stream.Seek(-$seekLength, [System.IO.SeekOrigin]::End) | Out-Null }
        $buffer = New-Object byte[] $seekLength
        if ($seekLength -gt 0) { $stream.Read($buffer, 0, [int]$seekLength) | Out-Null }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
    } finally {
        $stream.Dispose()
    }

    $allLines = [System.Collections.Generic.List[string]]::new()
    $allLines.AddRange([string[]]($text -split "`r?`n"))
    if ($seekedMidFile -and $allLines.Count -gt 0) { $allLines.RemoveAt(0) }
    if ($allLines.Count -gt 0 -and $allLines[$allLines.Count - 1] -eq '') { $allLines.RemoveAt($allLines.Count - 1) }

    if ($allLines.Count -le $Lines) { return , $allLines.ToArray() }
    return , $allLines.GetRange($allLines.Count - $Lines, $Lines).ToArray()
}

function Invoke-CcodexTailCommand {
    # Diagnostic tail of a job's live/finished-process artifacts (design: "tail <job_id>",
    # Phase 2b Task 6). Read-only, never reconciles or mutates status.json — unlike
    # status/wait/read, this is pure log inspection. Prints stderr.log's tail block first,
    # then codex-events.jsonl's; a missing file renders as a `(absent)` placeholder rather
    # than failing the whole command.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [int]$Lines = 40,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $stderrPath = Join-Path $jobDir 'stderr.log'
    $eventsPath = Join-Path $jobDir 'codex-events.jsonl'

    $stderrLines = Get-CcodexTailLines -Path $stderrPath -Lines $Lines
    $eventsLines = Get-CcodexTailLines -Path $eventsPath -Lines $Lines

    $blocks = New-Object System.Collections.Generic.List[string]
    $blocks.Add("== stderr.log (last $Lines) ==")
    if ($null -eq $stderrLines) { $blocks.Add('(absent)') } else { $blocks.AddRange([string[]]$stderrLines) }
    $blocks.Add("== codex-events.jsonl (last $Lines) ==")
    if ($null -eq $eventsLines) { $blocks.Add('(absent)') } else { $blocks.AddRange([string[]]$eventsLines) }

    $output = [string]::Join("`n", $blocks)
    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $output; Message = $null }
}

function ConvertTo-CcodexTailLinesCount {
    # --lines must be a positive whole number of lines (0 or negative is a usage error,
    # not "use the default"); non-numeric text is likewise a usage error, mirroring
    # ConvertTo-CcodexHardTimeoutSec's shape for --hard-timeout-sec.
    param([Parameter(Mandatory)][string]$FlagName, [Parameter(Mandatory)][string]$ValueText)
    $parsed = 0
    if (-not [int]::TryParse($ValueText, [ref]$parsed) -or $parsed -le 0) {
        throw "ccodex: $FlagName must be a positive whole number of lines; got '$ValueText'."
    }
    return $parsed
}

function Get-CcodexArgValue {
    # Test-support / internal flags (e.g. --job-id, --state-root, --codex-path) contain
    # hyphens that PowerShell's native named-parameter binder cannot match against a
    # script param name, so any such unbound tokens land in the automatic $args array
    # (see the header comment: this script deliberately stays a plain, non-CmdletBinding
    # script). This helper pulls a flag's value back out of that array.
    param([object[]]$ArgumentList, [Parameter(Mandatory)][string]$FlagName)
    if (-not $ArgumentList) { return $null }
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        if ($ArgumentList[$i] -eq $FlagName -and ($i + 1) -lt $ArgumentList.Count) {
            return $ArgumentList[$i + 1]
        }
    }
    return $null
}

function ConvertTo-CcodexHardTimeoutSec {
    # --hard-timeout-sec must be a non-negative whole number of seconds (0 = never). Before
    # this guard, a negative value silently fell back to "never" (since only >0 is ever
    # armed downstream) and non-numeric text threw a raw .NET cast error surfaced as an
    # unrelated wrapper-internal failure (exit 12) instead of a usage error naming the
    # flag. Both are usage errors now (exit 2), and 0 stays valid.
    param([Parameter(Mandatory)][string]$FlagName, [Parameter(Mandatory)][string]$ValueText)
    $parsed = 0
    if (-not [int]::TryParse($ValueText, [ref]$parsed) -or $parsed -lt 0) {
        throw "ccodex: $FlagName must be a non-negative whole number of seconds (0 = never); got '$ValueText'."
    }
    return $parsed
}

function Get-CcodexArgValues {
    # Repeatable-flag counterpart to Get-CcodexArgValue: collects EVERY value that
    # follows an occurrence of $FlagName in $args (e.g. `--path a --path b`). Always
    # returns an array (empty when the flag is absent) so callers can splat it into a
    # [string[]] parameter without null-vs-scalar surprises.
    param([object[]]$ArgumentList, [Parameter(Mandatory)][string]$FlagName)
    $values = @()
    if (-not $ArgumentList) { return , $values }
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        if ($ArgumentList[$i] -eq $FlagName -and ($i + 1) -lt $ArgumentList.Count) {
            $values += $ArgumentList[$i + 1]
        }
    }
    return , $values
}

if ($ImportOnly) { return }

$exitCode = 12
try {
    switch ($Command) {
        'run' {
            # Redirected stdin is read directly from the OS stream by
            # Get-CcodexPromptContent (via [Console]::OpenStandardInput); the
            # PowerShell pipeline ($input) path is intentionally not used here.
            # See the header comment for why. The PipelineExpected/PipelineObjects
            # parameters remain on Invoke-CcodexRun for direct/test callers.
            $runHardTimeoutSecText = Get-CcodexArgValue -ArgumentList $args -FlagName '--hard-timeout-sec'
            $runParams = @{
                Mode             = $Mode
                Access           = $Access
                RepoOverride     = $Repo
                PromptFile       = $PromptFile
                PositionalTask   = $PositionalTask
                PipelineExpected = $false
                PipelineObjects  = $null
            }
            if ($runHardTimeoutSecText) {
                try {
                    $runParams['HardTimeoutSec'] = ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText $runHardTimeoutSecText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }
            $runResult = Invoke-CcodexRun @runParams
            if ($runResult.WrapperExitCode -eq 0) {
                Write-Output $runResult.Stdout
            } else {
                Write-Host $runResult.Message
            }
            $exitCode = $runResult.WrapperExitCode
        }
        'submit' {
            # Mirrors `run`'s pipeline/stdin capture (see the header comment). --state-root,
            # --codex-path, --detach-mechanism are hidden test-support flags; production calls
            # never pass them, so LocalAppDataRoot/AppDataRoot default to the real
            # LOCALAPPDATA/APPDATA and the detached worker is launched via `cim` with no
            # env-var dependence.
            $submitStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $submitCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'
            $submitDetachMechanism = Get-CcodexArgValue -ArgumentList $args -FlagName '--detach-mechanism'
            $submitHardTimeoutSecText = Get-CcodexArgValue -ArgumentList $args -FlagName '--hard-timeout-sec'

            $submitParams = @{
                Mode             = $Mode
                Access           = $Access
                RepoOverride     = $Repo
                PromptFile       = $PromptFile
                PositionalTask   = $PositionalTask
                PipelineExpected = $false
                PipelineObjects  = $null
            }
            if ($submitStateRoot) { $submitParams['LocalAppDataRoot'] = $submitStateRoot }
            if ($submitCodexPath) { $submitParams['CodexPath'] = $submitCodexPath }
            if ($submitDetachMechanism) { $submitParams['DetachMechanism'] = $submitDetachMechanism }
            if ($submitHardTimeoutSecText) {
                try {
                    $submitParams['HardTimeoutSec'] = ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText $submitHardTimeoutSecText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }

            $submitResult = Invoke-CcodexSubmit @submitParams
            if ($submitResult.WrapperExitCode -eq 0) {
                Write-Output $submitResult.Stdout
            } else {
                Write-Host $submitResult.Message
            }
            $exitCode = $submitResult.WrapperExitCode
        }
        'worker' {
            # Internal entrypoint only: launched by the (future) `submit` detached
            # process, or directly in tests. Not documented/Claude-facing.
            $workerJobId = Get-CcodexArgValue -ArgumentList $args -FlagName '--job-id'
            $workerStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $workerCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'
            if (-not $workerJobId) {
                Write-Host "ccodex: worker requires --job-id <id>."
                $exitCode = 2
                break
            }
            $workerParams = @{ JobId = $workerJobId }
            if ($workerStateRoot) { $workerParams['StateRoot'] = $workerStateRoot }
            if ($workerCodexPath) { $workerParams['CodexPath'] = $workerCodexPath }
            $workerResult = Invoke-CcodexWorker @workerParams
            if ($workerResult.Message) {
                Write-Host $workerResult.Message
            }
            $exitCode = $workerResult.WrapperExitCode
        }
        'status' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit` use for their task text). --state-root is a hidden test flag.
            $statusJobId = $PositionalTask
            $statusStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $statusJobId) {
                Write-Host "ccodex: status requires a job id."
                $exitCode = 2
                break
            }
            $statusParams = @{ JobId = $statusJobId }
            if ($statusStateRoot) { $statusParams['StateRoot'] = $statusStateRoot }
            $statusResult = Invoke-CcodexStatusCommand @statusParams
            if ($statusResult.WrapperExitCode -eq 0) {
                Write-Output $statusResult.Stdout
            } else {
                Write-Host $statusResult.Message
            }
            $exitCode = $statusResult.WrapperExitCode
        }
        'wait' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status` use). --wait-timeout-sec/--state-root are flags.
            $waitJobId = $PositionalTask
            $waitStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $waitTimeoutSecText = Get-CcodexArgValue -ArgumentList $args -FlagName '--wait-timeout-sec'
            if (-not $waitJobId) {
                Write-Host "ccodex: wait requires a job id."
                $exitCode = 2
                break
            }
            $waitParams = @{ JobId = $waitJobId }
            if ($waitStateRoot) { $waitParams['StateRoot'] = $waitStateRoot }
            if ($waitTimeoutSecText) { $waitParams['WaitTimeoutSec'] = [int]$waitTimeoutSecText }
            $waitResult = Invoke-CcodexWaitCommand @waitParams
            if ($waitResult.WrapperExitCode -eq 0) {
                Write-Output $waitResult.Stdout
            } else {
                Write-Host $waitResult.Message
            }
            $exitCode = $waitResult.WrapperExitCode
        }
        'read' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait` use). --state-root is a hidden test flag.
            $readJobId = $PositionalTask
            $readStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $readJobId) {
                Write-Host "ccodex: read requires a job id."
                $exitCode = 2
                break
            }
            $readParams = @{ JobId = $readJobId }
            if ($readStateRoot) { $readParams['StateRoot'] = $readStateRoot }
            $readResult = Invoke-CcodexReadCommand @readParams
            if ($readResult.WrapperExitCode -eq 0) {
                Write-Output $readResult.Stdout
            } else {
                Write-Host $readResult.Message
            }
            $exitCode = $readResult.WrapperExitCode
        }
        'cancel' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait`/`read` use). --state-root is a hidden test flag.
            $cancelJobId = $PositionalTask
            $cancelStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $cancelJobId) {
                Write-Host "ccodex: cancel requires a job id."
                $exitCode = 2
                break
            }
            $cancelParams = @{ JobId = $cancelJobId }
            if ($cancelStateRoot) { $cancelParams['StateRoot'] = $cancelStateRoot }
            $cancelResult = Invoke-CcodexCancelCommand @cancelParams
            if ($cancelResult.WrapperExitCode -eq 0) {
                Write-Output $cancelResult.Stdout
            } else {
                Write-Host $cancelResult.Message
            }
            $exitCode = $cancelResult.WrapperExitCode
        }
        'review' {
            # Sugar over the `run` pipeline (mode review, access read-only): compose a
            # scoped-review prompt from the diff selector/paths, then hand the composed
            # text to Invoke-CcodexRun as the positional task. No second execution path —
            # same job artifacts, exit codes, and failure classification as `run`. Piped
            # stdin is NOT consumed by review (the task text is the composed prompt).
            # --repo binds to $Repo; --state-root/--codex-path are hidden test-support
            # flags mirroring the other subcommands.
            $reviewRange = Get-CcodexArgValue -ArgumentList $args -FlagName '--range'
            $reviewStaged = ($args -contains '--staged')
            $reviewWorking = ($args -contains '--working')
            $reviewEmbedDiff = ($args -contains '--embed-diff')
            $reviewIntent = Get-CcodexArgValue -ArgumentList $args -FlagName '--intent'
            $reviewFocus = Get-CcodexArgValue -ArgumentList $args -FlagName '--focus'
            $reviewPaths = Get-CcodexArgValues -ArgumentList $args -FlagName '--path'
            $reviewStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $reviewCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'

            # Resolve the repo up front: the self-diff prompt names it and the embed form
            # runs git from it. A bad --repo is a usage error (exit 2), same as `run`.
            try {
                $reviewRepoRoot = Resolve-CcodexRepo -RepoOverride $Repo
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }

            try {
                $reviewPrompt = Build-CcodexReviewPrompt -Range $reviewRange -Staged $reviewStaged -Working $reviewWorking `
                    -Paths $reviewPaths -Intent $reviewIntent -Focus $reviewFocus -EmbedDiff $reviewEmbedDiff -RepoRoot $reviewRepoRoot
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }

            $reviewParams = @{
                Mode             = 'review'
                Access           = $Access
                RepoOverride     = $Repo
                PromptFile       = $null
                PositionalTask   = $reviewPrompt
                PipelineExpected = $false
                PipelineObjects  = $null
            }
            if ($reviewStateRoot) { $reviewParams['LocalAppDataRoot'] = $reviewStateRoot }
            if ($reviewCodexPath) { $reviewParams['CodexPath'] = $reviewCodexPath }

            $reviewResult = Invoke-CcodexRun @reviewParams
            if ($reviewResult.WrapperExitCode -eq 0) {
                Write-Output $reviewResult.Stdout
            } else {
                Write-Host $reviewResult.Message
            }
            $exitCode = $reviewResult.WrapperExitCode
        }
        'tail' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait`/`read`/`cancel` use). --lines/--state-root are
            # flags; a bad --lines is a usage error (exit 2), same shape as --hard-timeout-sec.
            $tailJobId = $PositionalTask
            $tailStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $tailLinesText = Get-CcodexArgValue -ArgumentList $args -FlagName '--lines'
            if (-not $tailJobId) {
                Write-Host "ccodex: tail requires a job id."
                $exitCode = 2
                break
            }
            $tailParams = @{ JobId = $tailJobId }
            if ($tailStateRoot) { $tailParams['StateRoot'] = $tailStateRoot }
            if ($tailLinesText) {
                try {
                    $tailParams['Lines'] = ConvertTo-CcodexTailLinesCount -FlagName '--lines' -ValueText $tailLinesText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }
            $tailResult = Invoke-CcodexTailCommand @tailParams
            if ($tailResult.WrapperExitCode -eq 0) {
                Write-Output $tailResult.Stdout
            } else {
                Write-Host $tailResult.Message
            }
            $exitCode = $tailResult.WrapperExitCode
        }
        'cleanup' {
            # Retention sweep. --older-than <Nd|Nh> and --thread-ttl <Nd> override the
            # user-config thresholds; --repo binds to $Repo (narrows to that repo's key);
            # --dry-run/--include-stalled/--scrub-thread-ids are presence flags; --state-root
            # is a hidden test-support flag. Bad --older-than/--thread-ttl syntax is a usage
            # error (exit 2). Otherwise the engine is best-effort: exit 0, or 12 if any
            # individual delete/scrub failed.
            $cleanupStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $cleanupOlderThan = Get-CcodexArgValue -ArgumentList $args -FlagName '--older-than'
            $cleanupThreadTtl = Get-CcodexArgValue -ArgumentList $args -FlagName '--thread-ttl'

            $cleanupParams = @{
                RepoFilter     = $Repo
                DryRun         = ($args -contains '--dry-run')
                IncludeStalled = ($args -contains '--include-stalled')
                ScrubThreadIds = ($args -contains '--scrub-thread-ids')
            }
            if ($cleanupStateRoot) { $cleanupParams['StateRoot'] = $cleanupStateRoot }

            if ($cleanupOlderThan) {
                if ($cleanupOlderThan -notmatch '^\d+[dh]$') {
                    Write-Host "ccodex: --older-than must be <Nd|Nh> (e.g. 14d or 12h); got '$cleanupOlderThan'."
                    $exitCode = 2
                    break
                }
                $olderNum = [int]($cleanupOlderThan -replace '[dh]$', '')
                # h -> fractional days; d -> whole days.
                $cleanupParams['OlderThanDays'] = if ($cleanupOlderThan.EndsWith('h')) { $olderNum / 24.0 } else { $olderNum }
            }
            if ($cleanupThreadTtl) {
                if ($cleanupThreadTtl -notmatch '^\d+d?$') {
                    Write-Host "ccodex: --thread-ttl must be <Nd> (e.g. 30d); got '$cleanupThreadTtl'."
                    $exitCode = 2
                    break
                }
                $cleanupParams['ThreadTtlDays'] = [int]($cleanupThreadTtl -replace 'd$', '')
            }

            $cleanupResult = Invoke-CcodexCleanup @cleanupParams
            Write-Output $cleanupResult.Stdout
            $exitCode = $cleanupResult.WrapperExitCode
        }
        default {
            Write-Host "ccodex: command '$Command' is not implemented. Supported commands: run, review, submit, status, wait, read, cancel, tail, cleanup, worker."
            $exitCode = 2
        }
    }
} catch {
    Write-Host "ccodex: internal error: $($_.Exception.Message)"
    $exitCode = 12
}
exit $exitCode
