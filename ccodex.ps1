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
. (Join-Path $PSScriptRoot 'lib\JobList.ps1')
. (Join-Path $PSScriptRoot 'lib\Worker.ps1')
. (Join-Path $PSScriptRoot 'lib\Detach.ps1')
. (Join-Path $PSScriptRoot 'lib\ReviewPrompt.ps1')
. (Join-Path $PSScriptRoot 'lib\UserConfig.ps1')
. (Join-Path $PSScriptRoot 'lib\Cleanup.ps1')
. (Join-Path $PSScriptRoot 'lib\Worktree.ps1')
. (Join-Path $PSScriptRoot 'lib\Resume.ps1')

function Complete-CcodexInternalFailure {
    # A wrapper-internal failure after the job dir is reserved (codex path
    # resolution, or the launch/process step itself in the execution core, or
    # codex-path resolution inside `submit` before any worker is launched)
    # must still leave the design's completion evidence: a worker-complete.json
    # and a terminal failed status.json, both stamped wrapper_exit_code=12.
    # codex_exit_code stays null because Codex never produced one. A job must
    # never remain at a non-terminal status (e.g. `created`) after this runs.
    # Shared by the execution core and `submit`. It takes the per-job lock and
    # re-reads status before writing, so a concurrent cancel that already moved
    # the job to a terminal status (e.g. `cancelled`) is preserved rather than
    # clobbered with `failed`; only when the lock is contended (the paths reached
    # after a prior lock-acquisition already failed) does it fall through to an
    # unguarded write, since leaving the job non-terminal is the worse outcome.
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
        [string]$StderrPath = $null,
        # Phase 4: worktree jobs carry these on their initial status.json; preserve them on
        # the terminal failure write too (append-only). Null/absent for non-worktree jobs.
        [string]$MainRepo = $null,
        [string]$WorktreeRepo = $null,
        [string]$BaseCommit = $null,
        # Preserved onto the terminal failure status when a worktree finalization failure was
        # already detected before an internal-failure path was taken. Null/absent otherwise.
        [string]$WorktreeFinalizeError = $null,
        # Phase 5 resume lineage: carried onto the terminal failure status so a resumed job's
        # parentage survives even the internal-failure path. Null/absent for non-resume jobs.
        [string]$ParentJobId = $null,
        # Phase 5 resume: the parent's thread id, used as the codex_thread_id fallback when this
        # job's own events log carries no thread.started event (a resume continues the SAME thread,
        # so the parent's id is correct). Null for non-resume jobs (no fallback; unchanged).
        [string]$FallbackCodexThreadId = $null
    )
    $completedAt = (Get-Date).ToString('o')
    $resultPresent = $false
    if ($ResultPath) {
        try { $resultPresent = Test-Path -LiteralPath $ResultPath -PathType Leaf } catch { $resultPresent = $false }
    }

    $failureReason = Get-CcodexFailureReason -CodexExitCode $null -StderrPath $StderrPath -EventsPath $EventsPath
    $codexThreadId = Get-CcodexCodexThreadId -EventsPath $EventsPath
    if ([string]::IsNullOrEmpty($codexThreadId) -and -not [string]::IsNullOrEmpty($FallbackCodexThreadId)) { $codexThreadId = $FallbackCodexThreadId }
    $hintLine = Get-CcodexFailureHintLine -FailureReason $failureReason
    $hintedMessage = if ($hintLine) { "$Message`n  $hintLine" } else { $Message }

    $completeObj = New-CcodexWorkerCompleteObject -JobId $JobId -StatusCandidate 'failed' -CodexExitCode $null -WrapperExitCode 12 -ResultPresent $resultPresent -CompletedAt $completedAt
    $statusObj = New-CcodexStatusObject -JobId $JobId -Status 'failed' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -WrapperExitCode 12 -ErrorMessage $hintedMessage -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -FinishedAt $completedAt -FailureReason $failureReason -CodexThreadId $codexThreadId -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit -WorktreeFinalizeError $WorktreeFinalizeError -ParentJobId $ParentJobId

    # Guard the terminal write behind the per-job lock, re-reading status first so a concurrent
    # cancel that already reached a terminal status is preserved instead of clobbered with
    # 'failed'. ONE short attempt (no retry): in the common internal-failure paths (codex-path
    # resolution / launch throw) no lock is held and this acquires instantly; in the rare paths
    # reached only after a prior lock-acquisition already failed, the lock is contended and we
    # must not stall, so we fall through to the unguarded write (a non-terminal job is worse than
    # a rare cancelled->failed relabel).
    $acquired = $false
    try { Lock-CcodexJob -JobDir $JobDir -TimeoutSec 5 -CommandName 'internal-failure' | Out-Null; $acquired = $true } catch { $acquired = $false }
    try {
        if ($acquired) {
            $current = Read-CcodexStatusFile -JobDir $JobDir
            if (Test-CcodexTerminalStatus -StatusObject $current) {
                # A concurrent writer (in practice cancel) already decided this job's fate: leave
                # status.json exactly as-is and report the on-disk terminal outcome.
                return New-CcodexPreservedStatusResult -JobId $JobId -JobDir $JobDir -PreservedStatus $current
            }
        }
        Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'worker-complete.json') -Object $completeObj
        Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'status.json') -Object $statusObj
    } finally {
        if ($acquired) { Unlock-CcodexJob -JobDir $JobDir }
    }
    return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = "ccodex: internal error: $hintedMessage`n  job dir: $JobDir"; CodexExitCode = $null; Status = 'failed' }
}

function Write-CcodexStatusUnderLock {
    # Serializes a single status.json write behind the per-job lock so a concurrent
    # writer (cancel, cleanup, or read-side reconciliation) can never clobber it. The
    # lock is held only for the duration of this one write and released immediately
    # (try/finally), so it is free again while the long-running Codex process executes
    # between the `running` and terminal writes.
    #
    # RequireStatus/RequireBackendId (both optional): when RequireStatus is given, status.json
    # is RE-READ inside the lock (never from a stale pre-lock snapshot) and the write only
    # happens if the on-disk status still equals RequireStatus (and, when RequireBackendId is
    # also given, its backend_id still matches). This is how a terminal write (timed_out/
    # done/failed) avoids clobbering a status a concurrent cancel already moved off `running`
    # -- mirrors Update-CcodexHeartbeat's/Update-CcodexOrphanStatus's re-read-under-the-lock
    # idiom (lib/Worker.ps1, lib/JobStatus.ps1). Omit RequireStatus for a write that has no
    # such precondition (the initial created->running stamp below: the native worker path's
    # own equivalent transition is already guarded by Start-CcodexWorkerRunning).
    #
    # Returns a result object:
    #   LockAcquired=$false                 -> could not get the lock; nothing read or
    #                                           written; caller must force a terminal
    #                                           failure rather than die silently.
    #   LockAcquired=$true;  Written=$false -> RequireStatus was given and the on-disk
    #                                           status no longer matched; the write was
    #                                           skipped and CurrentStatus holds what IS on
    #                                           disk (preserved, not clobbered).
    #   LockAcquired=$true;  Written=$true  -> the write happened.
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$StatusPath,
        [Parameter(Mandatory)]$StatusObject,
        [string]$CommandName = 'worker',
        [int]$TimeoutSec = 10,
        [string]$RequireStatus = $null,
        [string]$RequireBackendId = $null
    )
    $acquired = $false
    try {
        Lock-CcodexJob -JobDir $JobDir -TimeoutSec $TimeoutSec -CommandName $CommandName | Out-Null
        $acquired = $true
    } catch {
        # This write is used by cancel. Retrying with the same timeout would turn a
        # caller's advertised bound into two full waits; a failed acquisition already
        # means no status write occurred, so report that result immediately.
        $acquired = $false
    }
    if (-not $acquired) {
        return [pscustomobject]@{ LockAcquired = $false; Written = $false; CurrentStatus = $null }
    }
    try {
        if ($RequireStatus) {
            $current = Read-CcodexStatusFile -JobDir $JobDir
            $statusMatches = ($null -ne $current) -and ($current.status -eq $RequireStatus)
            $backendMatches = (-not $RequireBackendId) -or ($null -ne $current -and [string]$current.backend_id -eq [string]$RequireBackendId)
            if (-not ($statusMatches -and $backendMatches)) {
                return [pscustomobject]@{ LockAcquired = $true; Written = $false; CurrentStatus = $current }
            }
        }
        Write-CcodexJsonFileAtomic -Path $StatusPath -Object $StatusObject
    } finally {
        Unlock-CcodexJob -JobDir $JobDir
    }
    return [pscustomobject]@{ LockAcquired = $true; Written = $true; CurrentStatus = $null }
}

function Test-CcodexTerminalStatus {
    # True only for the four statuses the design treats as terminal (done/failed/
    # timed_out/cancelled). Gates New-CcodexPreservedStatusResult: preserving "what's on
    # disk" as a decided outcome is only safe when what's on disk really is a terminal
    # outcome. A $null (unreadable) re-read, or a non-terminal status (created/running --
    # whether under this run's own backend_id or a foreign one), must NEVER be reported as
    # a preserved outcome; see the two call sites in Invoke-CcodexJobExecution.
    param($StatusObject)
    return ($null -ne $StatusObject) -and ($StatusObject.status -in @('done', 'failed', 'timed_out', 'cancelled'))
}

function New-CcodexPreservedStatusResult {
    # Builds the Invoke-CcodexJobExecution return value for the "terminal write skipped"
    # case: some concurrent writer (in practice only `cancel`) moved status.json off
    # `running` between this call's own running-write and its own terminal write, so
    # Write-CcodexStatusUnderLock's RequireStatus guard deliberately did not perform the
    # write. Report what IS on disk instead of what this call computed.
    #
    # CONTRACT: callers must only reach here when Test-CcodexTerminalStatus confirms
    # $PreservedStatus is a genuine terminal status. A $null/unreadable re-read, or a
    # readable-but-non-terminal status, must be routed elsewhere instead
    # (Complete-CcodexInternalFailure for the unreadable case; New-CcodexUnaccountedStatusResult
    # for the readable-non-terminal case) -- fabricating a success/"unknown" result for
    # either was a real bug: a non-terminal or unreadable job could make `run` report
    # WrapperExitCode 0 while the job was actually still running (or its state unknown).
    #
    # Wrapper-exit-code mapping mirrors Invoke-CcodexWaitCommand's own terminal-status
    # mapping: done -> 0; failed -> its recorded wrapper_exit_code if one of {10,11,12},
    # else 10; timed_out -> its recorded wrapper_exit_code if present, else 24;
    # cancelled -> 22 always (regardless of what's recorded).
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)]$PreservedStatus
    )
    $statusText = $PreservedStatus.status
    # Defensive parse: a preserved status.json may carry a malformed wrapper_exit_code
    # (corrupt/hand-edited file); an unparsable value falls back per status below.
    $recordedWrapperExitCode = $null
    if ($null -ne $PreservedStatus.wrapper_exit_code) {
        $parsedRecordedCode = 0
        if ([int]::TryParse([string]$PreservedStatus.wrapper_exit_code, [ref]$parsedRecordedCode)) {
            $recordedWrapperExitCode = $parsedRecordedCode
        }
    }
    $wrapperExitCode = switch ($statusText) {
        'cancelled' { 22 }
        'done' { 0 }
        'failed' { if ($recordedWrapperExitCode -in @(10, 11, 12)) { $recordedWrapperExitCode } else { 10 } }
        'timed_out' { if ($null -ne $recordedWrapperExitCode) { $recordedWrapperExitCode } else { 24 } }
        default { if ($null -ne $recordedWrapperExitCode) { $recordedWrapperExitCode } else { 0 } } # unreachable given the caller contract above
    }
    $message = "ccodex: job $JobId is '$statusText' (a concurrent writer changed its status before this run's own terminal write landed; leaving it as-is)`n  job dir: $JobDir"
    return [pscustomobject]@{ WrapperExitCode = $wrapperExitCode; Stdout = $null; Message = $message; CodexExitCode = $null; Status = $statusText }
}

