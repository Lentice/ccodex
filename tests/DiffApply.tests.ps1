# tests/DiffApply.tests.ps1
#
# Phase 4 Task 4: `ccodex diff` (Invoke-CcodexDiffCommand) over real worktree jobs built
# through the actual `run` pipeline (fake-codex fixture) and via a status.json fixture for
# the branches that don't need a real job run (unknown id / non-terminal / read-only /
# removed-worktree). The `apply` section (Task 5) extends this same file.
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobId.ps1')
. (Join-Path $PSScriptRoot '..\lib\StdinTimeout.ps1')
. (Join-Path $PSScriptRoot '..\lib\PromptSource.ps1')
. (Join-Path $PSScriptRoot '..\lib\WorkerPrompt.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')
. (Join-Path $PSScriptRoot '..\lib\Detach.ps1')

$utf8NoBomTest = New-Object System.Text.UTF8Encoding($false)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-diffapply-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
New-Item -ItemType Directory -Path $localAppData, $appData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '..\templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

function New-CcodexTestGitRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q 2>$null | Out-Null
    & git -C $Path config user.email 'test@example.com' | Out-Null
    & git -C $Path config user.name 'ccodex test' | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBomTest)
    & git -C $Path add seed.txt | Out-Null
    & git -C $Path commit -q -m 'init' | Out-Null
}

