# lib/Worktree.ps1
#
# Lifecycle for the detached git worktrees that back `--access worktree` jobs (Phase 4).
# Worktrees live ONLY under the global state root (<StateRoot>\ccodex\worktrees\<JobId>) —
# never inside the target repo — so the caller's working tree is never mutated by job
# execution. The three stages are: create (detached at the repo's current HEAD),
# finalize (snapshot whatever the worker changed into one deterministic commit so `diff`/
# `apply` have a stable basis), and remove (best-effort teardown during cleanup). Depends
# on Get-CcodexLocalAppDataRoot from lib/Paths.ps1 — dot-source that first.

function New-CcodexJobWorktree {
    # Creates a detached worktree at the main repo's current HEAD. Throws a usage error if
    # the main repo has no commits yet (an unborn HEAD can't be the detach point for a
    # worktree), and rethrows any other git failure with git's own stderr attached.
    param(
        [Parameter(Mandatory)][string]$MainRepo,
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot = $env:LOCALAPPDATA
    )

    $headOutput = & git -C $MainRepo rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: repository has no commits; worktree access needs at least one commit."
    }
    $baseCommit = ($headOutput | Select-Object -First 1).ToString().Trim()

    $worktreesRoot = Join-Path (Get-CcodexLocalAppDataRoot -Root $StateRoot) 'worktrees'
    $worktreePath = Join-Path $worktreesRoot $JobId

    # git worktree add will create any missing intermediate directories itself, but make
    # sure the parent exists so a failure here is unambiguously git's, not ours.
    $parentDir = Split-Path -Parent $worktreePath
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $addOutput = & git -C $MainRepo worktree add --detach $worktreePath $baseCommit 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git worktree add failed: $($addOutput -join "`n")"
    }

    return [pscustomobject]@{
        WorktreePath = $worktreePath
        BaseCommit   = $baseCommit
    }
}

function Complete-CcodexJobWorktree {
    # Snapshot finalization: stage everything the worker left behind and, if there is
    # anything to stage, commit it under a fixed synthetic identity so this works even on
    # machines with no git identity configured. This is what gives `diff`/`apply` a
    # deterministic <base>..HEAD range to operate on.
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$JobId
    )

    $addOutput = & git -C $WorktreePath add -A 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git add -A failed in worktree '$WorktreePath': $($addOutput -join "`n")"
    }

    $statusOutput = @(& git -C $WorktreePath status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git status --porcelain failed in worktree '$WorktreePath': $($statusOutput -join "`n")"
    }
    $hasChanges = @($statusOutput | Where-Object { $_ -and $_.ToString().Trim() -ne '' }).Count -gt 0

    if ($hasChanges) {
        $commitOutput = & git -C $WorktreePath -c user.name=ccodex-worker -c user.email=ccodex@local commit -m "ccodex: worker output $JobId" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ccodex: git commit failed in worktree '$WorktreePath': $($commitOutput -join "`n")"
        }
    }

    $headOutput = & git -C $WorktreePath rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git rev-parse HEAD failed in worktree '$WorktreePath': $($headOutput -join "`n")"
    }
    $headCommit = ($headOutput | Select-Object -First 1).ToString().Trim()

    return [pscustomobject]@{
        Committed  = $hasChanges
        HeadCommit = $headCommit
    }
}

function Remove-CcodexJobWorktree {
    # Best-effort teardown, used by cleanup sweeps: a failure here must never throw and
    # must never block the rest of a sweep. When the main repo itself no longer exists,
    # git can't run `worktree remove` against it at all — fall straight to deleting the
    # worktree directory. Otherwise ask git to remove and prune it properly; if that git
    # call itself fails for some other reason, fall back to a manual directory delete too.
    param(
        [Parameter(Mandatory)][string]$MainRepo,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    if (-not (Test-Path -LiteralPath $MainRepo -PathType Container)) {
        if (Test-Path -LiteralPath $WorktreePath) {
            try { Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction Stop } catch { }
        }
        return $false
    }

    & git -C $MainRepo worktree remove --force $WorktreePath 2>&1 | Out-Null
    $removeExit = $LASTEXITCODE
    & git -C $MainRepo worktree prune 2>&1 | Out-Null

    if ($removeExit -ne 0) {
        if (Test-Path -LiteralPath $WorktreePath) {
            try { Remove-Item -LiteralPath $WorktreePath -Recurse -Force -ErrorAction Stop } catch { }
        }
        return $false
    }

    return $true
}