function New-CcodexUnaccountedStatusResult {
    # Sibling to New-CcodexPreservedStatusResult for the OTHER outcome of a skipped
    # terminal write: the locked re-read came back READABLE but NON-terminal (e.g. still
    # `running`, possibly under a different backend_id than this run's own -- evidence
    # some other worker currently owns, or once owned, this job). Overwriting status.json
    # here would risk corrupting THAT worker's own eventual guarded terminal write (it
    # re-reads under the lock expecting to still see `running` + its own backend_id; if
    # this call clobbers it first, that worker's guard also mismatches and ITS real result
    # is silently dropped instead of this run's). So this path reports an internal failure
    # to THIS run's caller only and deliberately leaves status.json exactly as found --
    # unlike Complete-CcodexInternalFailure, which IS safe to call from the sibling
    # $null/unreadable case (there is no other writer's state to protect there, and a job
    # must never be left with zero terminal evidence at all).
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Message
    )
    return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = "ccodex: internal error: $Message`n  job dir: $JobDir"; CodexExitCode = $null; Status = 'failed' }
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
        # Phase 4 worktree wiring: when $WorktreeRepo is set the job runs `--access worktree`.
        # codex `-C` then targets the worktree (not the main repo), and after the process exits
        # the wrapper snapshots the worker's output via Complete-CcodexJobWorktree. $MainRepo/
        # $BaseCommit are carried onto every status.json write so the append-only worktree
        # fields survive the running/terminal transitions. All null => a normal (non-worktree)
        # job, byte-identical to before this parameter existed.
        [string]$MainRepo = $null,
        [string]$WorktreeRepo = $null,
        [string]$BaseCommit = $null,
        # 2a review minor: the native worker path already stamps its own `running`
        # status.json (with its own backend_id/started_at) before calling into this core;
        # without this switch the core's own running-write below duplicates that stamp with
        # identical content. `run` never passes this switch, so its behavior is unchanged.
        [switch]$SkipRunningWrite,
        # Best-effort heartbeat callback forwarded to Invoke-CcodexCodexProcess. The native
        # worker supplies one (it refreshes last_heartbeat_at in status.json); `run` (sync)
        # passes none, so the caller — which is actively watching — keeps its old behavior.
        [scriptblock]$OnHeartbeat = $null,
        # Phase 5 (resume): when supplied, this prebuilt codex argument array is used verbatim
        # instead of Build-CcodexCodexArgs (the resume path passes the `exec resume <thread>`
        # shape). `run`/`submit`/`worker` never pass it, so their argv is byte-identical to before.
        [string[]]$CodexArgs = $null,
        # Phase 5 (resume): stamped onto every status.json this core writes (running/terminal/
        # timeout) so a resumed job's lineage survives all transitions. Null for non-resume jobs.
        [string]$ParentJobId = $null,
        # Phase 5 (resume): the parent's Codex thread id. A resume continues the SAME thread, but
        # the resumed invocation may emit no thread.started event of its own — in which case
        # Get-CcodexCodexThreadId returns null and the child would end with a blank codex_thread_id,
        # breaking `ccodex resume <child>`. Used as the fallback for EVERY status write that stamps
        # codex_thread_id (created/running/terminal/timeout/internal-failure) whenever the
        # event-derived id is empty. Null for non-resume jobs => no fallback, behavior unchanged.
        [string]$FallbackCodexThreadId = $null,
        # Optional --model/--effort passthrough, forwarded to Build-CcodexCodexArgs. Ignored when
        # a prebuilt $CodexArgs is supplied (the resume path bakes them into its own argv). Both
        # absent => argv byte-identical to before these parameters existed.
        [string]$Model = $null,
        [string]$Effort = $null,
        # Opt-in: forward codex exec's `--skip-git-repo-check` (see Build-CcodexCodexArgs). Ignored
        # when a prebuilt $CodexArgs is supplied. Off by default => argv byte-identical to before.
        [switch]$SkipGitRepoCheck
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
        MainRepo = $MainRepo; WorktreeRepo = $WorktreeRepo; BaseCommit = $BaseCommit
        ParentJobId = $ParentJobId; FallbackCodexThreadId = $FallbackCodexThreadId
    }

    # For a worktree job Codex runs INSIDE the worktree (`-C <worktree>`); the main repo is
    # never handed to Codex and so is never mutated by the run. status.json's `repo` field
    # stays the main repo (RepoRoot) for continuity; the worktree is recorded separately.
    $codexTargetRepo = if ($WorktreeRepo) { $WorktreeRepo } else { $RepoRoot }

    try {
        $resolvedCodexPath = if ($CodexPath) { $CodexPath } else { Resolve-CcodexCodexPath }
    } catch {
        return Complete-CcodexInternalFailure @internalFailureParams -Message $_.Exception.Message
    }
    $codexArgs = if ($CodexArgs) { $CodexArgs } else { Build-CcodexCodexArgs -Access $Access -RepoRoot $codexTargetRepo -ResultPath $resultPath -Model $Model -Effort $Effort -SkipGitRepoCheck:$SkipGitRepoCheck }

    Write-CcodexTextFile -Path (Join-Path $JobDir 'command.txt') -Content (ConvertTo-CcodexCommandLineText -Executable $resolvedCodexPath -Arguments $codexArgs)
    Write-CcodexJsonFile -Path (Join-Path $JobDir 'debug.json') -Object (New-CcodexDebugObject -JobId $jobId -Repo $RepoRoot -JobDir $JobDir -Mode $Mode -Access $Access -CodexPath $resolvedCodexPath -CodexArgs $codexArgs -Backend $Backend -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit)

    # Diagnostic timing: the sync `run`/`resume` callers arrive with StartedAt empty (only the
    # native worker stamps its own, in Invoke-CcodexWorker, covering its detached-startup gap).
    # Left blank, status.json's started_at stays empty for every sync job, so codex runtime can
    # never be told apart from wrapper overhead after the fact. Stamp it HERE — after codex
    # path/args are resolved and immediately before the `running` write and process launch — so
    # a pre-launch internal failure (e.g. codex-path resolution) correctly leaves it empty, and
    # started_at -> finished_at tracks codex runtime (+ the fast finalize tail) rather than
    # wrapper setup. Guarded on empty so the native worker's own stamp is preserved unchanged
    # (native semantics byte-identical); internalFailureParams is refreshed in lockstep so a
    # post-launch internal failure reports the same started_at the terminal write would.
    if ([string]::IsNullOrEmpty($StartedAt)) {
        $StartedAt = (Get-Date).ToString('o')
        $internalFailureParams['StartedAt'] = $StartedAt
    }
    if (-not $SkipRunningWrite) {
        $runningWrite = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend `
            -StatusPath (Join-Path $JobDir 'status.json') `
            -StatusObject (New-CcodexStatusObject -JobId $jobId -Status 'running' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -HardTimeoutSec $hardTimeoutSecOrNull -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit -CodexThreadId $FallbackCodexThreadId -ParentJobId $ParentJobId)
        if (-not $runningWrite.LockAcquired) {
            return Complete-CcodexInternalFailure @internalFailureParams -Message 'could not acquire the job lock to record the running status'
        }
    }

    try {
        $codexExitCode = Invoke-CcodexCodexProcess -CodexPath $resolvedCodexPath -Arguments $codexArgs -PromptContent $WorkerPrompt -EventsLogPath $eventsPath -StderrLogPath $stderrPath -ExitCodeFilePath $exitCodeFilePath -HardTimeoutMs ($HardTimeoutSec * 1000) -OnHeartbeat $OnHeartbeat
    } catch {
        return Complete-CcodexInternalFailure @internalFailureParams -Message $_.Exception.Message
    }

    # Worktree snapshot finalization: after the Codex process (and its tree) has exited — for
    # ANY exit code, including the hard-timeout kill (null) below — stage and commit whatever
    # the worker left in the worktree so `diff`/`apply` have a deterministic <base>..HEAD range.
    # Best-effort: a git failure here must not derail the terminal status write, so a throw is
    # caught and recorded as "not committed" ($false) rather than propagated. worktree_committed
    # stays $null for non-worktree jobs.
    $worktreeCommitted = $null
    $worktreeFinalizeError = $null
    if ($WorktreeRepo) {
        try {
            $worktreeCommitted = [bool](Complete-CcodexJobWorktree -WorktreePath $WorktreeRepo -JobId $jobId).Committed
        } catch {
            # Finalization FAILED (git add/status/commit/rev-parse threw). worktree_committed=$false
            # here is indistinguishable from a clean empty-change run, so record the error text in a
            # dedicated field: it is the only reliable signal that uncommitted worker output may
            # still sit in the worktree and was never snapshot-committed. diff/apply key off it.
            $worktreeCommitted = $false
            $worktreeFinalizeError = $_.Exception.Message
        }
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
        if ([string]::IsNullOrEmpty($codexThreadId) -and -not [string]::IsNullOrEmpty($FallbackCodexThreadId)) { $codexThreadId = $FallbackCodexThreadId }
        $timeoutStatusObj = New-CcodexStatusObject -JobId $jobId -Status 'timed_out' -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -CodexExitCode $null -WrapperExitCode 24 -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -CodexThreadId $codexThreadId -HardTimeoutSec $HardTimeoutSec -TimeoutReason $timeoutReason -TerminatedAt $terminatedAt -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit -WorktreeCommitted $worktreeCommitted -WorktreeFinalizeError $worktreeFinalizeError -ParentJobId $ParentJobId
        $timeoutWrite = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend -StatusPath (Join-Path $JobDir 'status.json') -StatusObject $timeoutStatusObj -RequireStatus 'running' -RequireBackendId $BackendId
        if (-not $timeoutWrite.LockAcquired) {
            return Complete-CcodexInternalFailure @internalFailureParams -WorktreeFinalizeError $worktreeFinalizeError -Message 'could not acquire the job lock to record the timed_out status'
        }
        if (-not $timeoutWrite.Written) {
            # The job moved off `running` under us (e.g. a concurrent cancel) before this
            # write landed under the lock: its outcome is already decided elsewhere -- IF
            # what's on disk is a genuine terminal status. A $null/unreadable re-read, or a
            # readable-but-non-terminal one, is NOT a decided outcome; reporting either as
            # "preserved" would let this run report success/unknown over a job that is
            # actually still running or whose state is unknown.
            $preservedTimeout = $timeoutWrite.CurrentStatus
            if (Test-CcodexTerminalStatus -StatusObject $preservedTimeout) {
                return New-CcodexPreservedStatusResult -JobId $jobId -JobDir $JobDir -PreservedStatus $preservedTimeout
            }
            if ($null -eq $preservedTimeout) {
                return Complete-CcodexInternalFailure @internalFailureParams -WorktreeFinalizeError $worktreeFinalizeError -Message "job $jobId's status.json became unreadable during the timed_out write (expected to still be running under this run's backend_id); refusing to report a fabricated outcome"
            }
            return New-CcodexUnaccountedStatusResult -JobId $jobId -JobDir $JobDir -Message "job $jobId is unexpectedly '$($preservedTimeout.status)' (backend_id '$($preservedTimeout.backend_id)') during the timed_out write; leaving status.json untouched rather than reporting a fabricated outcome"
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
    if ([string]::IsNullOrEmpty($codexThreadId) -and -not [string]::IsNullOrEmpty($FallbackCodexThreadId)) { $codexThreadId = $FallbackCodexThreadId }

    $finalStatusObj = New-CcodexStatusObject -JobId $jobId -Status $validation.Status -Mode $Mode -Access $Access -Repo $RepoRoot -CreatedAt $CreatedAt -CodexExitCode $codexExitCode -WrapperExitCode $validation.WrapperExitCode -Backend $Backend -BackendId $BackendId -StartedAt $StartedAt -FinishedAt $finishedAt -FailureReason $failureReason -CodexThreadId $codexThreadId -HardTimeoutSec $hardTimeoutSecOrNull -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit -WorktreeCommitted $worktreeCommitted -WorktreeFinalizeError $worktreeFinalizeError -ParentJobId $ParentJobId
    $finalWrite = Write-CcodexStatusUnderLock -JobDir $JobDir -CommandName $Backend -StatusPath (Join-Path $JobDir 'status.json') -StatusObject $finalStatusObj -RequireStatus 'running' -RequireBackendId $BackendId
    if (-not $finalWrite.LockAcquired) {
        return Complete-CcodexInternalFailure @internalFailureParams -WorktreeFinalizeError $worktreeFinalizeError -Message 'could not acquire the job lock to record the terminal status'
    }
    if (-not $finalWrite.Written) {
        # Same race as the timed_out branch above: a concurrent writer (cancel) already
        # decided this job's fate -- IF what's on disk is a genuine terminal status. See
        # the identical three-way branch there for why a $null/unreadable or
        # readable-but-non-terminal re-read must never be reported as a preserved
        # (successful-looking) outcome.
        $preservedFinal = $finalWrite.CurrentStatus
        if (Test-CcodexTerminalStatus -StatusObject $preservedFinal) {
            return New-CcodexPreservedStatusResult -JobId $jobId -JobDir $JobDir -PreservedStatus $preservedFinal
        }
        if ($null -eq $preservedFinal) {
            return Complete-CcodexInternalFailure @internalFailureParams -WorktreeFinalizeError $worktreeFinalizeError -Message "job $jobId's status.json became unreadable during the terminal write (expected to still be running under this run's backend_id); refusing to report a fabricated outcome"
        }
        return New-CcodexUnaccountedStatusResult -JobId $jobId -JobDir $JobDir -Message "job $jobId is unexpectedly '$($preservedFinal.status)' (backend_id '$($preservedFinal.backend_id)') during the terminal write; leaving status.json untouched rather than reporting a fabricated outcome"
    }

    if ($validation.WrapperExitCode -eq 0) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null; CodexExitCode = $codexExitCode; Status = $validation.Status }
    }

    $hintLine = Get-CcodexFailureHintLine -FailureReason $failureReason
    $failureMessage = "ccodex: job $jobId $($validation.Status) (codex_exit_code=$codexExitCode, wrapper_exit_code=$($validation.WrapperExitCode))`n  job dir: $JobDir`n  result:  $resultPath"
    if ($hintLine) {
        $failureMessage += "`n  $hintLine"
    } else {
        # No recognized failure signature => no actionable hint. Surface the tail of stderr so
        # the real cause is visible in the CLI output instead of only in stderr.log.
        $stderrTail = Get-CcodexStderrTail -StderrPath $stderrPath
        if ($stderrTail) { $failureMessage += "`n  stderr (tail):`n$stderrTail" }
    }
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

    # Worktree access (implement, and opt-in test): create a detached worktree at the main
    # repo's current HEAD, under the state root (never inside the target repo). The worker then
    # sees the WORKTREE as {{REPO_ROOT}} and Codex runs `-C` the worktree, so the caller's tree
    # is never mutated by the run. Failure here is AFTER job-dir reservation, so it takes the
    # existing internal-failure path (terminal failed/12 with evidence) rather than a usage error.
    $mainRepo = $null
    $worktreeRepo = $null
    $baseCommit = $null
    $promptRepoRoot = $repoRoot
    if ($resolvedAccess -eq 'worktree') {
        try {
            $worktree = New-CcodexJobWorktree -MainRepo $repoRoot -JobId $jobId -StateRoot $LocalAppDataRoot
        } catch {
            $failure = Complete-CcodexInternalFailure -JobDir $jobDir -JobId $jobId -Mode $Mode -Access $resolvedAccess `
                -RepoRoot $repoRoot -CreatedAt $createdAt -Message $_.Exception.Message -Backend $Backend `
                -ResultPath (Join-Path $jobDir 'result.md')
            return [pscustomobject]@{ WrapperExitCode = 12; JobId = $jobId; JobDir = $jobDir; RepoRoot = $repoRoot; ResolvedAccess = $resolvedAccess; WorkerPrompt = $null; CreatedAt = $createdAt; Message = $failure.Message; MainRepo = $null; WorktreeRepo = $null; BaseCommit = $null }
        }
        $mainRepo = $repoRoot
        $worktreeRepo = $worktree.WorktreePath
        $baseCommit = $worktree.BaseCommit
        $promptRepoRoot = $worktreeRepo
    }

    # Artifacts stay under the job dir (never the worktree). Worktree access gets an artifact
    # dir exactly as workspace access does, so browser/test evidence has a home outside the repo.
    $artifactDir = $null
    if ($resolvedAccess -in @('workspace', 'worktree')) {
        $artifactDir = Join-Path $jobDir 'artifacts'
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }

    $templatePath = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $AppDataRoot
    $workerPrompt = Build-CcodexWorkerPrompt -TemplatePath $templatePath -Mode $Mode -Access $resolvedAccess -RepoRoot $promptRepoRoot -ArtifactDir $artifactDir -TaskContent $taskContent
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $workerPrompt

    $hardTimeoutSecOrNull = if ($HardTimeoutSec -gt 0) { $HardTimeoutSec } else { $null }
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status $InitialStatus -Mode $Mode -Access $resolvedAccess -Repo $repoRoot -CreatedAt $createdAt -Backend $Backend -HardTimeoutSec $hardTimeoutSecOrNull -MainRepo $mainRepo -WorktreeRepo $worktreeRepo -BaseCommit $baseCommit)

    return [pscustomobject]@{ WrapperExitCode = 0; JobId = $jobId; JobDir = $jobDir; RepoRoot = $repoRoot; ResolvedAccess = $resolvedAccess; WorkerPrompt = $workerPrompt; CreatedAt = $createdAt; Message = $null; MainRepo = $mainRepo; WorktreeRepo = $worktreeRepo; BaseCommit = $baseCommit }
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
        [int]$HardTimeoutSec = 0,
        # Optional --model/--effort passthrough (effort already validated at the dispatcher).
        [string]$Model = $null,
        [string]$Effort = $null,
        # Opt-in `ccodex run --skip-git-repo-check`: forwarded to the execution core so a non-git
        # (or untrusted) target repo is accepted instead of failing codex's trusted-directory check.
        [switch]$SkipGitRepoCheck
    )

    $init = Initialize-CcodexJob -Mode $Mode -Access $Access -RepoOverride $RepoOverride -PromptFile $PromptFile `
        -PositionalTask $PositionalTask -PipelineExpected $PipelineExpected -PipelineObjects $PipelineObjects `
        -LocalAppDataRoot $LocalAppDataRoot -AppDataRoot $AppDataRoot -InitialStatus 'created' -Backend 'sync' -HardTimeoutSec $HardTimeoutSec

    if ($init.WrapperExitCode -ne 0) {
        return [pscustomobject]@{ WrapperExitCode = $init.WrapperExitCode; Stdout = $null; JobDir = $init.JobDir; Message = $init.Message }
    }

    $coreResult = Invoke-CcodexJobExecution -JobDir $init.JobDir -RepoRoot $init.RepoRoot -Mode $Mode -Access $init.ResolvedAccess -WorkerPrompt $init.WorkerPrompt -CodexPath $CodexPath -CreatedAt $init.CreatedAt -HardTimeoutSec $HardTimeoutSec -MainRepo $init.MainRepo -WorktreeRepo $init.WorktreeRepo -BaseCommit $init.BaseCommit -Model $Model -Effort $Effort -SkipGitRepoCheck:$SkipGitRepoCheck

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Stdout = $coreResult.Stdout; JobDir = $init.JobDir; Message = $coreResult.Message }
}