function Invoke-CcodexRunForTest {
    param([hashtable]$Overrides = @{})
    $base = @{
        Mode                   = 'implement'
        Access                 = $null
        RepoOverride           = $null
        PromptFile             = $null
        PositionalTask         = 'do the implement task'
        PipelineExpected       = $false
        PipelineObjects        = $null
        CodexPath              = $fixtureCmd
        LocalAppDataRoot       = $localAppData
        AppDataRoot            = $appData
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return Invoke-CcodexRun @base
}

function New-CcodexTestJobWithStatus {
    # Minimal status.json-only fixture (no real codex run) for branches that only care
    # about the recorded status/access shape, mirroring StatusWaitRead.tests.ps1's helper
    # of the same name.
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$Status = 'created',
        [string]$BackendId = $null,
        [string]$WorktreeRepo = $null,
        [string]$MainRepo = $null,
        [string]$BaseCommit = $null
    )
    $repoKeyRepo = if ($MainRepo) { $MainRepo } else { $tempRoot }
    $repoKey = Get-CcodexRepoKey -RepoRoot $repoKeyRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content 'test worker prompt body'
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status $Status -Mode $Mode -Access $Access -Repo $repoKeyRepo -CreatedAt $createdAt -BackendId $BackendId -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

# ============================================================================
# diff
# ============================================================================

Write-Host "diff: done implement job -> stat + full patch, scoped to the written file"
$gitRepo1 = Join-Path $tempRoot 'gitrepo-diff-done'
New-CcodexTestGitRepo -Path $gitRepo1
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'worker-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker wrote this'
$runDone = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepo1 }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runDone.WrapperExitCode 0 'setup: implement run succeeds'
$statusDone = Get-Content -LiteralPath (Join-Path $runDone.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDone.status 'done' 'setup: job is terminal done'

$diffDone = Invoke-CcodexDiffCommand -JobId $statusDone.job_id -StateRoot $localAppData
Assert-Equal $diffDone.WrapperExitCode 0 'diff on a done worktree job -> exit 0'
Assert-True ($diffDone.Stdout -like '*worker-change.txt*') 'diff stdout mentions the changed file (stat line)'
Assert-True ($diffDone.Stdout -like '*+worker wrote this*') 'diff stdout includes the full patch content'
Assert-True ($diffDone.Stdout -notlike '*seed.txt*') 'diff is scoped to the base..HEAD range, not the whole repo history'

Write-Host "diff: empty-change job -> exit 0 with an informational message, no patch"
$gitRepo2 = Join-Path $tempRoot 'gitrepo-diff-empty'
New-CcodexTestGitRepo -Path $gitRepo2
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'nothing to change'
$runEmpty = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepo2; PositionalTask = 'inspect only' }
Assert-Equal $runEmpty.WrapperExitCode 0 'setup: no-write implement run still succeeds'
$statusEmpty = Get-Content -LiteralPath (Join-Path $runEmpty.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusEmpty.worktree_committed $false 'setup: nothing was committed in the worktree'

$diffEmpty = Invoke-CcodexDiffCommand -JobId $statusEmpty.job_id -StateRoot $localAppData
Assert-Equal $diffEmpty.WrapperExitCode 0 'diff on an empty-change job -> exit 0'
Assert-True ($diffEmpty.Stdout -like '*no changes*') 'diff stdout is an informational no-changes message'

Write-Host "diff: running job -> exit 4 with a wait hint"
$jobRunning = New-CcodexTestJobWithStatus -Mode 'implement' -Access 'worktree' -Status 'running' -MainRepo $gitRepo1 -WorktreeRepo (Join-Path $tempRoot 'nonexistent-wt') -BaseCommit 'deadbeef'
$diffRunning = Invoke-CcodexDiffCommand -JobId $jobRunning.JobId -StateRoot $localAppData
Assert-Equal $diffRunning.WrapperExitCode 4 'diff on a running job -> exit 4'
Assert-True ($diffRunning.Message -like '*ccodex wait*') 'exit-4 message includes the standard wait hint'

Write-Host "diff: unknown job id -> exit 3"
$diffUnknown = Invoke-CcodexDiffCommand -JobId 'no-such-job' -StateRoot $localAppData
Assert-Equal $diffUnknown.WrapperExitCode 3 'diff on an unknown job id -> exit 3'

Write-Host "diff: read-only job (no worktree) -> exit 2"
$jobReadOnly = New-CcodexTestJobWithStatus -Mode 'review' -Access 'read-only' -Status 'done'
$diffReadOnly = Invoke-CcodexDiffCommand -JobId $jobReadOnly.JobId -StateRoot $localAppData
Assert-Equal $diffReadOnly.WrapperExitCode 2 'diff on a read-only job -> exit 2'
Assert-True ($diffReadOnly.Message -like '*has no worktree*') 'exit-2 message names the missing worktree'

Write-Host "diff: workspace job (no worktree) -> exit 2"
$jobWorkspace = New-CcodexTestJobWithStatus -Mode 'test' -Access 'workspace' -Status 'done'
$diffWorkspace = Invoke-CcodexDiffCommand -JobId $jobWorkspace.JobId -StateRoot $localAppData
Assert-Equal $diffWorkspace.WrapperExitCode 2 'diff on a workspace-access job -> exit 2'
Assert-True ($diffWorkspace.Message -like '*has no worktree*') 'exit-2 message names the missing worktree'

Write-Host "diff: worktree removed from disk (cleaned) -> exit 3, evidence points at the job dir"
$gitRepo3 = Join-Path $tempRoot 'gitrepo-diff-removed'
New-CcodexTestGitRepo -Path $gitRepo3
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'worker-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker wrote this'
$runRemoved = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepo3 }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runRemoved.WrapperExitCode 0 'setup: implement run succeeds'
$statusRemoved = Get-Content -LiteralPath (Join-Path $runRemoved.JobDir 'status.json') -Raw | ConvertFrom-Json
Remove-Item -LiteralPath $statusRemoved.worktree_repo -Recurse -Force

$diffRemoved = Invoke-CcodexDiffCommand -JobId $statusRemoved.job_id -StateRoot $localAppData
Assert-Equal $diffRemoved.WrapperExitCode 3 'diff on a job whose worktree was removed from disk -> exit 3'
Assert-True ($diffRemoved.Message -like '*worktree removed*') 'exit-3 message says the worktree was removed'
Assert-True ($diffRemoved.Message -like "*$($runRemoved.JobDir)*") 'exit-3 message points at the surviving job dir'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# ============================================================================
# apply
# ============================================================================

