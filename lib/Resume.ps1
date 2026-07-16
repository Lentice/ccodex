# lib/Resume.ps1
#
# Phase 5 (multi-turn advisor): parent job resolution/preconditions for `ccodex resume`,
# plus the `codex exec resume` argument shape. Resume always creates a NEW job; this module
# never mutates the parent job's directory or status.json — it only reads them.

function Get-CcodexResumeContext {
    # Resolves a parent job id to the context a resume needs: its Codex thread id and its
    # inherited mode/access/repo. Three distinct throw shapes map to the caller's usage-error
    # exit codes (documented in the Phase 5 plan): index lookup failure -> 3 (not found,
    # message owned by Get-CcodexJobRecord), non-terminal parent -> 4 (still running), and two
    # "resume not possible for this parent" cases -> 2 (worktree access, or a thread id that is
    # absent/scrubbed). Worktree access is checked BEFORE the thread-id check: a worktree
    # parent is categorically unresumable regardless of whether it happens to still carry a
    # thread id, so that message must win.
    param(
        [Parameter(Mandatory)][string]$ParentJobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    # Get-CcodexJobRecord throws the standard "not found (no index entry)" message when the
    # index entry or its job directory is missing; that message is reused verbatim (callers
    # map it to exit 3).
    $record = Get-CcodexJobRecord -JobId $ParentJobId -Root $StateRoot

    $status = Read-CcodexStatusFile -JobDir $record.JobDir
    if ($null -eq $status) {
        throw "ccodex: job '$ParentJobId' not found (no index entry)."
    }

    $terminalStatuses = @('done', 'failed', 'timed_out', 'cancelled')
    if ($status.status -notin $terminalStatuses) {
        throw "ccodex: job '$ParentJobId' is still $($status.status) - resume requires the parent job to be finished (done, failed, timed_out, or cancelled)."
    }

    if ($status.access -eq 'worktree') {
        throw "ccodex: job '$ParentJobId' ran in worktree access mode - resume is not supported for worktree jobs; start a fresh run."
    }

    $threadId = [string]$status.codex_thread_id
    if ([string]::IsNullOrEmpty($threadId)) {
        throw "ccodex: job '$ParentJobId' has no codex thread id (absent or scrubbed by cleanup) - start a fresh run."
    }

    return [pscustomobject]@{
        ParentJobId = $ParentJobId
        ThreadId    = $threadId
        Mode        = [string]$status.mode
        Access      = [string]$status.access
        Repo        = [string]$status.repo
        Group       = $status.group
        Label       = $status.label
    }
}

function Build-CcodexResumeArgs {
    # Exactly the Phase-1 `codex exec` argument shape (lib/ModeAccess.ps1's
    # Build-CcodexCodexArgs) with `resume <thread-id>` spliced in AFTER the exec-level options
    # and before the trailing `-` prompt positional. clap only resolves `--sandbox`/`-C`/
    # `--color` at the `exec` level, so they must precede the `resume` subcommand token —
    # placing them after it fails with "unexpected argument '--sandbox'" (live-verified
    # 2026-07-08). Reuses ConvertTo-CcodexSandboxFlag so the access->sandbox mapping never
    # forks.
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ResultPath,
        # Optional per-invocation knobs; like every other exec-level option they must precede
        # the `resume <thread-id>` token (same placement as Build-CcodexCodexArgs).
        [string]$Model = $null,
        [string]$Effort = $null
    )
    $sandbox = ConvertTo-CcodexSandboxFlag -Access $Access
    return @(
        '--ask-for-approval', 'never',
        'exec',
        '--sandbox', $sandbox,
        '--json',
        '--color', 'never',
        '-C', $RepoRoot,
        '--output-last-message', $ResultPath
    ) + (Get-CcodexModelEffortArgs -Model $Model -Effort $Effort) + @(
        'resume', $ThreadId,
        '-'
    )
}