function Invoke-CcodexResume {
    # Phase 5 multi-turn advisor: continue a finished job's Codex thread with a follow-up.
    # ALWAYS creates a NEW job (new id, new job dir); the parent job dir and its status.json
    # are strictly read-only here (only Get-CcodexResumeContext reads them). The child inherits
    # the parent's mode/access/repo and stamps parent_job_id on its status.json for lineage.
    #
    # Unlike `run`, resume does NOT render the worker-prompt template: the Codex session already
    # carries the full prior context, so prompt.md (and the stdin handed to Codex) is exactly the
    # follow-up text. Codex is invoked via the Task-1 `exec resume <thread>` argument shape, fed
    # to the shared execution core through its -CodexArgs override so result validation, failure
    # classification, and the terminal status write are identical to `run`.
    param(
        [Parameter(Mandatory)][string]$ParentJobId,
        # The same prompt-source params as Invoke-CcodexRun; the composed follow-up becomes both
        # prompt.md and the stdin handed to Codex.
        [string]$PromptFile,
        [string]$PositionalTask,
        [bool]$PipelineExpected,
        [object[]]$PipelineObjects,
        [string]$CodexPath,
        [string]$LocalAppDataRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA,
        [int]$HardTimeoutSec = 0,
        # Optional --model/--effort passthrough. Unlike --repo/--mode/--access (inherited parent
        # context, rejected at the dispatcher), these are per-invocation knobs: a follow-up may
        # legitimately want a different model/effort than the parent ran with.
        [string]$Model = $null,
        [string]$Effort = $null
    )

    # Resolve the parent context first. Get-CcodexResumeContext's three throw classes map to
    # the documented precondition exit codes by message shape: not-found (no index entry, or
    # a missing job dir) -> 3; still-running (non-terminal parent) -> 4; every other rejection
    # (worktree access, or an absent/scrubbed thread id) -> 2.
    try {
        $ctx = Get-CcodexResumeContext -ParentJobId $ParentJobId -StateRoot $LocalAppDataRoot
    } catch {
        $message = $_.Exception.Message
        $exitCode = if ($message -like '*not found (no index entry)*' -or $message -like '*index entry exists but its job directory is missing*') {
            3
        } elseif ($message -like '*resume requires the parent job to be finished*') {
            4
        } else {
            2
        }
        return [pscustomobject]@{ WrapperExitCode = $exitCode; Stdout = $null; JobDir = $null; JobId = $null; Message = $message }
    }

    # Follow-up text via the standard prompt-source machinery; usage errors map to 2 with the
    # exact same messages as `run` (multiple sources, empty stdin, etc.).
    try {
        $followUp = Get-CcodexPromptContent `
            -ExpectingPipelineInput $PipelineExpected `
            -PipelineObjects $PipelineObjects `
            -PromptFile $PromptFile `
            -PositionalTask $PositionalTask `
            -StdinStream ([Console]::OpenStandardInput()) `
            -StdinIsRedirected ([Console]::IsInputRedirected)
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; JobDir = $null; JobId = $null; Message = $_.Exception.Message }
    }

    # Reserve a NEW job dir (mode = parent's mode) + index entry, inherit the parent's repo.
    $repoRoot = $ctx.Repo
    $repoKey = Get-CcodexRepoKey -RepoRoot $repoRoot
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $ctx.Mode -Root $LocalAppDataRoot
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $LocalAppDataRoot
    $createdAt = (Get-Date).ToString('o')

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
        Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })

        # prompt.md is the follow-up text only (no worker-prompt template on resume).
        Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $followUp

        $hardTimeoutSecOrNull = if ($HardTimeoutSec -gt 0) { $HardTimeoutSec } else { $null }
        # Initial status carries parent_job_id + the parent-inherited mode/access/repo, and the
        # parent's thread id (a resume continues the SAME thread) so the child is resumable from the
        # moment it is created, even before its own events log is written.
        Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status 'created' -Mode $ctx.Mode -Access $ctx.Access -Repo $repoRoot -CreatedAt $createdAt -Backend 'sync' -HardTimeoutSec $hardTimeoutSecOrNull -CodexThreadId $ctx.ThreadId -ParentJobId $ParentJobId)
    } catch {
        $initializationError = $_.Exception.Message
        $failureRecorded = $false
        try {
            $failureStatus = New-CcodexStatusObject -JobId $jobId -Status 'failed' -Mode $ctx.Mode -Access $ctx.Access -Repo $repoRoot -CreatedAt $createdAt -Backend 'sync' -CodexExitCode $null -WrapperExitCode 12 -CodexThreadId $ctx.ThreadId -ParentJobId $ParentJobId
            $failureStatus.finished_at = (Get-Date).ToString('o')
            $failureStatus.error = "resume initialization failed: $initializationError"
            Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $failureStatus
            Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'worker-complete.json') -Object ([ordered]@{ job_id = $jobId; status = 'failed'; wrapper_exit_code = 12; completed_at = (Get-Date).ToString('o'); error = $failureStatus.error })
            $failureRecorded = $true
        } catch { $failureRecorded = $false }
        if (-not $failureRecorded) {
            # Do not leave a reservation that index-based commands can resolve but whose
            # lifecycle has no terminal evidence.
            try { if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath -Force -ErrorAction Stop } } catch { }
            try { if (Test-Path -LiteralPath $jobDir) { Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction Stop } } catch { }
        }
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; JobDir = $(if ($failureRecorded) { $jobDir } else { $null }); JobId = $jobId; Message = "ccodex: resume initialization failed: $initializationError" }
    }

    $resumeArgs = Build-CcodexResumeArgs -ThreadId $ctx.ThreadId -Access $ctx.Access -RepoRoot $repoRoot -ResultPath (Join-Path $jobDir 'result.md') -Model $Model -Effort $Effort

    $coreResult = Invoke-CcodexJobExecution -JobDir $jobDir -RepoRoot $repoRoot -Mode $ctx.Mode -Access $ctx.Access `
        -WorkerPrompt $followUp -CodexPath $CodexPath -CreatedAt $createdAt -HardTimeoutSec $HardTimeoutSec `
        -CodexArgs $resumeArgs -ParentJobId $ParentJobId -FallbackCodexThreadId $ctx.ThreadId

    return [pscustomobject]@{ WrapperExitCode = $coreResult.WrapperExitCode; Stdout = $coreResult.Stdout; JobDir = $jobDir; JobId = $jobId; Message = $coreResult.Message }
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
        [string]$WorkerScriptPath = $PSCommandPath,
        # Optional --model/--effort passthrough. status.json deliberately carries neither
        # (append-only contract; they are per-invocation knobs, not job lifecycle state), so
        # they must reach the detached worker via its launch command line — the worker
        # re-derives command.txt/debug.json and the actual codex argv from what it received.
        [string]$Model = $null,
        [string]$Effort = $null
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
            -RepoRoot $init.RepoRoot -CreatedAt $init.CreatedAt -Message $_.Exception.Message -Backend 'native' -ResultPath $resultPath `
            -MainRepo $init.MainRepo -WorktreeRepo $init.WorktreeRepo -BaseCommit $init.BaseCommit
        $message = "$($failure.Message)`n  job:      $jobId"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; JobDir = $jobDir; JobId = $jobId; Message = $message }
    }

    # Pre-launch diagnostics only (the detached worker re-derives and overwrites both from
    # status.json). For a worktree job Codex targets the worktree, so reflect that here too.
    $submitCodexTargetRepo = if ($init.WorktreeRepo) { $init.WorktreeRepo } else { $init.RepoRoot }
    $codexArgs = Build-CcodexCodexArgs -Access $init.ResolvedAccess -RepoRoot $submitCodexTargetRepo -ResultPath $resultPath -Model $Model -Effort $Effort
    Write-CcodexTextFile -Path (Join-Path $jobDir 'command.txt') -Content (ConvertTo-CcodexCommandLineText -Executable $resolvedCodexPath -Arguments $codexArgs)
    Write-CcodexJsonFile -Path (Join-Path $jobDir 'debug.json') -Object (New-CcodexDebugObject -JobId $jobId -Repo $init.RepoRoot -JobDir $jobDir -Mode $Mode -Access $init.ResolvedAccess -CodexPath $resolvedCodexPath -CodexArgs $codexArgs -Backend 'native' -MainRepo $init.MainRepo -WorktreeRepo $init.WorktreeRepo -BaseCommit $init.BaseCommit)

    $stateRootOverride = if ($PSBoundParameters.ContainsKey('LocalAppDataRoot')) { $LocalAppDataRoot } else { $null }
    $codexPathOverride = if ($PSBoundParameters.ContainsKey('CodexPath')) { $CodexPath } else { $null }

    try {
        Start-CcodexDetachedWorker -ScriptPath $WorkerScriptPath -JobId $jobId -WorkingDirectory $init.RepoRoot `
            -StateRoot $stateRootOverride -CodexPath $codexPathOverride -Mechanism $DetachMechanism `
            -Model $Model -Effort $Effort | Out-Null
        Wait-CcodexWorkerLaunch -JobDir $jobDir -TimeoutSec $StartupTimeoutSec | Out-Null
    } catch {
        # Do NOT rewrite status.json here: a slow-but-alive worker may still be starting,
        # and the job must stay diagnosable in its current ('created') state.
        $message = "ccodex: $($_.Exception.Message)`n  job:      $jobId`n  job dir:  $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 23; Stdout = $null; JobDir = $jobDir; JobId = $jobId; Message = $message }
    }

    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$jobId`n$jobDir"; JobDir = $jobDir; JobId = $jobId; Message = $null }
}

function New-CcodexLifecycleErrorResult {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    $envelope = [ordered]@{
        schema_version    = 1
        job_id            = $JobId
        status            = 'unknown'
        error             = $ErrorMessage
        job_dir           = $null
        command_exit_code = 3
    }
    return [pscustomobject]@{ WrapperExitCode = 3; Stdout = ($envelope | ConvertTo-Json -Depth 10); Message = $null }
}

function New-CcodexWaitJsonResult {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()][object]$StatusObject,
        [Parameter(Mandatory)][object]$Reconciliation,
        [Parameter(Mandatory)][string]$JobDir,
        [AllowNull()][object]$Result,
        [Parameter(Mandatory)][int]$CommandExitCode
    )

    $envelope = [ordered]@{
        schema_version    = 1
        job_id            = $JobId
        status            = $Status
        codex_exit_code   = if ($StatusObject) { $StatusObject.codex_exit_code } else { $null }
        wrapper_exit_code = if ($StatusObject) { $StatusObject.wrapper_exit_code } else { $null }
        result            = $Result
        timeout_reason    = if ($StatusObject) { $StatusObject.timeout_reason } else { $null }
        health            = if ($Reconciliation.PossiblyStale) { 'possibly-stale' } else { $null }
        job_dir           = $JobDir
        command_exit_code = $CommandExitCode
    }
    return [pscustomobject]@{ WrapperExitCode = $CommandExitCode; Stdout = ($envelope | ConvertTo-Json -Depth 10); Message = $null }
}

function New-CcodexReadJsonResult {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][bool]$Finished,
        [Parameter(Mandatory)][bool]$ResultPresent,
        [AllowNull()][object]$Result,
        [Parameter(Mandatory)][object]$Reconciliation,
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][int]$CommandExitCode
    )

    $envelope = [ordered]@{
        schema_version    = 1
        job_id            = $JobId
        status            = $Status
        finished          = $Finished
        result_present    = $ResultPresent
        result            = $Result
        health            = if ($Reconciliation.PossiblyStale) { 'possibly-stale' } else { $null }
        job_dir           = $JobDir
        command_exit_code = $CommandExitCode
    }
    return [pscustomobject]@{ WrapperExitCode = $CommandExitCode; Stdout = ($envelope | ConvertTo-Json -Depth 10); Message = $null }
}

function Invoke-CcodexStatusCommand {
    # Read-only lifecycle report for a job id, callable from any directory. Reconciles
    # a narrowly-gated orphan (dead worker + completion evidence) via
    # Update-CcodexOrphanStatus before composing the line; never writes otherwise.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [switch]$Json,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        if ($Json) {
            return (New-CcodexLifecycleErrorResult -JobId $JobId -ErrorMessage $_.Exception.Message)
        }
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $reconciliation = Update-CcodexOrphanStatus -JobDir $record.JobDir
    $statusObj = Read-CcodexStatusFile -JobDir $record.JobDir

    $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    $codexExitCode = if ($statusObj) { $statusObj.codex_exit_code } else { $null }
    $wrapperExitCode = if ($statusObj) { $statusObj.wrapper_exit_code } else { $null }
    $health = if ($reconciliation.PossiblyStale) { 'possibly-stale' } else { Get-CcodexJobHealth -Status $statusObj }
    $parentJobId = if ($statusObj) { $statusObj.parent_job_id } else { $null }

    if ($Json) {
        $envelope = [ordered]@{
            schema_version    = 1
            job_id            = $JobId
            status            = $statusText
            codex_exit_code   = $codexExitCode
            wrapper_exit_code = $wrapperExitCode
            health            = $health
            parent_job_id     = $parentJobId
            job_dir           = $record.JobDir
            command_exit_code = 0
        }
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = ($envelope | ConvertTo-Json -Depth 10); Message = $null }
    }

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

    if (-not [string]::IsNullOrEmpty([string]$parentJobId)) {
        $line += " parent=$parentJobId"
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
        [switch]$Json,
        [int]$WaitTimeoutSec = 0,
        [int]$PollIntervalMs = 1000,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        if ($Json) {
            return (New-CcodexLifecycleErrorResult -JobId $JobId -ErrorMessage $_.Exception.Message)
        }
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $resultPath = Join-Path $jobDir 'result.md'
    $deadline = if ($WaitTimeoutSec -gt 0) { (Get-Date).AddSeconds($WaitTimeoutSec) } else { $null }

    while ($true) {
        $reconciliation = $null
        if ($deadline) {
            $remainingSec = ($deadline - (Get-Date)).TotalSeconds
            if ($remainingSec -gt 0) {
                # Reconciliation is a writer and can wait on the job lock. Give it no
                # more than this wait invocation has left, rather than its 10s default.
                $reconciliationTimeoutSec = [Math]::Max(0, [int][Math]::Floor($remainingSec))
                $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir -LockTimeoutSec $reconciliationTimeoutSec
            } else {
                # At the deadline, do one ordinary status read below but never begin a
                # lock wait that would make `--wait-timeout-sec` overrun.
                $reconciliation = [pscustomobject]@{ Status = $null; PossiblyStale = $false }
            }
        } else {
            $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
        }
        $statusObj = Read-CcodexStatusFile -JobDir $jobDir
        $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
        if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

        if ($statusText -eq 'done') {
            $recordedCodexExitCode = if ($statusObj -and $null -ne $statusObj.codex_exit_code) { [int]$statusObj.codex_exit_code } else { 0 }
            $validation = Test-CcodexResult -CodexExitCode $recordedCodexExitCode -ResultPath $resultPath
            if ($validation.WrapperExitCode -eq 0) {
                if ($Json) {
                    return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $validation.ResultContent -CommandExitCode 0)
                }
                return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null }
            }
            $failureMessage = "ccodex: job $JobId done but result.md is missing or empty (codex_exit_code=$recordedCodexExitCode)`n  job dir: $jobDir`n  result:  $resultPath"
            if ($Json) {
                return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $null -CommandExitCode 11)
            }
            return [pscustomobject]@{ WrapperExitCode = 11; Stdout = $null; Message = $failureMessage }
        }

        if ($statusText -eq 'failed') {
            $codexExitText = if ($statusObj -and $null -ne $statusObj.codex_exit_code) { $statusObj.codex_exit_code } else { 'null' }
            $recordedWrapperExitCode = if ($statusObj) { $statusObj.wrapper_exit_code } else { $null }
            $wrapperExitText = if ($null -eq $recordedWrapperExitCode) { 'null' } else { $recordedWrapperExitCode }
            $exitCodeToReturn = if ($recordedWrapperExitCode -in @(10, 11, 12)) { $recordedWrapperExitCode } else { 10 }
            $failureMessage = "ccodex: job $JobId failed codex_exit_code=$codexExitText wrapper_exit_code=$wrapperExitText`n  job dir: $jobDir`n  result:  $resultPath"
            if ($Json) {
                return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $null -CommandExitCode $exitCodeToReturn)
            }
            return [pscustomobject]@{ WrapperExitCode = $exitCodeToReturn; Stdout = $null; Message = $failureMessage }
        }

        if ($statusText -eq 'timed_out') {
            # Terminal hard-timeout: return the recorded wrapper exit code (24).
            $recordedWrapperExitCode = if ($statusObj -and $null -ne $statusObj.wrapper_exit_code) { [int]$statusObj.wrapper_exit_code } else { 24 }
            $timeoutReasonText = if ($statusObj -and $statusObj.timeout_reason) { " ($($statusObj.timeout_reason))" } else { '' }
            $timeoutMessage = "ccodex: job $JobId timed_out$timeoutReasonText`n  job dir: $jobDir"
            if ($Json) {
                return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $null -CommandExitCode $recordedWrapperExitCode)
            }
            return [pscustomobject]@{ WrapperExitCode = $recordedWrapperExitCode; Stdout = $null; Message = $timeoutMessage }
        }

        if ($statusText -eq 'cancelled') {
            # Terminal cancellation (Task 4): concise status line, wrapper exit 22.
            $cancelledMessage = "ccodex: job $JobId cancelled`n  job dir: $jobDir"
            if ($Json) {
                return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $null -CommandExitCode 22)
            }
            return [pscustomobject]@{ WrapperExitCode = 22; Stdout = $null; Message = $cancelledMessage }
        }

        if ($deadline -and (Get-Date) -ge $deadline) {
            $line = "$JobId $statusText"
            if ($reconciliation.PossiblyStale) { $line += ' health=possibly-stale' }
            $message = "$line`nccodex: wait timed out after ${WaitTimeoutSec}s; re-run ``ccodex wait $JobId`` to keep waiting."
            if ($Json) {
                return (New-CcodexWaitJsonResult -JobId $JobId -Status $statusText -StatusObject $statusObj -Reconciliation $reconciliation -JobDir $jobDir -Result $null -CommandExitCode 20)
            }
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
        [switch]$Json,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        if ($Json) {
            return (New-CcodexLifecycleErrorResult -JobId $JobId -ErrorMessage $_.Exception.Message)
        }
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message }
    }

    $jobDir = $record.JobDir
    $resultPath = Join-Path $jobDir 'result.md'

    $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
    $statusObj = Read-CcodexStatusFile -JobDir $jobDir
    $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    if ($statusText -notin @('done', 'failed', 'timed_out', 'cancelled')) {
        if ($Json) {
            return (New-CcodexReadJsonResult -JobId $JobId -Status $statusText -Finished $false -ResultPresent $false -Result $null -Reconciliation $reconciliation -JobDir $jobDir -CommandExitCode 4)
        }
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
        if ($Json) {
            return (New-CcodexReadJsonResult -JobId $JobId -Status $statusText -Finished $true -ResultPresent $true -Result $validation.ResultContent -Reconciliation $reconciliation -JobDir $jobDir -CommandExitCode 0)
        }
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $validation.ResultContent; Message = $null }
    }

    $failureMessage = "ccodex: job $JobId $statusText but result.md is missing or empty`n  job dir: $jobDir`n  result:  $resultPath"
    if ($Json) {
        return (New-CcodexReadJsonResult -JobId $JobId -Status $statusText -Finished $true -ResultPresent $false -Result $null -Reconciliation $reconciliation -JobDir $jobDir -CommandExitCode 11)
    }
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
        [string]$StateRoot = $env:LOCALAPPDATA,
        # Wall-clock bound for polling worker death after the kill request is issued.
        # Overridable for tests; production callers keep the 10s default.
        [int]$KillPollTimeoutSec = 10
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

    # Everything after the lock is acquired runs inside try/finally so the lock is ALWAYS
    # released — an unexpected throw (write failure, taskkill launch failure, a malformed
    # backend_id, etc.) must never leak `.lock\` and wedge the job. Branches decide via
    # result variables instead of early `return`s that would skip the finally: $result
    # holds the outcome to return directly, and $needsReconcile defers the dead-worker
    # orphan path until AFTER the lock is released (Update-CcodexOrphanStatus takes its own
    # lock, so calling it while still holding this one would deadlock the retry loop).
    $result = $null
    $needsReconcile = $false
    try {
        $status = Read-CcodexStatusFile -JobDir $jobDir
        if ($null -eq $status) {
            $message = "ccodex: internal error: job '$JobId' has no readable status.json.`n  job dir: $jobDir"
            $result = [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
        }
        elseif ($status.status -in $terminalStatuses) {
            # No-op: already terminal (whichever terminal status). Nothing to mutate.
            $result = [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId already $($status.status)"; Message = $null }
        }
        elseif ($status.status -eq 'running' -and -not (Test-CcodexWorkerAlive -BackendId $status.backend_id)) {
            # The recorded worker identity is dead: this is not a live job to kill, it is
            # an orphan. Defer to the same evidence-based reconciliation `status`/`wait`/
            # `read` perform, rather than forcing `cancelled` over a job that actually
            # completed (or failed) before the cancel request arrived. Run it after the
            # finally releases the lock (see $needsReconcile note above).
            $needsReconcile = $true
        }
        else {
            # Reached for `running` with a live worker, or `created` (never started).
            $killFailed = $false
            if ($status.status -eq 'running') {
                # Worker identity verified alive: force-kill the whole process tree (the
                # worker process itself AND whatever codex child it spawned), then poll for
                # actual death -- taskkill returns once the kill request is issued, not once
                # the process tree has actually exited. Parse the pid defensively so a
                # malformed backend_id cannot throw out of the lock (Test-CcodexWorkerAlive
                # already validated it above, but the lock release must not depend on that).
                $backendParts = $status.backend_id.Split(';', 2)
                $workerPid = 0
                if ([int]::TryParse($backendParts[0], [ref]$workerPid)) {
                    Stop-CcodexProcessTree -ProcessId $workerPid
                    $killDeadline = (Get-Date).AddSeconds($KillPollTimeoutSec)
                    while ((Get-Date) -lt $killDeadline -and (Test-CcodexWorkerAlive -BackendId $status.backend_id)) {
                        Start-Sleep -Milliseconds 200
                    }
                }
                # Stop-CcodexProcessTree is best-effort (it swallows taskkill launch/exit
                # failures), so re-verify aliveness after the poll deadline before declaring
                # the job cancelled. If the worker is STILL alive, writing `cancelled` now
                # would race the live worker's own terminal status write
                # (Invoke-CcodexJobExecution): that write could still land later and
                # overwrite this cancellation right back to `done`/`failed`. Report the kill
                # failure instead and leave status.json exactly as it was -- the job really
                # is still running.
                if (Test-CcodexWorkerAlive -BackendId $status.backend_id) {
                    $killFailed = $true
                }
            }

            if ($killFailed) {
                $message = "ccodex: internal error: failed to terminate the worker process for job '$JobId' (backend_id=$($status.backend_id)); the job is still running.`n  job dir: $jobDir"
                $result = [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
            } else {
                # Mark the job cancelled directly, preserving every existing field (append-only)
                # and stamping cancelled_at. wrapper_exit_code is left exactly as it was (null
                # for a job that never reached a terminal codex exit code).
                $cancelledAt = (Get-Date).ToUniversalTime().ToString('o')
                $updated = [ordered]@{}
                foreach ($property in $status.PSObject.Properties) {
                    $updated[$property.Name] = $property.Value
                }
                $updated['status'] = 'cancelled'
                $updated['cancelled_at'] = $cancelledAt
                Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $updated
                $result = [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId cancelled"; Message = $null }
            }
        }
    } finally {
        Unlock-CcodexJob -JobDir $jobDir
    }

    if ($needsReconcile) {
        $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
        $reconciledStatus = Read-CcodexStatusFile -JobDir $jobDir
        $finalStatusText = if ($reconciledStatus) { $reconciledStatus.status } else { $reconciliation.Status }
        if ([string]::IsNullOrEmpty($finalStatusText)) { $finalStatusText = 'unknown' }
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$JobId $finalStatusText"; Message = $null }
    }

    return $result
}

function Resolve-CcodexWorktreeJobContext {
    # Shared precondition chain for `diff`/`apply` (Phase 4 Tasks 4/5): resolve the job,
    # reconcile a narrowly-gated orphan exactly as status/wait/read do, then verify the job
    # is terminal, was run with `--access worktree`, and its worktree still exists on disk.
    # Returns WrapperExitCode=0 with the resolved job/worktree fields on success; any
    # nonzero WrapperExitCode is a fully-formed error result the caller can return as-is.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    try {
        $record = Get-CcodexJobRecord -JobId $JobId -Root $StateRoot
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $_.Exception.Message; JobDir = $null; StatusObject = $null; WorktreePath = $null; BaseCommit = $null; MainRepo = $null }
    }

    $jobDir = $record.JobDir
    $reconciliation = Update-CcodexOrphanStatus -JobDir $jobDir
    $statusObj = Read-CcodexStatusFile -JobDir $jobDir
    $statusText = if ($statusObj) { $statusObj.status } else { $reconciliation.Status }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    $terminalStatuses = @('done', 'failed', 'timed_out', 'cancelled')
    if ($statusText -notin $terminalStatuses) {
        $line = "$JobId $statusText"
        if ($reconciliation.PossiblyStale) { $line += ' health=possibly-stale' }
        $message = "$line`nccodex: job $JobId is not finished yet; run ``ccodex wait $JobId`` to block until it completes."
        return [pscustomobject]@{ WrapperExitCode = 4; Stdout = $null; Message = $message; JobDir = $jobDir; StatusObject = $statusObj; WorktreePath = $null; BaseCommit = $null; MainRepo = $null }
    }

    $worktreePath = if ($statusObj) { [string]$statusObj.worktree_repo } else { $null }
    if ([string]::IsNullOrEmpty($worktreePath)) {
        $accessText = if ($statusObj -and $statusObj.access) { $statusObj.access } else { 'unknown' }
        $message = "ccodex: job $JobId has no worktree (access=$accessText); this command requires a job run with --access worktree.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $message; JobDir = $jobDir; StatusObject = $statusObj; WorktreePath = $null; BaseCommit = $null; MainRepo = $null }
    }

    if (-not (Test-Path -LiteralPath $worktreePath -PathType Container)) {
        $message = "ccodex: worktree removed; artifacts remain at $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 3; Stdout = $null; Message = $message; JobDir = $jobDir; StatusObject = $statusObj; WorktreePath = $null; BaseCommit = $null; MainRepo = $null }
    }

    # Worktree snapshot finalization failed for this job: the worker's edits were never captured
    # into a <base>..HEAD commit, so diff/apply would silently see an empty range and report a
    # misleading no-op. Refuse (exit 12) instead, naming the worktree so the operator can inspect
    # the uncommitted output there. (worktree_committed=$false alone does NOT trigger this — that
    # also happens on a clean empty-change run; only a recorded finalize error does.)
    $finalizeError = if ($statusObj) { [string]$statusObj.worktree_finalize_error } else { $null }
    if (-not [string]::IsNullOrEmpty($finalizeError)) {
        $message = "ccodex: job $JobId's worktree snapshot was never committed (finalization failed: $finalizeError); uncommitted worker changes may still exist in the worktree and were not captured, so this command cannot proceed. Inspect the worktree manually.`n  worktree: $worktreePath`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message; JobDir = $jobDir; StatusObject = $statusObj; WorktreePath = $worktreePath; BaseCommit = $null; MainRepo = $null }
    }

    return [pscustomobject]@{
        WrapperExitCode = 0
        Stdout          = $null
        Message         = $null
        JobDir          = $jobDir
        StatusObject    = $statusObj
        WorktreePath    = $worktreePath
        BaseCommit      = [string]$statusObj.base_commit
        MainRepo        = [string]$statusObj.main_repo
    }
}

function Invoke-CcodexDiffCommand {
    # Read-only inspection of a worktree job's changes (design: "diff <job_id>", Phase 4
    # Task 4). Precondition chain (unknown/non-terminal/no-worktree/worktree-removed) lives
    # in Resolve-CcodexWorktreeJobContext, shared with `apply`. On success prints
    # `git diff --stat <base>..HEAD` followed by the full `git diff <base>..HEAD`; an empty
    # change set prints an informational line instead (still exit 0).
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    $context = Resolve-CcodexWorktreeJobContext -JobId $JobId -StateRoot $StateRoot
    if ($context.WrapperExitCode -ne 0) {
        return [pscustomobject]@{ WrapperExitCode = $context.WrapperExitCode; Stdout = $context.Stdout; Message = $context.Message }
    }

    $worktreePath = $context.WorktreePath
    $baseCommit = $context.BaseCommit
    $range = "$baseCommit..HEAD"

    $statOutput = (& git -C $worktreePath diff --stat $range 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        $message = "ccodex: internal error: git diff --stat failed in worktree '$worktreePath': $statOutput"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
    }
    $statOutput = $statOutput.TrimEnd("`r", "`n")

    if ([string]::IsNullOrWhiteSpace($statOutput)) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "ccodex: no changes to diff for job $JobId ($range is empty)."; Message = $null }
    }

    $diffOutput = (& git -C $worktreePath diff $range 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        $message = "ccodex: internal error: git diff failed in worktree '$worktreePath': $diffOutput"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
    }
    $diffOutput = $diffOutput.TrimEnd("`r", "`n")

    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "$statOutput`n`n$diffOutput"; Message = $null }
}