Write-Host "apply: clean apply -> main repo gains the snapshot commit content, author preserved, exit 0"
$gitRepoApplyClean = Join-Path $tempRoot 'gitrepo-apply-clean'
New-CcodexTestGitRepo -Path $gitRepoApplyClean
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'applied-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'applied content'
$runApplyClean = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyClean }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyClean.WrapperExitCode 0 'setup: clean implement run succeeds'
$statusApplyClean = Get-Content -LiteralPath (Join-Path $runApplyClean.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusApplyClean.status 'done' 'setup: apply-clean job is terminal done'
$preHeadClean = (& git -C $gitRepoApplyClean rev-parse HEAD).Trim()

$applyClean = Invoke-CcodexApplyCommand -JobId $statusApplyClean.job_id -StateRoot $localAppData
Assert-Equal $applyClean.WrapperExitCode 0 'clean apply -> exit 0'
Assert-True (Test-Path -LiteralPath (Join-Path $gitRepoApplyClean 'applied-file.txt')) 'main repo gained the worker-authored file'
$appliedContent = Get-Content -LiteralPath (Join-Path $gitRepoApplyClean 'applied-file.txt') -Raw
Assert-True ($appliedContent -like '*applied content*') 'applied file has the worker-authored content'
$appliedAuthor = (& git -C $gitRepoApplyClean log -1 --format='%an <%ae>').Trim()
Assert-Equal $appliedAuthor 'ccodex-worker <ccodex@local>' 'author identity preserved from the snapshot commit'
$newHeadClean = (& git -C $gitRepoApplyClean rev-parse HEAD).Trim()
Assert-True ($newHeadClean -ne $preHeadClean) 'main repo HEAD advanced by the applied commit'
Assert-True ($applyClean.Stdout -like "*$newHeadClean*") 'stdout names the applied range new HEAD'

Write-Host "apply: dirty main repo -> exit 2, repo untouched"
$gitRepoApplyDirty = Join-Path $tempRoot 'gitrepo-apply-dirty'
New-CcodexTestGitRepo -Path $gitRepoApplyDirty
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'applied-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'applied content'
$runApplyDirty = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyDirty }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyDirty.WrapperExitCode 0 'setup: dirty-case implement run succeeds'
$statusApplyDirty = Get-Content -LiteralPath (Join-Path $runApplyDirty.JobDir 'status.json') -Raw | ConvertFrom-Json
# Dirty the MAIN repo working tree (uncommitted change) after the run.
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyDirty 'seed.txt'), "dirtied`n", $utf8NoBomTest)
$preHeadDirty = (& git -C $gitRepoApplyDirty rev-parse HEAD).Trim()

$applyDirty = Invoke-CcodexApplyCommand -JobId $statusApplyDirty.job_id -StateRoot $localAppData
Assert-Equal $applyDirty.WrapperExitCode 2 'apply onto a dirty main repo -> exit 2'
Assert-True ($applyDirty.Message -like '*clean*') 'exit-2 message names the not-clean working tree'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyDirty 'applied-file.txt'))) 'dirty main repo was not mutated (no applied file)'
$postHeadDirty = (& git -C $gitRepoApplyDirty rev-parse HEAD).Trim()
Assert-Equal $postHeadDirty $preHeadDirty 'dirty main repo HEAD unchanged'

Write-Host "apply: textual conflict -> exit 25, main repo restored (clean + HEAD unchanged), diff hint"
$gitRepoApplyConflict = Join-Path $tempRoot 'gitrepo-apply-conflict'
New-CcodexTestGitRepo -Path $gitRepoApplyConflict
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'seed.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker version'
$runApplyConflict = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyConflict }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyConflict.WrapperExitCode 0 'setup: conflict-case implement run succeeds'
$statusApplyConflict = Get-Content -LiteralPath (Join-Path $runApplyConflict.JobDir 'status.json') -Raw | ConvertFrom-Json
# Diverge the SAME file on the main repo, on top of the base, and commit it.
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyConflict 'seed.txt'), "main version`n", $utf8NoBomTest)
& git -C $gitRepoApplyConflict add seed.txt | Out-Null
& git -C $gitRepoApplyConflict commit -q -m 'main diverges seed.txt' | Out-Null
$preHeadConflict = (& git -C $gitRepoApplyConflict rev-parse HEAD).Trim()

