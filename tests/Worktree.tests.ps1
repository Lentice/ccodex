# tests/Worktree.tests.ps1
#
# Phase 4 Task 1: lib/Worktree.ps1 lifecycle — New-CcodexJobWorktree (create, detached at
# the main repo's HEAD), Complete-CcodexJobWorktree (snapshot finalization), and
# Remove-CcodexJobWorktree (best-effort teardown). All git operations run against real temp
# repos (never this repo, never the real LOCALAPPDATA state root).
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\Worktree.ps1')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function New-CcodexTestMainRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q 2>$null | Out-Null
    & git -C $Path config user.email 'test@example.com' | Out-Null
    & git -C $Path config user.name 'ccodex test' | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
    & git -C $Path add seed.txt | Out-Null
    & git -C $Path commit -q -m 'init' | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-worktree-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$stateRoot = Join-Path $tempRoot 'state'
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null

# --- New-CcodexJobWorktree: create -------------------------------------------

Write-Host "New-CcodexJobWorktree creates a detached worktree at the main repo's HEAD"
$mainRepo = Join-Path $tempRoot 'main1'
New-CcodexTestMainRepo -Path $mainRepo
$expectedHead = (& git -C $mainRepo rev-parse HEAD).Trim()

$created = New-CcodexJobWorktree -MainRepo $mainRepo -JobId 'job-create-1' -StateRoot $stateRoot
$expectedWtPath = Join-Path (Join-Path (Join-Path $stateRoot 'ccodex') 'worktrees') 'job-create-1'
Assert-Equal $created.WorktreePath $expectedWtPath 'returns the worktree path under <StateRoot>\ccodex\worktrees\<JobId>'
Assert-Equal $created.BaseCommit $expectedHead 'BaseCommit matches the main repo HEAD'
Assert-True (Test-Path -LiteralPath $created.WorktreePath -PathType Container) 'worktree directory exists on disk'

$wtHead = (& git -C $created.WorktreePath rev-parse HEAD).Trim()
Assert-Equal $wtHead $expectedHead 'worktree HEAD matches the recorded base commit'

$wtBranch = (& git -C $created.WorktreePath symbolic-ref -q HEAD 2>&1)
Assert-True ($LASTEXITCODE -ne 0) 'worktree is detached (symbolic-ref on HEAD fails)'

$mainHeadAfterCreate = (& git -C $mainRepo rev-parse HEAD).Trim()
Assert-Equal $mainHeadAfterCreate $expectedHead 'creating the worktree does not move the main repo HEAD'

# --- New-CcodexResumeWorktree: create at an explicit seed --------------------

Write-Host "New-CcodexResumeWorktree creates a detached child at the recorded parent snapshot"
[System.IO.File]::WriteAllText((Join-Path $created.WorktreePath 'parent-change.txt'), "parent`n", $utf8NoBom)
$parentSnapshot = Complete-CcodexJobWorktree -WorktreePath $created.WorktreePath -JobId 'job-create-1'
$resumeCreated = New-CcodexResumeWorktree -MainRepo $mainRepo -JobId 'job-resume-1' `
    -SeedCommit $parentSnapshot.HeadCommit -SeriesBaseCommit $expectedHead -StateRoot $stateRoot
Assert-Equal $resumeCreated.BaseCommit $parentSnapshot.HeadCommit 'resume BaseCommit echoes the explicit seed commit'
Assert-Equal $resumeCreated.SeriesBaseCommit $expectedHead 'resume SeriesBaseCommit echoes the cumulative series root'
Assert-True ($resumeCreated.WorktreePath -ne $created.WorktreePath) 'resume creates a distinct child worktree path'
Assert-Equal ((& git -C $resumeCreated.WorktreePath rev-parse HEAD).Trim()) $parentSnapshot.HeadCommit 'resume worktree HEAD equals the recorded parent snapshot'
$resumeBranch = (& git -C $resumeCreated.WorktreePath symbolic-ref -q HEAD 2>&1)
Assert-True ($LASTEXITCODE -ne 0) 'resume worktree is detached'
Assert-True (Test-Path -LiteralPath (Join-Path $resumeCreated.WorktreePath 'parent-change.txt')) 'resume worktree contains the parent snapshot content'

# --- Complete-CcodexJobWorktree: with changes --------------------------------

Write-Host "Complete-CcodexJobWorktree commits staged changes and reports Committed=true"
[System.IO.File]::WriteAllText((Join-Path $created.WorktreePath 'new-file.txt'), "hello`n", $utf8NoBom)
$finalized = Complete-CcodexJobWorktree -WorktreePath $created.WorktreePath -JobId 'job-create-1'
Assert-True $finalized.Committed 'Committed is true when the worktree has changes'
Assert-True ($finalized.HeadCommit -ne $expectedHead) 'worktree HEAD advanced past the base commit'