function Invoke-CcodexApplyCommand {
    # Applies a done worktree job's snapshot commit(s) onto the main repo (design: "apply
    # <job_id>", Phase 4 Task 5). Shares the unknown/non-terminal/no-worktree/worktree-removed
    # precondition chain (3/4/2/3) with `diff` via Resolve-CcodexWorktreeJobContext, then adds
    # apply-only preconditions: the job must be `done` (a failed/timed_out/cancelled job -> 2),
    # and the MAIN repo working tree must be clean (else -> 2). An empty change set is a no-op
    # (exit 0). Otherwise `git format-patch <base>..HEAD --stdout` from the worktree is piped to
    # `git am --3way` in the main repo. Success (a new commit landed) prints the applied range
    # and exits 0. ANY non-success outcome -- textual conflict, or an already-applied/empty patch
    # that git am accepts as a no-op without advancing HEAD -- is a failure: `git am --abort` is
    # attempted best-effort, the main repo is force-restored to its pre-apply HEAD (its tree was
    # verified clean beforehand, so this loses no user work), and the command exits 25 naming any
    # conflicting files parsed from the am output and pointing at `ccodex diff <job_id>`. The main
    # repo is NEVER left mutated except by a successful apply.
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA,
        # Wall-clock bound for acquiring the per-main-repo apply lock (see below). Overridable
        # for tests; production callers keep the default. A timeout yields exit 21, matching the
        # lock-timeout contract `cancel` already uses.
        [int]$LockTimeoutSec = 30
    )

    $context = Resolve-CcodexWorktreeJobContext -JobId $JobId -StateRoot $StateRoot
    if ($context.WrapperExitCode -ne 0) {
        return [pscustomobject]@{ WrapperExitCode = $context.WrapperExitCode; Stdout = $context.Stdout; Message = $context.Message }
    }

    $statusObj = $context.StatusObject
    $worktreePath = $context.WorktreePath
    $baseCommit = $context.BaseCommit
    $mainRepo = $context.MainRepo
    $jobDir = $context.JobDir

    # apply-only precondition: only `done` jobs may be applied. `diff` inspects any terminal
    # job, but applying the partial output of a failed/timed_out/cancelled run is unsafe.
    $statusText = if ($statusObj) { [string]$statusObj.status } else { 'unknown' }
    if ($statusText -ne 'done') {
        $message = "ccodex: only done jobs can be applied; job $JobId is '$statusText'.`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $message }
    }

    if ([string]::IsNullOrEmpty($mainRepo) -or -not (Test-Path -LiteralPath $mainRepo -PathType Container)) {
        $message = "ccodex: internal error: job $JobId has no recorded main_repo on disk (main_repo='$mainRepo').`n  job dir: $jobDir"
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
    }

    # Serialize the ENTIRE main-repo mutation section (clean check -> preHead capture -> git am
    # -> restore/verification) under a per-main-repo lock. Without it, two concurrent applies to
    # the same main repo can both capture the same preHead; if one succeeds and the other then
    # fails, the failing one's `reset --hard $preHead` erases the successful apply's commit. The
    # lock lives under the STATE ROOT (keyed by the main repo's repo key), never inside the target
    # repo, and reuses the same per-directory lock machinery as the per-job lock. A timeout yields
    # exit 21, mirroring `cancel`'s lock-timeout contract.
    $mainRepoKey = Get-CcodexRepoKey -RepoRoot $mainRepo
    $applyLockDir = Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $StateRoot) 'locks') "apply-$mainRepoKey"
    New-Item -ItemType Directory -Path $applyLockDir -Force | Out-Null
    try {
        Lock-CcodexJob -JobDir $applyLockDir -TimeoutSec $LockTimeoutSec -CommandName 'apply' | Out-Null
    } catch {
        $message = "ccodex: could not acquire the apply lock for main repo '$mainRepo' within ${LockTimeoutSec}s.`n  main repo: $mainRepo"
        return [pscustomobject]@{ WrapperExitCode = 21; Stdout = $null; Message = $message }
    }
    try {
        # Main repo working tree must be clean: `am` mutates the working tree, so any uncommitted
        # local change could be silently entangled with (or clobbered by) the applied patch.
        $porcelain = @(& git -C $mainRepo status --porcelain 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $message = "ccodex: internal error: git status --porcelain failed in main repo '$mainRepo': $($porcelain -join "`n")"
            return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
        }
        $dirtyLines = @($porcelain | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
        if ($dirtyLines.Count -gt 0) {
            $message = "ccodex: main repo working tree is not clean; commit or stash your changes before applying job $JobId.`n  main repo: $mainRepo`n  dirty:`n$([string]::Join("`n", ($dirtyLines | ForEach-Object { "    $_" })))"
            return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $message }
        }

        # Keep an explicit pre-apply inventory so recovery can remove only untracked files this
        # transaction introduced. (The clean-tree precondition normally makes this empty, but the
        # inventory preserves that safety if Git's ignore rules or status behavior change.)
        $preUntracked = @(& git -C $mainRepo ls-files --others --exclude-standard 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $message = "ccodex: internal error: could not inventory untracked files in main repo '$mainRepo': $($preUntracked -join "`n")"
            return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
        }
        $emptyHooksDir = Join-Path $applyLockDir 'empty-hooks'
        New-Item -ItemType Directory -Path $emptyHooksDir -Force | Out-Null

        $range = "$baseCommit..HEAD"

        # Empty change set (worker committed nothing) -> nothing to apply; exit 0 no-op.
        $revList = @(& git -C $worktreePath rev-list $range 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $message = "ccodex: internal error: git rev-list $range failed in worktree '$worktreePath': $($revList -join "`n")"
            return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
        }
        if (@($revList | Where-Object { $_ -and $_.ToString().Trim() -ne '' }).Count -eq 0) {
            return [pscustomobject]@{ WrapperExitCode = 0; Stdout = "ccodex: no changes to apply for job $JobId ($range is empty); main repo unchanged."; Message = $null }
        }

        $preHead = (& git -C $mainRepo rev-parse HEAD 2>&1 | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) {
            $message = "ccodex: internal error: git rev-parse HEAD failed in main repo '$mainRepo': $preHead"
            return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $message }
        }
        $preHead = ([string]$preHead).Trim()

        # format-patch --stdout emits the mbox patch stream on stdout (diagnostics go to its own
        # stderr, which must NOT be merged into the pipe or it would corrupt the patch). The 2>&1 on
        # `am` captures its progress/conflict lines for parsing. A native-to-native pipe in
        # PowerShell 7 is byte-preserving, so patch content survives intact.
        $amOutput = (& git -C $worktreePath format-patch $range --stdout | & git -c "core.hooksPath=$emptyHooksDir" -C $mainRepo am --3way 2>&1 | Out-String)
        $amExit = $LASTEXITCODE

        $postHead = (& git -C $mainRepo rev-parse HEAD 2>&1 | Select-Object -First 1)
        $postHead = ([string]$postHead).Trim()

        if ($amExit -eq 0 -and $postHead -ne $preHead) {
            # A new commit landed: the patch genuinely applied.
            $stdout = "ccodex: applied job $JobId to $mainRepo`n  range: $baseCommit..$postHead"
            return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $stdout; Message = $null }
        }

        # Failure (nonzero am) OR a no-op that advanced nothing (already-applied/empty patch that
        # `am --3way` accepts with exit 0 but no commit). Either way this is NOT a real application:
        # abort any in-progress am (best-effort), then force the main repo back to its pre-apply HEAD.
        & git -C $mainRepo am --abort 2>&1 | Out-Null
        & git -C $mainRepo reset --hard $preHead 2>&1 | Out-Null

        $postUntracked = @(& git -C $mainRepo ls-files --others --exclude-standard 2>&1)
        $newUntracked = @()
        if ($LASTEXITCODE -eq 0) {
            $newUntracked = @(
                Compare-Object -ReferenceObject $preUntracked -DifferenceObject $postUntracked |
                    Where-Object { $_.SideIndicator -eq '=>' } |
                    ForEach-Object { [string]$_.InputObject }
            )
            if ($newUntracked.Count -gt 0) {
                # Let Git remove only the paths it reports as untracked and newly created by this
                # apply. It will not follow this into tracked or pre-existing user files.
                & git -C $mainRepo clean -f -d -- $newUntracked 2>&1 | Out-Null
            }
        }

        $restoredHead = ([string](& git -C $mainRepo rev-parse HEAD 2>&1 | Select-Object -First 1)).Trim()
        $restorePorcelain = @(& git -C $mainRepo status --porcelain 2>&1 | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
        $restored = ($restoredHead -eq $preHead) -and ($restorePorcelain.Count -eq 0)

        # Parse conflicting file names out of the am output.
        $conflictFiles = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($amOutput -split "`r?`n")) {
            if ($line -match 'Merge conflict in (.+?)\s*$') { $conflictFiles.Add($Matches[1].Trim()) }
            elseif ($line -match 'error: patch failed: (.+?):\d+\s*$') { $conflictFiles.Add($Matches[1].Trim()) }
            elseif ($line -match 'error: (.+?): patch does not apply\s*$') { $conflictFiles.Add($Matches[1].Trim()) }
        }
        $uniqueConflicts = @($conflictFiles | Select-Object -Unique)
        $filesText = if ($uniqueConflicts.Count -gt 0) { $uniqueConflicts -join ', ' } else { '(none reported; the patch may already be applied or empty)' }

        $message = "ccodex: could not apply job $JobId to $mainRepo; git am failed and the main repo was restored to its previous state.`n  conflicting files: $filesText`n  run ``ccodex diff $JobId`` to inspect the changes."
        if (-not $restored) {
            $message += "`n  WARNING: the main repo could not be fully restored to its pre-apply state (HEAD='$restoredHead', expected '$preHead'); inspect it manually."
        }
        return [pscustomobject]@{ WrapperExitCode = 25; Stdout = $null; Message = $message }
    } finally {
        Unlock-CcodexJob -JobDir $applyLockDir
    }
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