$applyConflict = Invoke-CcodexApplyCommand -JobId $statusApplyConflict.job_id -StateRoot $localAppData
Assert-Equal $applyConflict.WrapperExitCode 25 'apply with a textual conflict -> exit 25'
$conflictPorcelain = @(& git -C $gitRepoApplyConflict status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
Assert-Equal $conflictPorcelain.Count 0 'main repo working tree is clean after the failed apply'
$postHeadConflict = (& git -C $gitRepoApplyConflict rev-parse HEAD).Trim()
Assert-Equal $postHeadConflict $preHeadConflict 'main repo HEAD unchanged after the failed apply'
Assert-True ($applyConflict.Message -like '*seed.txt*') 'exit-25 message names the conflicting file'
Assert-True ($applyConflict.Message -like "*ccodex diff $($statusApplyConflict.job_id)*") 'exit-25 message points at ccodex diff'

Write-Host "apply: failed-status job -> exit 2 (only done jobs can be applied)"
$gitRepoApplyFailed = Join-Path $tempRoot 'gitrepo-apply-failed'
New-CcodexTestGitRepo -Path $gitRepoApplyFailed
$env:CCODEX_FAKE_EXIT_CODE = '1'
$env:CCODEX_FAKE_RESULT = 'boom'
$env:CCODEX_FAKE_WRITE_FILE = 'applied-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'applied content'
$runApplyFailed = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyFailed }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$statusApplyFailed = Get-Content -LiteralPath (Join-Path $runApplyFailed.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusApplyFailed.status 'failed' 'setup: apply-failed job is terminal failed'

$applyFailed = Invoke-CcodexApplyCommand -JobId $statusApplyFailed.job_id -StateRoot $localAppData
Assert-Equal $applyFailed.WrapperExitCode 2 'apply on a failed-status job -> exit 2'
Assert-True ($applyFailed.Message -like '*only done jobs can be applied*') 'exit-2 message says only done jobs can be applied'

Write-Host "apply: empty change set -> exit 0 no-op, main repo unchanged"
$gitRepoApplyEmpty = Join-Path $tempRoot 'gitrepo-apply-empty'
New-CcodexTestGitRepo -Path $gitRepoApplyEmpty
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'nothing to change'
$runApplyEmpty = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyEmpty; PositionalTask = 'inspect only' }
Assert-Equal $runApplyEmpty.WrapperExitCode 0 'setup: no-write implement run succeeds'
$statusApplyEmpty = Get-Content -LiteralPath (Join-Path $runApplyEmpty.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusApplyEmpty.worktree_committed $false 'setup: nothing was committed in the worktree'
$preHeadEmpty = (& git -C $gitRepoApplyEmpty rev-parse HEAD).Trim()

$applyEmpty = Invoke-CcodexApplyCommand -JobId $statusApplyEmpty.job_id -StateRoot $localAppData
Assert-Equal $applyEmpty.WrapperExitCode 0 'apply on an empty-change job -> exit 0'
Assert-True ($applyEmpty.Stdout -like '*no changes*') 'stdout is an informational no-changes message'
$postHeadEmpty = (& git -C $gitRepoApplyEmpty rev-parse HEAD).Trim()
Assert-Equal $postHeadEmpty $preHeadEmpty 'empty-change apply leaves main repo HEAD unchanged'

Write-Host "apply: applying the same job twice -> second apply exit 25, main restored"
$gitRepoApplyTwice = Join-Path $tempRoot 'gitrepo-apply-twice'
New-CcodexTestGitRepo -Path $gitRepoApplyTwice
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'twice-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'twice content'
$runApplyTwice = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyTwice }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyTwice.WrapperExitCode 0 'setup: twice-case implement run succeeds'
$statusApplyTwice = Get-Content -LiteralPath (Join-Path $runApplyTwice.JobDir 'status.json') -Raw | ConvertFrom-Json