$mainHeadAfterFinalize = (& git -C $mainRepo rev-parse HEAD).Trim()
Assert-Equal $mainHeadAfterFinalize $expectedHead 'finalizing the worktree does not touch the main repo HEAD'

$wtHeadAfterFinalize = (& git -C $created.WorktreePath rev-parse HEAD).Trim()
Assert-Equal $wtHeadAfterFinalize $finalized.HeadCommit 'worktree HEAD matches the returned HeadCommit'

$commitAuthor = (& git -C $created.WorktreePath log -1 '--format=%an <%ae>').Trim()
Assert-Equal $commitAuthor 'ccodex-worker <ccodex@local>' 'snapshot commit uses the fixed ccodex-worker identity'

$commitMessage = (& git -C $created.WorktreePath log -1 '--format=%s').Trim()
Assert-Equal $commitMessage 'ccodex: worker output job-create-1' 'snapshot commit message follows the fixed template'

# --- Complete-CcodexJobWorktree: without changes -----------------------------

Write-Host "Complete-CcodexJobWorktree reports Committed=false when nothing changed"
$mainRepo2 = Join-Path $tempRoot 'main2'
New-CcodexTestMainRepo -Path $mainRepo2
$created2 = New-CcodexJobWorktree -MainRepo $mainRepo2 -JobId 'job-nochange' -StateRoot $stateRoot
$finalizedNoChange = Complete-CcodexJobWorktree -WorktreePath $created2.WorktreePath -JobId 'job-nochange'
Assert-True (-not $finalizedNoChange.Committed) 'Committed is false when the worktree has no changes'
Assert-Equal $finalizedNoChange.HeadCommit $created2.BaseCommit 'HeadCommit stays at the base commit when nothing was committed'

# --- Remove-CcodexJobWorktree: normal removal --------------------------------

Write-Host "Remove-CcodexJobWorktree removes the worktree and prunes the main repo's list"
$removed = Remove-CcodexJobWorktree -MainRepo $mainRepo2 -WorktreePath $created2.WorktreePath
Assert-True $removed 'Remove-CcodexJobWorktree returns true on success'
Assert-True (-not (Test-Path -LiteralPath $created2.WorktreePath)) 'worktree directory is gone from disk'
$listAfter = & git -C $mainRepo2 worktree list
$stillListed = @($listAfter | Where-Object { $_ -like "*$($created2.WorktreePath)*" })
Assert-Equal $stillListed.Count 0 'git worktree list no longer references the removed worktree'

# --- Remove-CcodexJobWorktree: main repo gone (best-effort) ------------------

Write-Host "Remove-CcodexJobWorktree is best-effort when the main repo itself no longer exists"
$mainRepo3 = Join-Path $tempRoot 'main3'
New-CcodexTestMainRepo -Path $mainRepo3
$created3 = New-CcodexJobWorktree -MainRepo $mainRepo3 -JobId 'job-gone' -StateRoot $stateRoot
Remove-Item -LiteralPath $mainRepo3 -Recurse -Force
$removedGone = Remove-CcodexJobWorktree -MainRepo $mainRepo3 -WorktreePath $created3.WorktreePath
Assert-True (-not $removedGone) 'returns false (no throw) when the main repo no longer exists'
Assert-True (-not (Test-Path -LiteralPath $created3.WorktreePath)) 'worktree directory is still deleted via the fallback path'

# --- New-CcodexJobWorktree: unborn HEAD ---------------------------------------

Write-Host "New-CcodexJobWorktree throws a usage error on an unborn-HEAD (commit-less) repo"
$emptyRepo = Join-Path $tempRoot 'empty-repo'
New-Item -ItemType Directory -Path $emptyRepo -Force | Out-Null
& git -C $emptyRepo init -q 2>$null | Out-Null
Assert-Throws { New-CcodexJobWorktree -MainRepo $emptyRepo -JobId 'job-unborn' -StateRoot $stateRoot } 'throws when the main repo has no commits'
Assert-True ($script:CcodexLastError -like '*no commits*') 'error message names the no-commits condition'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Complete-CcodexTests