function Invoke-CcodexDebugCommand {
    # Compact multi-line diagnosis of a single job (design: "debug <job_id>", Phase 2b
    # Task 7). Performs the same narrow orphan reconciliation `status` does (via
    # Update-CcodexOrphanStatus), then renders every diagnostic field the design calls
    # for. Read-only beyond that one reconciliation write; unknown job id -> exit 3,
    # otherwise always exit 0 (there is no "bad" debug output, only more/less detail).
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
    $stderrPath = Join-Path $jobDir 'stderr.log'

    Update-CcodexOrphanStatus -JobDir $jobDir | Out-Null
    $status = Read-CcodexStatusFile -JobDir $jobDir

    $statusText = if ($status) { $status.status } else { 'unknown' }
    if ([string]::IsNullOrEmpty($statusText)) { $statusText = 'unknown' }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("job: $JobId")

    $statusLine = "status: $statusText"
    if ($statusText -eq 'running') {
        $health = Get-CcodexJobHealth -Status $status
        if ($health) { $statusLine += " health=$health" }
    }
    $lines.Add($statusLine)

    $mode = if ($status) { $status.mode } else { 'unknown' }
    $access = if ($status) { $status.access } else { 'unknown' }
    $backend = if ($status) { $status.backend } else { 'unknown' }
    $lines.Add("mode: $mode  access: $access  backend: $backend")
    $lines.Add("repo: $(if ($status) { $status.repo } else { 'unknown' })")

    $parentJobId = if ($status) { $status.parent_job_id } else { $null }
    if (-not [string]::IsNullOrEmpty([string]$parentJobId)) {
        $lines.Add("parent: $parentJobId")
    }

    foreach ($field in @(
            @{ Key = 'created_at'; Label = 'created_at' },
            @{ Key = 'started_at'; Label = 'started_at' },
            @{ Key = 'finished_at'; Label = 'finished_at' },
            @{ Key = 'terminated_at'; Label = 'terminated_at' },
            @{ Key = 'cancelled_at'; Label = 'cancelled_at' }
        )) {
        $value = if ($status) { $status.($field.Key) } else { $null }
        if (-not [string]::IsNullOrEmpty([string]$value)) {
            $lines.Add("$($field.Label): $value")
        }
    }

    $backendId = if ($status) { $status.backend_id } else { $null }
    if ([string]::IsNullOrEmpty([string]$backendId)) {
        $lines.Add('backend_id: (absent)')
    } else {
        $alive = Test-CcodexWorkerAlive -BackendId $backendId
        $verdict = if ($alive) { 'alive' } else { 'dead' }
        $lines.Add("backend_id: $backendId ($verdict)")
    }

    $codexExitText = if ($status -and $null -ne $status.codex_exit_code) { $status.codex_exit_code } else { 'null' }
    $wrapperExitText = if ($status -and $null -ne $status.wrapper_exit_code) { $status.wrapper_exit_code } else { 'null' }
    $lines.Add("codex_exit_code: $codexExitText  wrapper_exit_code: $wrapperExitText")

    $failureReason = if ($status) { $status.failure_reason } else { $null }
    if (-not [string]::IsNullOrEmpty([string]$failureReason)) {
        $lines.Add("failure_reason: $failureReason")
        $hintLine = Get-CcodexFailureHintLine -FailureReason $failureReason
        if ($hintLine) { $lines.Add("  $hintLine") }
    }

    $codexThreadId = if ($status) { $status.codex_thread_id } else { $null }
    if ([string]::IsNullOrEmpty([string]$codexThreadId)) {
        $lines.Add('codex_thread_id: absent/scrubbed')
    } else {
        $lines.Add("codex_thread_id: $codexThreadId")
    }

    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $resultSize = (Get-Item -LiteralPath $resultPath).Length
        $lines.Add("result.md: present ($resultSize bytes)")
    } else {
        $lines.Add('result.md: absent')
    }

    $lines.Add('== stderr.log (last 5) ==')
    $stderrTail = Get-CcodexTailLines -Path $stderrPath -Lines 5
    if ($null -eq $stderrTail) { $lines.Add('(absent)') } else { $lines.AddRange([string[]]$stderrTail) }

    $lines.Add("job dir: $jobDir")

    # "next command" recommendation: only for the commands that exist today. A future
    # Phase 5 `resume` pointer belongs here once that command lands.
    $nextCommand = switch ($statusText) {
        'running' { "next: ccodex wait $JobId" }
        'done' { "next: ccodex read $JobId" }
        'failed' { "next: ccodex tail $JobId" }
        default { $null }
    }
    if ($nextCommand) { $lines.Add($nextCommand) }

    $output = [string]::Join("`n", $lines)
    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = $output; Message = $null }
}