$applyTwiceFirst = Invoke-CcodexApplyCommand -JobId $statusApplyTwice.job_id -StateRoot $localAppData
Assert-Equal $applyTwiceFirst.WrapperExitCode 0 'first apply -> exit 0'
$headAfterFirst = (& git -C $gitRepoApplyTwice rev-parse HEAD).Trim()

$applyTwiceSecond = Invoke-CcodexApplyCommand -JobId $statusApplyTwice.job_id -StateRoot $localAppData
Assert-Equal $applyTwiceSecond.WrapperExitCode 25 'applying the same job twice -> second apply exit 25'
$twicePorcelain = @(& git -C $gitRepoApplyTwice status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
Assert-Equal $twicePorcelain.Count 0 'main repo working tree is clean after the already-applied attempt'
$headAfterSecond = (& git -C $gitRepoApplyTwice rev-parse HEAD).Trim()
Assert-Equal $headAfterSecond $headAfterFirst 'already-applied attempt leaves main repo HEAD at the first-apply commit'

Write-Host "apply: per-main-repo lock held externally -> exit 21, main repo untouched"
$gitRepoApplyLocked = Join-Path $tempRoot 'gitrepo-apply-locked'
New-CcodexTestGitRepo -Path $gitRepoApplyLocked
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'locked-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'locked content'
$runApplyLocked = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyLocked }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyLocked.WrapperExitCode 0 'setup: locked-case implement run succeeds'
$statusApplyLocked = Get-Content -LiteralPath (Join-Path $runApplyLocked.JobDir 'status.json') -Raw | ConvertFrom-Json
$lockedMainRepo = [string]$statusApplyLocked.main_repo
$lockedRepoKey = Get-CcodexRepoKey -RepoRoot $lockedMainRepo
$lockedApplyLockDir = Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $localAppData) 'locks') "apply-$lockedRepoKey"
New-Item -ItemType Directory -Path $lockedApplyLockDir -Force | Out-Null
# Hold the same per-main-repo apply lock this process would otherwise take, so the apply below
# cannot acquire it and must time out. The owner is THIS (alive) process, so the lock is never
# broken as stale within the short timeout.
Lock-CcodexJob -JobDir $lockedApplyLockDir -TimeoutSec 5 -CommandName 'test-holder' | Out-Null
$preHeadLocked = (& git -C $gitRepoApplyLocked rev-parse HEAD).Trim()
$applyLocked = Invoke-CcodexApplyCommand -JobId $statusApplyLocked.job_id -StateRoot $localAppData -LockTimeoutSec 1
Assert-Equal $applyLocked.WrapperExitCode 21 'apply while the per-main-repo lock is held -> exit 21'
Assert-True ($applyLocked.Message -like '*apply lock*') 'exit-21 message names the apply lock'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyLocked 'locked-file.txt'))) 'main repo was not mutated while the lock was held (no applied file)'
$postHeadLocked = (& git -C $gitRepoApplyLocked rev-parse HEAD).Trim()
Assert-Equal $postHeadLocked $preHeadLocked 'main repo HEAD unchanged when apply cannot acquire the lock'
Unlock-CcodexJob -JobDir $lockedApplyLockDir
# With the lock released, the same apply now succeeds (proves the lock, not some other gate,
# was what blocked it).
$applyAfterUnlock = Invoke-CcodexApplyCommand -JobId $statusApplyLocked.job_id -StateRoot $localAppData
Assert-Equal $applyAfterUnlock.WrapperExitCode 0 'apply succeeds once the lock is released'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Complete-CcodexTests
