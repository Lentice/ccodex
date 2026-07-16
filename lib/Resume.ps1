# lib/Resume.ps1
#
# Parent job resolution/preconditions for `ccodex resume`, plus the `codex exec resume`
# argument shape. Resume always creates a NEW job; this module never mutates the parent job's
# directory or status.json. Worktree parents expose their frozen snapshot context so the caller
# can validate and seed a distinct continuation worktree.

function Get-CcodexResumeContext {
    # Resolves a parent job id to the context a resume needs: its Codex thread id and its
    # inherited mode/access/repo. Worktree parents additionally carry the main repo, parent
    # worktree, own base, frozen snapshot, and inherited series base. Index lookup failure maps
    # to 3, a non-terminal parent to 4, and an absent/scrubbed thread id to 2 at the caller.
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

    $isWorktree = $status.access -eq 'worktree'
    $threadId = [string]$status.codex_thread_id
    # Worktree continuation has a stricter ordered precondition chain in the shared
    # initializer (worktree existence/finalization/snapshot before thread presence), so carry
    # an empty thread through for that branch. Non-worktree resume keeps the established check.
    if (-not $isWorktree -and [string]::IsNullOrEmpty($threadId)) {
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
        MainRepo                 = if ($isWorktree) { [string]$status.main_repo } else { $null }
        ParentWorktreeRepo       = if ($isWorktree) { [string]$status.worktree_repo } else { $null }
        ParentBaseCommit         = if ($isWorktree) { [string]$status.base_commit } else { $null }
        ParentSnapshotCommit     = if ($isWorktree) { [string]$status.snapshot_commit } else { $null }
        ParentSeriesBaseCommit   = if ($isWorktree) { [string]$status.series_base_commit } else { $null }
        ParentWorktreeFinalizeError = if ($isWorktree) { [string]$status.worktree_finalize_error } else { $null }
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