function Invoke-CcodexListCommand {
    # Read-only listing of jobs (design: docs/2026-07-15-ccodex-list-command-design.md).
    # Human text by default; a stable JSON envelope (schema_version + count + jobs[]) under
    # -Json. Never writes, never reconciles — a running job's health is the heartbeat-derived
    # ok|stale from Get-CcodexJobList. For an authoritative reconciled verdict on one job, use
    # `ccodex status <id>`.
    param(
        [switch]$Json,
        [string]$RepoOverride = $null,
        [string[]]$State = @(),
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    $validStates = @('created', 'running', 'done', 'failed', 'timed_out', 'cancelled')
    foreach ($s in $State) {
        if ($s -cnotin $validStates) {
            return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = "ccodex: --state must be one of: $($validStates -join ', '); got '$s'." }
        }
    }

    $repoKey = $null
    if ($RepoOverride) {
        try {
            $repoRoot = Resolve-CcodexRepo -RepoOverride $RepoOverride
        } catch {
            return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $_.Exception.Message }
        }
        $repoKey = Get-CcodexRepoKey -RepoRoot $repoRoot
    }

    # Get-CcodexJobList returns via the `, @(...)` idiom, which keeps the result an array
    # across the pipeline boundary; plain assignment consumes it intact. Wrapping in a
    # further @() would nest it (the whole array as one element), so do NOT.
    $jobs = Get-CcodexJobList -Root $StateRoot -RepoKey $repoKey -State $State

    if ($Json) {
        $envelope = [ordered]@{
            schema_version = 1
            count          = $jobs.Count
            jobs           = $jobs
        }
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = ($envelope | ConvertTo-Json -Depth 10); Message = $null }
    }

    if ($jobs.Count -eq 0) {
        return [pscustomobject]@{ WrapperExitCode = 0; Stdout = 'ccodex: no jobs found.'; Message = $null }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($job in $jobs) {
        if ($job.status -eq 'unknown') {
            $lines.Add("$($job.job_id)  unknown  ($($job.error))")
            continue
        }
        # health= is appended only for a running job whose derived health is 'stale' (an
        # 'ok' running job and every non-running job append nothing — mirrors the status line).
        $healthText = if ($job.status -eq 'running' -and $job.health -eq 'stale') { ' health=stale' } else { '' }
        $lines.Add("$($job.job_id)  $($job.status)$healthText  $($job.mode)/$($job.access)  $($job.backend)  $($job.repo)")
    }
    return [pscustomobject]@{ WrapperExitCode = 0; Stdout = ([string]::Join("`n", $lines)); Message = $null }
}

function Invoke-CcodexDoctorProbe {
    # Minimal one-shot process runner used only by `doctor` to invoke plain `codex
    # --version` / `codex doctor` (no prompt on stdin, no job artifacts). Reuses the
    # same launch-plan machinery as Invoke-CcodexCodexProcess (Get-CcodexProcessLaunchPlan,
    # the cmd.exe /d /s /c wrapping for .cmd/.bat targets) so the .cmd-vs-.ps1 precedence
    # guard and cmd metacharacter quoting apply identically here, but skips the
    # timeout/heartbeat/log-file plumbing that command doesn't need. Stdin is closed
    # immediately (no prompt content) since neither probed subcommand reads it, though
    # the fake-codex fixture drains stdin unconditionally regardless.
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        # Per-probe wall-clock bound. A hung codex must not hang `doctor` forever. 0 or
        # negative means wait indefinitely (not used by the doctor callers).
        [int]$TimeoutSec = 30
    )
    $plan = Get-CcodexProcessLaunchPlan -CodexPath $CodexPath -Arguments $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $plan.FileName
    if ($plan.FileName -eq "$env:SystemRoot\System32\cmd.exe") {
        $psi.Arguments = $plan.ArgumentList -join ' '
    } else {
        foreach ($arg in $plan.ArgumentList) { [void]$psi.ArgumentList.Add($arg) }
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardInputEncoding = $utf8NoBom
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    $psi.UseShellExecute = $false
    # Same no-console-window rule as Invoke-CcodexCodexProcess: never flash a window.
    $psi.CreateNoWindow = $true

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Bounded wait: WaitForExit(ms) returns $false on timeout. On timeout, kill the whole
        # tree (Stop-CcodexProcessTree — the same kill-tree primitive Invoke-CcodexCodexProcess
        # uses on a hard timeout), then bound the reaping attempts as well.
        $timeoutMs = if ($TimeoutSec -gt 0) { $TimeoutSec * 1000 } else { [int]::MaxValue }
        if (-not $process.WaitForExit($timeoutMs)) {
            Stop-CcodexProcessTree -ProcessId $process.Id
            $secondWaitMs = 5000
            $exited = $false
            try { $exited = $process.WaitForExit($secondWaitMs) } catch { $exited = $false }
            if (-not $exited) {
                try { $process.Kill($true) } catch { }
                try { $exited = $process.WaitForExit($secondWaitMs) } catch { $exited = $false }
            }
            $partialStdout = ''
            $partialStderr = ''
            if ($exited) {
                try { $partialStdout = $stdoutTask.GetAwaiter().GetResult() } catch { $partialStdout = '' }
                try { $partialStderr = $stderrTask.GetAwaiter().GetResult() } catch { $partialStderr = '' }
            }
            # A process that survived both tree-kill attempts must be visible to doctor as a
            # distinct failure. The finally block still disposes our Process/stream handles.
            return [pscustomobject]@{ ExitCode = $null; Stdout = $partialStdout; Stderr = $partialStderr; TimedOut = $true; TerminationFailed = (-not $exited) }
        }

        # Parameterless WaitForExit after a bounded one that returned true guarantees the async
        # readers have fully flushed before we read.
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr; TimedOut = $false; TerminationFailed = $false }
    } finally {
        if ($process) {
            try { $process.StandardInput.Close() } catch { }
            try { $process.StandardOutput.Close() } catch { }
            try { $process.StandardError.Close() } catch { }
            try { $process.Dispose() } catch { }
        }
    }
}

function Invoke-CcodexDoctorCommand {
    # Environment diagnosis (design: "doctor", Phase 2b Task 8). Checks are printed in
    # order, one `ok|FAIL <name>: <detail>` line each; the index/jobs consistency check is
    # purely informational (its counts never fail the command). Exit-code precedence: an
    # environment check failure (codex unresolvable, `codex --version`/`codex doctor`
    # nonzero, state root unwritable, or the worker-prompt template missing) always yields
    # 12, even when the smoke test also ran and failed — an unhealthy environment is the
    # more fundamental problem and is reported as such regardless of the smoke outcome. A
    # bad --repo is a usage error (exit 2), matching `run`/`review`.
    param(
        [bool]$NoSmoke = $false,
        [string]$CodexPath,
        [string]$StateRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA,
        [string]$RepoOverride,
        # Per-probe wall-clock bound for the `codex --version` / `codex doctor` probes so a
        # hung codex cannot hang `doctor`. Overridable for tests (which drive the fixture's
        # probe-delay knobs against a short bound).
        [int]$ProbeTimeoutSec = 30
    )

    try {
        $repoRoot = Resolve-CcodexRepo -RepoOverride $RepoOverride
    } catch {
        return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $_.Exception.Message }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $extraBlocks = New-Object System.Collections.Generic.List[string]
    $envFailed = $false

    # --- Check 1: codex resolvable to a launchable .cmd/.exe + `codex --version` -----
    $resolvedCodexPath = $null
    try {
        $resolvedCodexPath = if ($CodexPath) { $CodexPath } else { Resolve-CcodexCodexPath }
    } catch {
        $envFailed = $true
        $lines.Add("FAIL codex resolvable: $($_.Exception.Message)")
    }

    if ($resolvedCodexPath) {
        try {
            $versionProbe = Invoke-CcodexDoctorProbe -CodexPath $resolvedCodexPath -Arguments @('--version') -TimeoutSec $ProbeTimeoutSec
            if ($versionProbe.TerminationFailed) {
                $envFailed = $true
                $lines.Add("FAIL codex resolvable: unable to terminate timed-out 'codex --version' probe after ${ProbeTimeoutSec}s")
            } elseif ($versionProbe.TimedOut) {
                $envFailed = $true
                $lines.Add("FAIL codex resolvable: 'codex --version' timed out after ${ProbeTimeoutSec}s")
            } elseif ($versionProbe.ExitCode -eq 0) {
                $versionLine = ($versionProbe.Stdout -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 1)
                $lines.Add("ok codex resolvable: $resolvedCodexPath (version: $versionLine)")
            } else {
                $envFailed = $true
                $lines.Add("FAIL codex resolvable: 'codex --version' exited $($versionProbe.ExitCode)")
            }
        } catch {
            $envFailed = $true
            $lines.Add("FAIL codex resolvable: could not run 'codex --version': $($_.Exception.Message)")
        }
    }

    # --- Check 2: built-in delegation to `codex doctor` -------------------------------
    if ($resolvedCodexPath) {
        try {
            $doctorProbe = Invoke-CcodexDoctorProbe -CodexPath $resolvedCodexPath -Arguments @('doctor') -TimeoutSec $ProbeTimeoutSec
            $doctorOutputLines = @($doctorProbe.Stdout -split "`r?`n" | Where-Object { $_ -ne '' })
            $doctorLastLine = if ($doctorOutputLines.Count -gt 0) { $doctorOutputLines[$doctorOutputLines.Count - 1] } else { '(no output)' }
            if ($doctorProbe.TerminationFailed) {
                $envFailed = $true
                $lines.Add("FAIL codex doctor: unable to terminate timed-out probe after ${ProbeTimeoutSec}s")
            } elseif ($doctorProbe.TimedOut) {
                $envFailed = $true
                $lines.Add("FAIL codex doctor: timed out after ${ProbeTimeoutSec}s")
            } elseif ($doctorProbe.ExitCode -eq 0) {
                $lines.Add("ok codex doctor: $doctorLastLine")
            } else {
                $envFailed = $true
                $lines.Add("FAIL codex doctor: exited $($doctorProbe.ExitCode) ($doctorLastLine); see 'codex doctor' output below")
                $extraBlocks.Add('== codex doctor output ==')
                if ($doctorProbe.Stdout) { $extraBlocks.Add($doctorProbe.Stdout.TrimEnd()) }
                if ($doctorProbe.Stderr) { $extraBlocks.Add($doctorProbe.Stderr.TrimEnd()) }
            }
        } catch {
            $envFailed = $true
            $lines.Add("FAIL codex doctor: could not run 'codex doctor': $($_.Exception.Message)")
        }
    } else {
        $envFailed = $true
        $lines.Add('FAIL codex doctor: skipped (codex not resolvable)')
    }

    # --- Check 3a: state root writable (create+delete a probe file under jobs\) -------
    $jobsDir = Join-Path (Get-CcodexLocalAppDataRoot -Root $StateRoot) 'jobs'
    $probeFile = Join-Path $jobsDir ".doctor-probe-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        New-Item -ItemType Directory -Path $jobsDir -Force -ErrorAction Stop | Out-Null
        Write-CcodexTextFile -Path $probeFile -Content 'doctor probe'
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction Stop
        $lines.Add("ok state root writable: $jobsDir")
    } catch {
        $envFailed = $true
        $lines.Add("FAIL state root writable: $jobsDir ($($_.Exception.Message))")
    }

    # --- Check 3b: worker-prompt template present -------------------------------------
    $templatePath = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $AppDataRoot
    if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        $lines.Add("ok worker prompt template: $templatePath")
    } else {
        $envFailed = $true
        $lines.Add("FAIL worker prompt template: not found at $templatePath")
    }

    # --- Check 3c: index/jobs consistency (informational; counts never fail this) ----
    $indexDir = Join-Path (Get-CcodexLocalAppDataRoot -Root $StateRoot) 'index'
    $indexedJobIds = New-Object System.Collections.Generic.HashSet[string]
    $danglingIndexCount = 0
    if (Test-Path -LiteralPath $indexDir -PathType Container) {
        foreach ($indexFile in Get-ChildItem -LiteralPath $indexDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $jobIdFromFile = [System.IO.Path]::GetFileNameWithoutExtension($indexFile.Name)
            [void]$indexedJobIds.Add($jobIdFromFile)
            $entry = $null
            try { $entry = Get-Content -LiteralPath $indexFile.FullName -Raw | ConvertFrom-Json } catch { $entry = $null }
            if (-not $entry -or -not $entry.job_dir -or -not (Test-Path -LiteralPath $entry.job_dir)) {
                $danglingIndexCount++
            }
        }
    }
    $unindexedJobDirCount = 0
    if (Test-Path -LiteralPath $jobsDir -PathType Container) {
        foreach ($repoKeyDir in Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue) {
            foreach ($jobDirEntry in Get-ChildItem -LiteralPath $repoKeyDir.FullName -Directory -ErrorAction SilentlyContinue) {
                if (-not $indexedJobIds.Contains($jobDirEntry.Name)) { $unindexedJobDirCount++ }
            }
        }
    }
    $lines.Add("ok index/jobs consistency: dangling_indexes=$danglingIndexCount unindexed_job_dirs=$unindexedJobDirCount")

    # --- Check 4: live smoke through the normal run pipeline (unless -NoSmoke) --------
    $smokeFailed = $false
    if ($NoSmoke) {
        $lines.Add('ok smoke test: skipped (--no-smoke)')
    } else {
        $smokeParams = @{
            Mode             = 'review'
            Access           = $null
            RepoOverride     = $repoRoot
            PromptFile       = $null
            PositionalTask   = 'Reply with exactly the word OK.'
            PipelineExpected = $false
            PipelineObjects  = $null
            LocalAppDataRoot = $StateRoot
            AppDataRoot      = $AppDataRoot
        }
        if ($CodexPath) { $smokeParams['CodexPath'] = $CodexPath }
        $smokeResult = Invoke-CcodexRun @smokeParams
        if ($smokeResult.WrapperExitCode -eq 2) {
            # A usage error from the shared init path (e.g. an invalid resolved repo)
            # is a doctor usage error too, not an environment or smoke failure.
            return [pscustomobject]@{ WrapperExitCode = 2; Stdout = $null; Message = $smokeResult.Message }
        }
        $smokeResultText = if ($smokeResult.Stdout) { $smokeResult.Stdout.Trim() } else { $null }
        if ($smokeResult.WrapperExitCode -eq 0 -and $smokeResultText -eq 'OK') {
            $lines.Add("ok smoke test: result '$smokeResultText'")
        } else {
            $smokeFailed = $true
            $reportedResult = if ($smokeResultText) { $smokeResultText } else { '(none)' }
            $lines.Add("FAIL smoke test: wrapper_exit_code=$($smokeResult.WrapperExitCode) result='$reportedResult'")
        }
    }

    $allLines = New-Object System.Collections.Generic.List[string]
    $allLines.AddRange([string[]]$lines.ToArray())
    if ($extraBlocks.Count -gt 0) { $allLines.AddRange([string[]]$extraBlocks.ToArray()) }
    $output = [string]::Join("`n", $allLines)

    if ($envFailed) {
        return [pscustomobject]@{ WrapperExitCode = 12; Stdout = $null; Message = $output }
    }
    if ($smokeFailed) {
        return [pscustomobject]@{ WrapperExitCode = 10; Stdout = $null; Message = $output }
    }
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

function Get-CcodexRequiredArgValue {
    # Get-CcodexArgValue variant for public flags whose silent misparse would be worse than a
    # usage error: with plain Get-CcodexArgValue a trailing `--model` is silently ignored (it
    # returns $null) and `--model --effort high` consumes `--effort` as the model, forwarding
    # `-m --effort` to Codex. Here a PRESENT flag must be followed by a real value — end of
    # line, or a next token that is itself a `--`-shaped flag, throws a usage error naming the
    # flag (callers map it to exit 2). An absent flag still returns $null, exactly like
    # Get-CcodexArgValue. Legitimate values never start with `--` for the flags routed here.
    param([object[]]$ArgumentList, [Parameter(Mandatory)][string]$FlagName)
    if (-not $ArgumentList) { return $null }
    $found = $null
    $seen = $false
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        if ($ArgumentList[$i] -eq $FlagName) {
            if (($i + 1) -ge $ArgumentList.Count -or ([string]$ArgumentList[$i + 1]).StartsWith('--')) {
                throw "ccodex: $FlagName requires a value."
            }
            # Validate EVERY occurrence: a valueless repeat like `--older-than 14d --older-than`
            # must still be rejected, not masked by the first occurrence's value. Return the first.
            if (-not $seen) { $found = $ArgumentList[$i + 1]; $seen = $true }
        }
    }
    if ($seen) { return $found }
    return $null
}

function ConvertTo-CcodexEffort {
    # --effort passes through to Codex as `-c model_reasoning_effort=<value>`, so only the
    # values Codex itself accepts are allowed, case-sensitively (Codex accepts arbitrary
    # strings as a Custom effort since 0.144.x, so a typo like 'High' would be forwarded and
    # silently degrade server-side instead of failing fast). An invalid value is a usage error
    # naming the flag (exit 2), same shape as ConvertTo-CcodexHardTimeoutSec. --model is
    # deliberately NOT validated: model names are an open set that changes with Codex releases,
    # so it is forwarded verbatim as `-m <model>`. This list mirrors Codex's ReasoningEffort
    # enum (verified against codex-cli 0.144.1); per-model support varies and is enforced by
    # Codex/the API, not here. On a Codex upgrade, re-derive the list per the
    # codex-upgrade-check skill (.claude/skills/codex-upgrade-check/SKILL.md).
    param([Parameter(Mandatory)][string]$FlagName, [Parameter(Mandatory)][string]$ValueText)
    $valid = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
    if ($ValueText -cnotin $valid) {
        throw "ccodex: $FlagName must be one of: $($valid -join ', ') (case-sensitive); got '$ValueText'."
    }
    return $ValueText
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
        if ($ArgumentList[$i] -eq $FlagName) {
            if (($i + 1) -ge $ArgumentList.Count -or ([string]$ArgumentList[$i + 1]).StartsWith('--')) {
                throw "ccodex: $FlagName requires a value."
            }
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
            # `--prompt-file` carries an internal hyphen, so PowerShell's -File binder cannot map
            # it onto the -PromptFile script parameter (it lands in $args instead, leaving
            # $PromptFile empty and silently falling through to the stdin reader — a 2s stall then
            # a confusing "redirected stdin produced no data" error). Parse it from $args here,
            # exactly like the other hyphenated flags; keep $PromptFile as the fallback so a direct
            # `-PromptFile` caller still works.
            $runPromptFile = Get-CcodexArgValue -ArgumentList $args -FlagName '--prompt-file'
            if (-not $runPromptFile) { $runPromptFile = $PromptFile }
            # Opt-in bypass of codex's trusted-directory check for a non-git (or untrusted) target.
            # Presence-only switch (no value), so a plain membership test in $args is enough.
            $runSkipGitRepoCheck = ($args -contains '--skip-git-repo-check')
            try {
                $runModel = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--model'
                $runEffortText = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--effort'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }
            $runParams = @{
                Mode             = $Mode
                Access           = $Access
                RepoOverride     = $Repo
                PromptFile       = $runPromptFile
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
            if ($runSkipGitRepoCheck) { $runParams['SkipGitRepoCheck'] = $true }
            if ($runModel) { $runParams['Model'] = $runModel }
            if ($runEffortText) {
                try {
                    $runParams['Effort'] = ConvertTo-CcodexEffort -FlagName '--effort' -ValueText $runEffortText
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
            # See the `run` branch: --prompt-file cannot bind to -PromptFile through the -File
            # binder (internal hyphen), so parse it from $args with $PromptFile as the fallback.
            $submitPromptFile = Get-CcodexArgValue -ArgumentList $args -FlagName '--prompt-file'
            if (-not $submitPromptFile) { $submitPromptFile = $PromptFile }
            $submitModel = $null
            $submitEffortText = $null
            try {
                $submitModel = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--model'
                $submitEffortText = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--effort'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }

            $submitParams = @{
                Mode             = $Mode
                Access           = $Access
                RepoOverride     = $Repo
                PromptFile       = $submitPromptFile
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
            if ($submitModel) { $submitParams['Model'] = $submitModel }
            if ($submitEffortText) {
                try {
                    $submitParams['Effort'] = ConvertTo-CcodexEffort -FlagName '--effort' -ValueText $submitEffortText
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
        'resume' {
            # Continue a finished job's Codex thread with a follow-up. The parent job id is the
            # positional arg (lands in $PositionalTask, same declaration-order binding the other
            # subcommands use); the follow-up itself comes from the standard prompt-source
            # machinery (piped stdin at the shell, since the positional slot is the parent id).
            # Pipeline/stdin capture mirrors run/submit exactly (PipelineExpected=$false; the OS
            # stdin stream is read directly by Get-CcodexPromptContent). --state-root/--codex-path
            # are hidden test-support flags; --hard-timeout-sec is a usage error on bad input (2).
            $resumeParentJobId = $PositionalTask
            $resumeStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $resumeCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'
            $resumeHardTimeoutSecText = Get-CcodexArgValue -ArgumentList $args -FlagName '--hard-timeout-sec'
            $resumeModel = $null
            $resumeEffortText = $null
            try {
                $resumeModel = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--model'
                $resumeEffortText = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--effort'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }
            if (-not $resumeParentJobId) {
                Write-Host "ccodex: resume requires a job id."
                $exitCode = 2
                break
            }
            # resume inherits mode/access/repo from the parent job verbatim, so it must not accept
            # --mode/--access/--repo (which bind to $Mode/$Access/$Repo). A second positional after
            # the job id ALSO binds to those params in declaration order, so the same guard rejects
            # `ccodex resume <job> <text>` instead of silently dropping the text (the follow-up must
            # come from stdin or --prompt-file). Reject before doing any work; --state-root/
            # --codex-path/--hard-timeout-sec (hidden/supported flags) land in $args and are unaffected.
            $resumeReject = $null
            if ($Repo)   { $resumeReject = '--repo' }
            elseif ($Mode)   { $resumeReject = '--mode' }
            elseif ($Access) { $resumeReject = '--access' }
            if ($resumeReject) {
                Write-Host "ccodex: resume does not accept $resumeReject or extra positional arguments; it inherits mode, access, and repo from the parent job. Pass only the job id (the follow-up text comes from stdin or --prompt-file)."
                $exitCode = 2
                break
            }
            # See the `run` branch: --prompt-file cannot bind to -PromptFile through the -File
            # binder (internal hyphen). Parse it from $args (with $PromptFile as fallback) so the
            # documented "follow-up from stdin or --prompt-file" actually works.
            $resumePromptFile = Get-CcodexArgValue -ArgumentList $args -FlagName '--prompt-file'
            if (-not $resumePromptFile) { $resumePromptFile = $PromptFile }
            $resumeParams = @{
                ParentJobId      = $resumeParentJobId
                PromptFile       = $resumePromptFile
                PositionalTask   = $null
                PipelineExpected = $false
                PipelineObjects  = $null
            }
            if ($resumeStateRoot) { $resumeParams['LocalAppDataRoot'] = $resumeStateRoot }
            if ($resumeCodexPath) { $resumeParams['CodexPath'] = $resumeCodexPath }
            if ($resumeHardTimeoutSecText) {
                try {
                    $resumeParams['HardTimeoutSec'] = ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText $resumeHardTimeoutSecText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }
            # Unlike --repo/--mode/--access above, --model/--effort are ACCEPTED on resume:
            # they are per-invocation knobs (this follow-up's model/effort), not inherited
            # parent context. They land in $args (hyphenated flags never bind to the script
            # params), so the rejection guard above never sees them.
            if ($resumeModel) { $resumeParams['Model'] = $resumeModel }
            if ($resumeEffortText) {
                try {
                    $resumeParams['Effort'] = ConvertTo-CcodexEffort -FlagName '--effort' -ValueText $resumeEffortText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }
            $resumeResult = Invoke-CcodexResume @resumeParams
            if ($resumeResult.WrapperExitCode -eq 0) {
                Write-Output $resumeResult.Stdout
            } else {
                Write-Host $resumeResult.Message
            }
            $exitCode = $resumeResult.WrapperExitCode
        }
        'worker' {
            # Internal entrypoint only: launched by the (future) `submit` detached
            # process, or directly in tests. Not documented/Claude-facing.
            $workerJobId = Get-CcodexArgValue -ArgumentList $args -FlagName '--job-id'
            $workerStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $workerCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'
            # --model/--effort arrive on the wrapper-authored launch line built by
            # Get-CcodexWorkerArgumentLine; effort was already validated by `submit`, so the
            # internal worker entrypoint forwards both verbatim.
            $workerModel = Get-CcodexArgValue -ArgumentList $args -FlagName '--model'
            $workerEffort = Get-CcodexArgValue -ArgumentList $args -FlagName '--effort'
            if (-not $workerJobId) {
                Write-Host "ccodex: worker requires --job-id <id>."
                $exitCode = 2
                break
            }
            $workerParams = @{ JobId = $workerJobId }
            if ($workerStateRoot) { $workerParams['StateRoot'] = $workerStateRoot }
            if ($workerCodexPath) { $workerParams['CodexPath'] = $workerCodexPath }
            if ($workerModel) { $workerParams['Model'] = $workerModel }
            if ($workerEffort) { $workerParams['Effort'] = $workerEffort }
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
            $statusJson = ($args -contains '--json')
            if (-not $statusJobId) {
                Write-Host "ccodex: status requires a job id."
                $exitCode = 2
                break
            }
            $statusParams = @{ JobId = $statusJobId }
            if ($statusStateRoot) { $statusParams['StateRoot'] = $statusStateRoot }
            if ($statusJson) { $statusParams['Json'] = $true }
            $statusResult = Invoke-CcodexStatusCommand @statusParams
            if ($statusJson) {
                Write-Output $statusResult.Stdout
            } elseif ($statusResult.WrapperExitCode -eq 0) {
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
            $waitJson = ($args -contains '--json')
            if (-not $waitJobId) {
                Write-Host "ccodex: wait requires a job id."
                $exitCode = 2
                break
            }
            $waitParams = @{ JobId = $waitJobId }
            if ($waitStateRoot) { $waitParams['StateRoot'] = $waitStateRoot }
            if ($waitTimeoutSecText) { $waitParams['WaitTimeoutSec'] = [int]$waitTimeoutSecText }
            if ($waitJson) { $waitParams['Json'] = $true }
            $waitResult = Invoke-CcodexWaitCommand @waitParams
            if ($waitJson) {
                Write-Output $waitResult.Stdout
            } elseif ($waitResult.WrapperExitCode -eq 0) {
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
            $readJson = ($args -contains '--json')
            if (-not $readJobId) {
                Write-Host "ccodex: read requires a job id."
                $exitCode = 2
                break
            }
            $readParams = @{ JobId = $readJobId }
            if ($readStateRoot) { $readParams['StateRoot'] = $readStateRoot }
            if ($readJson) { $readParams['Json'] = $true }
            $readResult = Invoke-CcodexReadCommand @readParams
            if ($readJson) {
                Write-Output $readResult.Stdout
            } elseif ($readResult.WrapperExitCode -eq 0) {
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
        'diff' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait`/`read`/`cancel` use). --state-root is a hidden
            # test-support flag.
            $diffJobId = $PositionalTask
            $diffStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $diffJobId) {
                Write-Host "ccodex: diff requires a job id."
                $exitCode = 2
                break
            }
            $diffParams = @{ JobId = $diffJobId }
            if ($diffStateRoot) { $diffParams['StateRoot'] = $diffStateRoot }
            $diffResult = Invoke-CcodexDiffCommand @diffParams
            if ($diffResult.WrapperExitCode -eq 0) {
                Write-Output $diffResult.Stdout
            } else {
                Write-Host $diffResult.Message
            }
            $exitCode = $diffResult.WrapperExitCode
        }
        'apply' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait`/`read`/`cancel`/`diff` use). --state-root is a
            # hidden test-support flag.
            $applyJobId = $PositionalTask
            $applyStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $applyJobId) {
                Write-Host "ccodex: apply requires a job id."
                $exitCode = 2
                break
            }
            $applyParams = @{ JobId = $applyJobId }
            if ($applyStateRoot) { $applyParams['StateRoot'] = $applyStateRoot }
            $applyResult = Invoke-CcodexApplyCommand @applyParams
            if ($applyResult.WrapperExitCode -eq 0) {
                Write-Output $applyResult.Stdout
            } else {
                Write-Host $applyResult.Message
            }
            $exitCode = $applyResult.WrapperExitCode
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
            $reviewStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $reviewCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'
            $reviewModel = $null
            $reviewEffortText = $null
            try {
                $reviewPaths = Get-CcodexArgValues -ArgumentList $args -FlagName '--path'
                $reviewModel = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--model'
                $reviewEffortText = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--effort'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }

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
            if ($reviewModel) { $reviewParams['Model'] = $reviewModel }
            if ($reviewEffortText) {
                try {
                    $reviewParams['Effort'] = ConvertTo-CcodexEffort -FlagName '--effort' -ValueText $reviewEffortText
                } catch {
                    Write-Host $_.Exception.Message
                    $exitCode = 2
                    break
                }
            }

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
        'debug' {
            # Positional job id lands in $PositionalTask (same declaration-order binding
            # `run`/`submit`/`status`/`wait`/`read`/`cancel`/`tail` use). --state-root is a
            # hidden test flag.
            $debugJobId = $PositionalTask
            $debugStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            if (-not $debugJobId) {
                Write-Host "ccodex: debug requires a job id."
                $exitCode = 2
                break
            }
            $debugParams = @{ JobId = $debugJobId }
            if ($debugStateRoot) { $debugParams['StateRoot'] = $debugStateRoot }
            $debugResult = Invoke-CcodexDebugCommand @debugParams
            if ($debugResult.WrapperExitCode -eq 0) {
                Write-Output $debugResult.Stdout
            } else {
                Write-Host $debugResult.Message
            }
            $exitCode = $debugResult.WrapperExitCode
        }
        'list' {
            # No positional job id. --json is a presence flag; --repo binds to $Repo (narrows
            # to that repo's key); --state is repeatable (Get-CcodexArgValues, so a bare
            # `--state` with no value is a usage error); --state-root is a hidden test flag.
            $listJson = ($args -contains '--json')
            $listStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            try {
                $listStates = Get-CcodexArgValues -ArgumentList $args -FlagName '--state'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }
            $listParams = @{}
            if ($listJson) { $listParams['Json'] = $true }
            if ($Repo) { $listParams['RepoOverride'] = $Repo }
            if ($listStates.Count -gt 0) { $listParams['State'] = $listStates }
            if ($listStateRoot) { $listParams['StateRoot'] = $listStateRoot }
            $listResult = Invoke-CcodexListCommand @listParams
            if ($listResult.WrapperExitCode -eq 0) {
                Write-Output $listResult.Stdout
            } else {
                Write-Host $listResult.Message
            }
            $exitCode = $listResult.WrapperExitCode
        }
        'cleanup' {
            # Retention sweep. --older-than <Nd|Nh> and --thread-ttl <Nd> override the
            # user-config thresholds; --repo binds to $Repo (narrows to that repo's key);
            # --dry-run/--include-stalled/--scrub-thread-ids are presence flags; --state-root
            # is a hidden test-support flag. Bad --older-than/--thread-ttl syntax is a usage
            # error (exit 2). Otherwise the engine is best-effort: exit 0, or 12 if any
            # individual delete/scrub failed.
            $cleanupStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            # Require a real value when the flag is present: a bare `--older-than` (or one followed
            # by another `--flag`) must be a usage error, NOT silently fall back to the configured
            # default retention and delete jobs the caller never asked to delete. Absent flag ->
            # $null (unchanged).
            try {
                $cleanupOlderThan = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--older-than'
                $cleanupThreadTtl = Get-CcodexRequiredArgValue -ArgumentList $args -FlagName '--thread-ttl'
            } catch {
                Write-Host $_.Exception.Message
                $exitCode = 2
                break
            }

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
                $olderNum = 0
                # TryParse (not a bare [int] cast): a regex-valid but oversized value like
                # 99999999999d must be a usage error (exit 2), not an [int] OverflowException that
                # surfaces as an internal error (exit 12).
                if (-not [int]::TryParse(($cleanupOlderThan -replace '(?i)[dh]$', ''), [ref]$olderNum)) {
                    Write-Host "ccodex: --older-than numeric value is out of range; got '$cleanupOlderThan'."
                    $exitCode = 2
                    break
                }
                # h -> fractional days; d -> whole days. Match the suffix case-INSENSITIVELY: the
                # validation regex above accepts `12H`, and String.EndsWith('h') is case-sensitive,
                # so `.EndsWith('h')` would misread `12H` as 12 DAYS instead of 12 hours.
                $cleanupParams['OlderThanDays'] = if ($cleanupOlderThan -match '(?i)h$') { $olderNum / 24.0 } else { $olderNum }
            }
            if ($cleanupThreadTtl) {
                if ($cleanupThreadTtl -notmatch '^\d+d?$') {
                    Write-Host "ccodex: --thread-ttl must be <Nd> (e.g. 30d); got '$cleanupThreadTtl'."
                    $exitCode = 2
                    break
                }
                $ttlNum = 0
                if (-not [int]::TryParse(($cleanupThreadTtl -replace 'd$', ''), [ref]$ttlNum)) {
                    Write-Host "ccodex: --thread-ttl numeric value is out of range; got '$cleanupThreadTtl'."
                    $exitCode = 2
                    break
                }
                $cleanupParams['ThreadTtlDays'] = $ttlNum
            }

            $cleanupResult = Invoke-CcodexCleanup @cleanupParams
            Write-Output $cleanupResult.Stdout
            $exitCode = $cleanupResult.WrapperExitCode
        }
        'doctor' {
            # No positional job id. --no-smoke is a presence flag; --repo binds to $Repo;
            # --codex-path/--state-root are hidden test-support flags mirroring the other
            # subcommands (there is no --app-data-root flag — tests override $env:APPDATA
            # directly, same as ReviewCommand/RealInvocation).
            $doctorNoSmoke = ($args -contains '--no-smoke')
            $doctorStateRoot = Get-CcodexArgValue -ArgumentList $args -FlagName '--state-root'
            $doctorCodexPath = Get-CcodexArgValue -ArgumentList $args -FlagName '--codex-path'

            $doctorParams = @{
                NoSmoke      = $doctorNoSmoke
                RepoOverride = $Repo
            }
            if ($doctorStateRoot) { $doctorParams['StateRoot'] = $doctorStateRoot }
            if ($doctorCodexPath) { $doctorParams['CodexPath'] = $doctorCodexPath }

            $doctorResult = Invoke-CcodexDoctorCommand @doctorParams
            if ($doctorResult.WrapperExitCode -eq 0) {
                Write-Output $doctorResult.Stdout
            } else {
                Write-Host $doctorResult.Message
            }
            $exitCode = $doctorResult.WrapperExitCode
        }
        default {
            Write-Host "ccodex: command '$Command' is not implemented. Supported commands: run, review, resume, submit, list, status, wait, read, cancel, diff, apply, tail, debug, cleanup, doctor, worker."
            $exitCode = 2
        }
    }
} catch {
    Write-Host "ccodex: internal error: $($_.Exception.Message)"
    $exitCode = 12
}
exit $exitCode
