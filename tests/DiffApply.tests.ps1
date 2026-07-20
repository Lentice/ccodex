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

Write-Host "resume/diff/apply: worktree child uses a fresh snapshot-seeded worktree and cumulative frozen range"
$resumeRepo = Join-Path $tempRoot 'gitrepo-resume-cumulative'
New-CcodexTestGitRepo -Path $resumeRepo
$seriesBase = (& git -C $resumeRepo rev-parse HEAD).Trim()
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'parent implement done'
$env:CCODEX_FAKE_THREAD_ID = 'thread-worktree-resume'
$env:CCODEX_FAKE_WRITE_FILE = 'parent-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'parent content'
$resumeParent = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $resumeRepo }
Assert-Equal $resumeParent.WrapperExitCode 0 'setup: parent worktree implement run succeeds'
$resumeParentStatus = Get-Content -LiteralPath (Join-Path $resumeParent.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-True (-not [string]::IsNullOrEmpty($resumeParentStatus.snapshot_commit)) 'parent terminal status records snapshot_commit'
Assert-Equal $resumeParentStatus.snapshot_commit ((& git -C $resumeParentStatus.worktree_repo rev-parse HEAD).Trim()) 'parent snapshot_commit equals finalized worktree HEAD'

$env:CCODEX_FAKE_RESULT = 'child implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'child-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'child content'
$resumeChild = Invoke-CcodexResume -ParentJobId $resumeParentStatus.job_id -PositionalTask 'address review feedback' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd `
    -LocalAppDataRoot $localAppData -AppDataRoot $appData
Assert-Equal $resumeChild.WrapperExitCode 0 'sync resume of a worktree parent succeeds'
$resumeChildStatus = Get-Content -LiteralPath (Join-Path $resumeChild.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-True ($resumeChildStatus.worktree_repo -ne $resumeParentStatus.worktree_repo) 'child worktree path is distinct from the parent worktree'
Assert-Equal $resumeChildStatus.base_commit $resumeParentStatus.snapshot_commit 'child own base_commit is the parent frozen snapshot'
Assert-Equal $resumeChildStatus.series_base_commit $seriesBase 'child series_base_commit is the original main base'
Assert-True (Test-Path -LiteralPath (Join-Path $resumeChildStatus.worktree_repo 'parent-change.txt')) 'child worktree starts with the parent accumulated change'
Assert-True (Test-Path -LiteralPath (Join-Path $resumeChildStatus.worktree_repo 'child-change.txt')) 'child worktree contains its own follow-up change'
$resumePrompt = [System.IO.File]::ReadAllText((Join-Path $resumeChild.JobDir 'prompt.md'))
Assert-True ($resumePrompt -like "*NEW isolated git worktree: $($resumeChildStatus.worktree_repo)*") 'child prompt contains the relocation worktree envelope'
Assert-True ($resumePrompt -like "*Artifact directory for this turn: *artifacts*User follow-up:*address review feedback*") 'child prompt contains the relocated artifact path and original follow-up'

$resumeDiff = Invoke-CcodexDiffCommand -JobId $resumeChildStatus.job_id -StateRoot $localAppData
Assert-Equal $resumeDiff.WrapperExitCode 0 'diff of the child cumulative series succeeds'
Assert-True ($resumeDiff.Stdout -like '*parent-change.txt*') 'child diff includes the parent change'
Assert-True ($resumeDiff.Stdout -like '*child-change.txt*') 'child diff includes the child change'

# Mutate the terminal child worktree after finalization. The recorded snapshot endpoint must
# freeze diff/apply and grandchildren against this late commit.
[System.IO.File]::WriteAllText((Join-Path $resumeChildStatus.worktree_repo 'late-mutation.txt'), "late`n", $utf8NoBomTest)
& git -C $resumeChildStatus.worktree_repo add late-mutation.txt | Out-Null
& git -C $resumeChildStatus.worktree_repo commit -q -m 'late mutation after terminal status' | Out-Null
$frozenDiff = Invoke-CcodexDiffCommand -JobId $resumeChildStatus.job_id -StateRoot $localAppData
Assert-True ($frozenDiff.Stdout -notlike '*late-mutation.txt*') 'diff endpoint is frozen at snapshot_commit, not live worktree HEAD'

$env:CCODEX_FAKE_RESULT = 'grandchild implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'grandchild-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'grandchild content'
$resumeGrandchild = Invoke-CcodexResume -ParentJobId $resumeChildStatus.job_id -PositionalTask 'one more adjustment' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd `
    -LocalAppDataRoot $localAppData -AppDataRoot $appData
Assert-Equal $resumeGrandchild.WrapperExitCode 0 'grandchild worktree resume succeeds'
$resumeGrandchildStatus = Get-Content -LiteralPath (Join-Path $resumeGrandchild.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $resumeGrandchildStatus.series_base_commit $seriesBase 'grandchild keeps the original series base B'
Assert-Equal $resumeGrandchildStatus.base_commit $resumeChildStatus.snapshot_commit 'grandchild is seeded from the child recorded snapshot'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $resumeGrandchildStatus.worktree_repo 'late-mutation.txt'))) 'grandchild ignores post-terminal parent worktree mutation'

$resumeApply = Invoke-CcodexApplyCommand -JobId $resumeChildStatus.job_id -StateRoot $localAppData
Assert-Equal $resumeApply.WrapperExitCode 0 'apply of the child cumulative range succeeds on untouched main B'
Assert-True (Test-Path -LiteralPath (Join-Path $resumeRepo 'parent-change.txt')) 'cumulative apply lands the parent change'
Assert-True (Test-Path -LiteralPath (Join-Path $resumeRepo 'child-change.txt')) 'cumulative apply lands the child change'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $resumeRepo 'late-mutation.txt'))) 'cumulative apply excludes post-terminal worktree mutation'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_THREAD_ID, Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue

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

Write-Host "apply: untracked main-repo file without override -> exit 2, repo untouched"
$gitRepoApplyUntrackedDefault = Join-Path $tempRoot 'gitrepo-apply-untracked-default'
New-CcodexTestGitRepo -Path $gitRepoApplyUntrackedDefault
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'default-target.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'default target content'
$runApplyUntrackedDefault = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyUntrackedDefault }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyUntrackedDefault.WrapperExitCode 0 'setup: default-untracked implement run succeeds'
$statusApplyUntrackedDefault = Get-Content -LiteralPath (Join-Path $runApplyUntrackedDefault.JobDir 'status.json') -Raw | ConvertFrom-Json
$defaultScratchPath = Join-Path $gitRepoApplyUntrackedDefault 'scratch.txt'
[System.IO.File]::WriteAllText($defaultScratchPath, "keep default scratch`n", $utf8NoBomTest)
$preHeadUntrackedDefault = (& git -C $gitRepoApplyUntrackedDefault rev-parse HEAD).Trim()

$applyUntrackedDefault = Invoke-CcodexApplyCommand -JobId $statusApplyUntrackedDefault.job_id -StateRoot $localAppData
Assert-Equal $applyUntrackedDefault.WrapperExitCode 2 'apply without --allow-untracked rejects an untracked main-repo file'
Assert-True ($applyUntrackedDefault.Message -like '*scratch.txt*') 'default exit-2 message lists the untracked file'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyUntrackedDefault 'default-target.txt'))) 'default rejection does not land the worker patch'
Assert-Equal ([System.IO.File]::ReadAllText($defaultScratchPath)) "keep default scratch`n" 'default rejection leaves the untracked file untouched'
$postHeadUntrackedDefault = (& git -C $gitRepoApplyUntrackedDefault rev-parse HEAD).Trim()
Assert-Equal $postHeadUntrackedDefault $preHeadUntrackedDefault 'default rejection leaves main repo HEAD unchanged'

Write-Host "apply: --allow-untracked with a non-overlapping file -> patch lands and file survives"
$gitRepoApplyUntrackedAllowed = Join-Path $tempRoot 'gitrepo-apply-untracked-allowed'
New-CcodexTestGitRepo -Path $gitRepoApplyUntrackedAllowed
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'allowed-target.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'allowed target content'
$runApplyUntrackedAllowed = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyUntrackedAllowed }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyUntrackedAllowed.WrapperExitCode 0 'setup: allowed-untracked implement run succeeds'
$statusApplyUntrackedAllowed = Get-Content -LiteralPath (Join-Path $runApplyUntrackedAllowed.JobDir 'status.json') -Raw | ConvertFrom-Json
$allowedScratchPath = Join-Path $gitRepoApplyUntrackedAllowed 'scratch.txt'
[System.IO.File]::WriteAllText($allowedScratchPath, "keep allowed scratch`n", $utf8NoBomTest)
$preHeadUntrackedAllowed = (& git -C $gitRepoApplyUntrackedAllowed rev-parse HEAD).Trim()

# Exercise the shell dispatcher so this scenario covers --allow-untracked parsing as well as
# Invoke-CcodexApplyCommand's behavior.
$applyUntrackedAllowedOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') apply --allow-untracked $statusApplyUntrackedAllowed.job_id --state-root $localAppData
$applyUntrackedAllowedExit = $LASTEXITCODE
Assert-Equal $applyUntrackedAllowedExit 0 'shell apply --allow-untracked with a non-overlapping file -> exit 0'
Assert-True (($applyUntrackedAllowedOutput -join "`n") -like '*applied job*') 'shell dispatcher prints the successful apply line'
Assert-True (Test-Path -LiteralPath (Join-Path $gitRepoApplyUntrackedAllowed 'allowed-target.txt')) 'allowed apply lands the non-overlapping worker patch'
Assert-Equal ([System.IO.File]::ReadAllText($allowedScratchPath)) "keep allowed scratch`n" 'allowed apply preserves the pre-existing untracked file byte-for-byte'
$postHeadUntrackedAllowed = (& git -C $gitRepoApplyUntrackedAllowed rev-parse HEAD).Trim()
Assert-True ($postHeadUntrackedAllowed -ne $preHeadUntrackedAllowed) 'allowed apply advances main repo HEAD'

Write-Host "apply: --allow-untracked overlap -> exit 2 before git am, repo untouched"
$gitRepoApplyUntrackedOverlap = Join-Path $tempRoot 'gitrepo-apply-untracked-overlap'
New-CcodexTestGitRepo -Path $gitRepoApplyUntrackedOverlap
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'overlap.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker overlap content'
$runApplyUntrackedOverlap = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyUntrackedOverlap }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyUntrackedOverlap.WrapperExitCode 0 'setup: overlap-untracked implement run succeeds'
$statusApplyUntrackedOverlap = Get-Content -LiteralPath (Join-Path $runApplyUntrackedOverlap.JobDir 'status.json') -Raw | ConvertFrom-Json
$overlapPath = Join-Path $gitRepoApplyUntrackedOverlap 'overlap.txt'
[System.IO.File]::WriteAllText($overlapPath, "pre-existing overlap`n", $utf8NoBomTest)
$preHeadUntrackedOverlap = (& git -C $gitRepoApplyUntrackedOverlap rev-parse HEAD).Trim()

$applyUntrackedOverlap = Invoke-CcodexApplyCommand -JobId $statusApplyUntrackedOverlap.job_id -StateRoot $localAppData -AllowUntracked
Assert-Equal $applyUntrackedOverlap.WrapperExitCode 2 'allow-untracked rejects a patch path that already exists untracked'
Assert-True ($applyUntrackedOverlap.Message -like '*overlap.txt*') 'overlap exit-2 message names the overlapping path'
Assert-Equal ([System.IO.File]::ReadAllText($overlapPath)) "pre-existing overlap`n" 'overlap rejection preserves the pre-existing file byte-for-byte'
$postHeadUntrackedOverlap = (& git -C $gitRepoApplyUntrackedOverlap rev-parse HEAD).Trim()
Assert-Equal $postHeadUntrackedOverlap $preHeadUntrackedOverlap 'overlap rejection leaves main repo HEAD unchanged'

Write-Host "apply: --allow-untracked with tracked dirt -> exit 2, repo untouched"
$gitRepoApplyTrackedDirtyAllowed = Join-Path $tempRoot 'gitrepo-apply-tracked-dirty-allowed'
New-CcodexTestGitRepo -Path $gitRepoApplyTrackedDirtyAllowed
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'tracked-dirty-target.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'tracked dirty target content'
$runApplyTrackedDirtyAllowed = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyTrackedDirtyAllowed }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyTrackedDirtyAllowed.WrapperExitCode 0 'setup: tracked-dirty-allowed implement run succeeds'
$statusApplyTrackedDirtyAllowed = Get-Content -LiteralPath (Join-Path $runApplyTrackedDirtyAllowed.JobDir 'status.json') -Raw | ConvertFrom-Json
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyTrackedDirtyAllowed 'seed.txt'), "tracked dirt`n", $utf8NoBomTest)
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyTrackedDirtyAllowed 'scratch.txt'), "untracked scratch`n", $utf8NoBomTest)
$preHeadTrackedDirtyAllowed = (& git -C $gitRepoApplyTrackedDirtyAllowed rev-parse HEAD).Trim()

$applyTrackedDirtyAllowed = Invoke-CcodexApplyCommand -JobId $statusApplyTrackedDirtyAllowed.job_id -StateRoot $localAppData -AllowUntracked
Assert-Equal $applyTrackedDirtyAllowed.WrapperExitCode 2 'allow-untracked still rejects a tracked-dirty main repo'
Assert-True ($applyTrackedDirtyAllowed.Message -like '*seed.txt*') 'tracked-dirty exit-2 message names the tracked file'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyTrackedDirtyAllowed 'tracked-dirty-target.txt'))) 'tracked-dirty rejection does not land the worker patch'
$postHeadTrackedDirtyAllowed = (& git -C $gitRepoApplyTrackedDirtyAllowed rev-parse HEAD).Trim()
Assert-Equal $postHeadTrackedDirtyAllowed $preHeadTrackedDirtyAllowed 'tracked-dirty rejection leaves main repo HEAD unchanged'

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

Write-Host "apply: failed --allow-untracked apply restores tracked state without warning about preserved scratch"
$gitRepoApplyConflictUntracked = Join-Path $tempRoot 'gitrepo-apply-conflict-untracked'
New-CcodexTestGitRepo -Path $gitRepoApplyConflictUntracked
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'seed.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker conflict version'
$runApplyConflictUntracked = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyConflictUntracked }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyConflictUntracked.WrapperExitCode 0 'setup: conflict-with-untracked implement run succeeds'
$statusApplyConflictUntracked = Get-Content -LiteralPath (Join-Path $runApplyConflictUntracked.JobDir 'status.json') -Raw | ConvertFrom-Json
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyConflictUntracked 'seed.txt'), "main conflict version`n", $utf8NoBomTest)
& git -C $gitRepoApplyConflictUntracked add seed.txt | Out-Null
& git -C $gitRepoApplyConflictUntracked commit -q -m 'main diverges with untracked scratch' | Out-Null
$conflictScratchPath = Join-Path $gitRepoApplyConflictUntracked 'scratch.txt'
[System.IO.File]::WriteAllText($conflictScratchPath, "preserve conflict scratch`n", $utf8NoBomTest)
$preHeadConflictUntracked = (& git -C $gitRepoApplyConflictUntracked rev-parse HEAD).Trim()

$applyConflictUntracked = Invoke-CcodexApplyCommand -JobId $statusApplyConflictUntracked.job_id -StateRoot $localAppData -AllowUntracked
Assert-Equal $applyConflictUntracked.WrapperExitCode 25 'conflicting allow-untracked apply -> exit 25'
Assert-True ($applyConflictUntracked.Message -notlike '*WARNING:*') 'restored conflict does not warn solely because the pre-existing untracked file remains'
Assert-Equal ([System.IO.File]::ReadAllText($conflictScratchPath)) "preserve conflict scratch`n" 'failed apply preserves the pre-existing untracked file byte-for-byte'
Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $gitRepoApplyConflictUntracked 'seed.txt'))) "main conflict version`n" 'failed apply restores the tracked file content'
$conflictUntrackedPorcelain = @(& git -c core.quotepath=false -C $gitRepoApplyConflictUntracked status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
Assert-Equal $conflictUntrackedPorcelain.Count 1 'restored repo has only the expected pre-existing untracked entry'
Assert-Equal $conflictUntrackedPorcelain[0] '?? scratch.txt' 'restored porcelain entry is the pre-existing scratch file'
$postHeadConflictUntracked = (& git -C $gitRepoApplyConflictUntracked rev-parse HEAD).Trim()
Assert-Equal $postHeadConflictUntracked $preHeadConflictUntracked 'failed apply restores main repo HEAD with untracked file present'

Write-Host "apply: hooks are disabled transactionally and failed multi-patch recovery leaves no hook output"
$gitRepoApplyHookConflict = Join-Path $tempRoot 'gitrepo-apply-hook-conflict'
New-CcodexTestGitRepo -Path $gitRepoApplyHookConflict
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'first-patch.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'first patch'
$runApplyHookConflict = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyHookConflict }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyHookConflict.WrapperExitCode 0 'setup: first patch worktree commit succeeds'
$statusApplyHookConflict = Get-Content -LiteralPath (Join-Path $runApplyHookConflict.JobDir 'status.json') -Raw | ConvertFrom-Json
# Add a second worker-side patch that will conflict after the first email applies.
[System.IO.File]::WriteAllText((Join-Path $statusApplyHookConflict.worktree_repo 'seed.txt'), "worker conflict`n", $utf8NoBomTest)
& git -C $statusApplyHookConflict.worktree_repo add seed.txt | Out-Null
& git -C $statusApplyHookConflict.worktree_repo commit -q -m 'worker conflict patch' | Out-Null
# Model a pre-F3 status that has no frozen endpoint; current jobs deliberately ignore any
# post-terminal commit like the one above and use snapshot_commit instead of live HEAD.
$statusApplyHookConflict.snapshot_commit = $null
Write-CcodexJsonFileAtomic -Path (Join-Path $runApplyHookConflict.JobDir 'status.json') -Object $statusApplyHookConflict
[System.IO.File]::WriteAllText((Join-Path $gitRepoApplyHookConflict 'seed.txt'), "main conflict`n", $utf8NoBomTest)
& git -C $gitRepoApplyHookConflict add seed.txt | Out-Null
& git -C $gitRepoApplyHookConflict commit -q -m 'main conflict patch' | Out-Null
$hookPath = Join-Path $gitRepoApplyHookConflict '.git\hooks\pre-applypatch'
[System.IO.File]::WriteAllText($hookPath, "#!/bin/sh`necho hook > hook-output.txt`n", $utf8NoBomTest)
$hookConflict = Invoke-CcodexApplyCommand -JobId $statusApplyHookConflict.job_id -StateRoot $localAppData
Assert-Equal $hookConflict.WrapperExitCode 25 'multi-patch apply with a later conflict exits 25'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyHookConflict 'hook-output.txt'))) 'transactional apply disables repository hooks, so no hook-created untracked output remains'
$hookConflictPorcelain = @(& git -C $gitRepoApplyHookConflict status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
Assert-Equal $hookConflictPorcelain.Count 0 'failed hook-conflict apply restores a clean main repo'

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

Write-Host "diff/apply: recorded worktree_finalize_error -> exit 12 (uncommitted worker output may be lost)"
$ffMainRepo = Join-Path $tempRoot 'gitrepo-finalize-fail'
New-CcodexTestGitRepo -Path $ffMainRepo
$ffRepoKey = Get-CcodexRepoKey -RepoRoot $ffMainRepo
$ffReservation = Reserve-CcodexJobDir -RepoKey $ffRepoKey -Mode 'implement' -Root $localAppData
$ffJobId = $ffReservation.JobId
$ffJobDir = $ffReservation.JobDir
$ffIndexPath = Get-CcodexIndexPath -JobId $ffJobId -Root $localAppData
New-Item -ItemType Directory -Path (Split-Path -Parent $ffIndexPath) -Force | Out-Null
Write-CcodexJsonFileAtomic -Path $ffIndexPath -Object ([ordered]@{ job_id = $ffJobId; repo_key = $ffRepoKey; job_dir = $ffJobDir })
# A REAL detached worktree at base (empty base..HEAD range), so that WITHOUT the finalize-error
# refuse, diff/apply would see an empty range and report the misleading exit-0 no-op the finding
# describes — the refuse (exit 12) is what this test locks in. worktree_committed=$false here is
# deliberately identical to a clean empty run; only worktree_finalize_error distinguishes the
# "worker output may be lost" case.
$ffWt = New-CcodexJobWorktree -MainRepo $ffMainRepo -JobId $ffJobId -StateRoot $localAppData
$ffWorktree = $ffWt.WorktreePath
$ffBaseCommit = $ffWt.BaseCommit
$ffStatus = New-CcodexStatusObject -JobId $ffJobId -Status 'done' -Mode 'implement' -Access 'worktree' -Repo $ffMainRepo `
    -CreatedAt (Get-Date).ToString('o') -CodexExitCode 0 -WrapperExitCode 0 `
    -MainRepo $ffMainRepo -WorktreeRepo $ffWorktree -BaseCommit $ffBaseCommit -WorktreeCommitted $false `
    -WorktreeFinalizeError 'git commit failed in worktree: simulated finalize failure'
Write-CcodexJsonFileAtomic -Path (Join-Path $ffJobDir 'status.json') -Object $ffStatus

$ffPreHead = (& git -C $ffMainRepo rev-parse HEAD).Trim()
$ffDiff = Invoke-CcodexDiffCommand -JobId $ffJobId -StateRoot $localAppData
Assert-Equal $ffDiff.WrapperExitCode 12 'diff on a job whose worktree finalization failed -> exit 12'
Assert-True ($ffDiff.Message -like "*$ffWorktree*") 'diff exit-12 message names the worktree path'
Assert-True ($ffDiff.Message -like '*uncommitted worker changes*') 'diff exit-12 message warns uncommitted worker changes may exist'

$ffApply = Invoke-CcodexApplyCommand -JobId $ffJobId -StateRoot $localAppData
Assert-Equal $ffApply.WrapperExitCode 12 'apply on a job whose worktree finalization failed -> exit 12'
Assert-True ($ffApply.Message -like "*$ffWorktree*") 'apply exit-12 message names the worktree path'
$ffPostHead = (& git -C $ffMainRepo rev-parse HEAD).Trim()
Assert-Equal $ffPostHead $ffPreHead 'main repo HEAD untouched by the refused apply'

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
# Keep the original third positional parameter contract: it is LockTimeoutSec, not the new switch.
$applyLocked = Invoke-CcodexApplyCommand $statusApplyLocked.job_id $localAppData 1
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

# ============================================================================
# diff --stat / --name-only (#11)
# ============================================================================

Write-Host "diff --stat / --name-only: scoped views vs default stat+patch"
$gitRepoDiffScoped = Join-Path $tempRoot 'gitrepo-diff-scoped'
New-CcodexTestGitRepo -Path $gitRepoDiffScoped
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'scoped-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'scoped body line'
$runDiffScoped = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoDiffScoped }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runDiffScoped.WrapperExitCode 0 'setup: scoped-diff implement run succeeds'
$statusDiffScoped = Get-Content -LiteralPath (Join-Path $runDiffScoped.JobDir 'status.json') -Raw | ConvertFrom-Json

$diffStat = Invoke-CcodexDiffCommand -JobId $statusDiffScoped.job_id -StateRoot $localAppData -Stat
Assert-Equal $diffStat.WrapperExitCode 0 'diff --stat -> exit 0'
Assert-True ($diffStat.Stdout -like '*scoped-change.txt*') 'diff --stat names the changed file'
Assert-True ($diffStat.Stdout -notlike '*+scoped body line*') 'diff --stat omits the full patch body'

$diffNameOnly = Invoke-CcodexDiffCommand -JobId $statusDiffScoped.job_id -StateRoot $localAppData -NameOnly
Assert-Equal $diffNameOnly.WrapperExitCode 0 'diff --name-only -> exit 0'
Assert-Equal $diffNameOnly.Stdout 'scoped-change.txt' 'diff --name-only prints just the changed path'
Assert-True ($diffNameOnly.Stdout -notlike '*|*') 'diff --name-only omits the stat graph'

$diffDefaultScoped = Invoke-CcodexDiffCommand -JobId $statusDiffScoped.job_id -StateRoot $localAppData
Assert-True ($diffDefaultScoped.Stdout -like '*scoped-change.txt*' -and $diffDefaultScoped.Stdout -like '*+scoped body line*') 'default diff still emits stat + full patch'

# Mutual exclusivity + flag-before-id recovery are enforced by the shell dispatcher.
$diffBothOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') diff --stat --name-only $statusDiffScoped.job_id --state-root $localAppData
Assert-Equal $LASTEXITCODE 2 'diff --stat --name-only together -> exit 2'
Assert-True (($diffBothOutput -join "`n") -like '*mutually exclusive*') 'exit-2 message names the mutual exclusivity'

$diffFlagFirstOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') diff --stat $statusDiffScoped.job_id --state-root $localAppData
Assert-Equal $LASTEXITCODE 0 'diff --stat before the job id -> exit 0 (dispatcher recovers the id)'
Assert-True (($diffFlagFirstOutput -join "`n") -like '*scoped-change.txt*') 'flag-first diff --stat still resolves the job'

Write-Host "diff --stat: empty-change job -> shared no-changes message"
$diffStatEmpty = Invoke-CcodexDiffCommand -JobId $statusEmpty.job_id -StateRoot $localAppData -Stat
Assert-Equal $diffStatEmpty.WrapperExitCode 0 'diff --stat on an empty-change job -> exit 0'
Assert-True ($diffStatEmpty.Stdout -like '*no changes*') 'diff --stat empty-change reuses the no-changes message'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# ============================================================================
# apply --message / --reset-author (#12)
# ============================================================================

Write-Host "apply --reset-author / --message: land with operator identity in one step"
$gitRepoApplyIdent = Join-Path $tempRoot 'gitrepo-apply-identity'
New-CcodexTestGitRepo -Path $gitRepoApplyIdent
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'identity-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'identity content'
$runApplyIdent = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyIdent }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyIdent.WrapperExitCode 0 'setup: identity-case implement run succeeds'
$statusApplyIdent = Get-Content -LiteralPath (Join-Path $runApplyIdent.JobDir 'status.json') -Raw | ConvertFrom-Json

$applyIdent = Invoke-CcodexApplyCommand -JobId $statusApplyIdent.job_id -StateRoot $localAppData -ResetAuthor -Message 'feat: land via ccodex apply'
Assert-Equal $applyIdent.WrapperExitCode 0 'apply --reset-author --message -> exit 0'
Assert-True (Test-Path -LiteralPath (Join-Path $gitRepoApplyIdent 'identity-file.txt')) 'apply still lands the worker content'
$identAuthor = (& git -C $gitRepoApplyIdent log -1 --format='%an <%ae>').Trim()
Assert-Equal $identAuthor 'ccodex test <test@example.com>' '--reset-author reauthors to the main repo git identity'
$identSubject = (& git -C $gitRepoApplyIdent log -1 --format='%s').Trim()
Assert-Equal $identSubject 'feat: land via ccodex apply' '--message sets the landed commit subject'
Assert-True ($applyIdent.Stdout -like "*$((& git -C $gitRepoApplyIdent rev-parse HEAD).Trim())*") 'stdout reports the amended HEAD'

Write-Host "apply --reset-author only: message preserved, author reset"
$gitRepoApplyResetOnly = Join-Path $tempRoot 'gitrepo-apply-reset-only'
New-CcodexTestGitRepo -Path $gitRepoApplyResetOnly
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'reset-only.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'reset only content'
$runApplyResetOnly = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyResetOnly }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
$statusApplyResetOnly = Get-Content -LiteralPath (Join-Path $runApplyResetOnly.JobDir 'status.json') -Raw | ConvertFrom-Json
# Exercise the shell dispatcher with the flag before the job id.
$applyResetOnlyOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') apply --reset-author $statusApplyResetOnly.job_id --state-root $localAppData
Assert-Equal $LASTEXITCODE 0 'shell apply --reset-author before the id -> exit 0'
Assert-True (($applyResetOnlyOutput -join "`n") -like '*applied job*') 'shell dispatcher prints the applied line'
$resetOnlyAuthor = (& git -C $gitRepoApplyResetOnly log -1 --format='%an <%ae>').Trim()
Assert-Equal $resetOnlyAuthor 'ccodex test <test@example.com>' '--reset-author alone reauthors the landed commit'
$resetOnlySubject = (& git -C $gitRepoApplyResetOnly log -1 --format='%s').Trim()
Assert-Equal $resetOnlySubject "ccodex: worker output $($statusApplyResetOnly.job_id)" '--reset-author alone preserves the worker commit message'

Write-Host "apply --message on a multi-commit series -> exit 2 before mutation"
$gitRepoApplyMulti = Join-Path $tempRoot 'gitrepo-apply-multi'
New-CcodexTestGitRepo -Path $gitRepoApplyMulti
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'multi-first.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'multi first'
$runApplyMulti = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyMulti }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
$statusApplyMulti = Get-Content -LiteralPath (Join-Path $runApplyMulti.JobDir 'status.json') -Raw | ConvertFrom-Json
# Add a second worker-side commit and drop the frozen snapshot so the range spans both commits.
[System.IO.File]::WriteAllText((Join-Path $statusApplyMulti.worktree_repo 'multi-second.txt'), "multi second`n", $utf8NoBomTest)
& git -C $statusApplyMulti.worktree_repo add multi-second.txt | Out-Null
& git -C $statusApplyMulti.worktree_repo commit -q -m 'second worker commit' | Out-Null
$statusApplyMulti.snapshot_commit = $null
Write-CcodexJsonFileAtomic -Path (Join-Path $runApplyMulti.JobDir 'status.json') -Object $statusApplyMulti
$preHeadMulti = (& git -C $gitRepoApplyMulti rev-parse HEAD).Trim()

$applyMulti = Invoke-CcodexApplyCommand -JobId $statusApplyMulti.job_id -StateRoot $localAppData -Message 'should be rejected'
Assert-Equal $applyMulti.WrapperExitCode 2 'apply --message on a 2-commit series -> exit 2'
Assert-True ($applyMulti.Message -like '*single-commit apply*') 'exit-2 message explains the single-commit restriction'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyMulti 'multi-first.txt'))) 'rejected multi-commit apply did not mutate the main repo'
$postHeadMulti = (& git -C $gitRepoApplyMulti rev-parse HEAD).Trim()
Assert-Equal $postHeadMulti $preHeadMulti 'rejected multi-commit apply leaves main repo HEAD unchanged'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

Write-Host "apply --message: a valueless flag is a usage error (exit 2), never a silent no-op or a consumed next flag"
$gitRepoApplyMsgArg = Join-Path $tempRoot 'gitrepo-apply-message-argparse'
New-CcodexTestGitRepo -Path $gitRepoApplyMsgArg
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'msgarg-file.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'msgarg content'
$runApplyMsgArg = Invoke-CcodexRunForTest -Overrides @{ RepoOverride = $gitRepoApplyMsgArg }
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
Assert-Equal $runApplyMsgArg.WrapperExitCode 0 'setup: message-argparse implement run succeeds'
$statusApplyMsgArg = Get-Content -LiteralPath (Join-Path $runApplyMsgArg.JobDir 'status.json') -Raw | ConvertFrom-Json
$preHeadMsgArg = (& git -C $gitRepoApplyMsgArg rev-parse HEAD).Trim()

# Trailing --message with no value must be rejected, not silently ignored (which would land the
# worker's default commit message while the caller believes the message was rewritten).
$msgTrailingOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') apply $statusApplyMsgArg.job_id --message --state-root $localAppData
Assert-Equal $LASTEXITCODE 2 'apply <job> --message (no value) -> exit 2'
Assert-True (($msgTrailingOutput -join "`n") -like '*--message requires a value*') 'trailing --message exit-2 message names the flag'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyMsgArg 'msgarg-file.txt'))) 'rejected trailing --message does not land the worker patch'
Assert-Equal ((& git -C $gitRepoApplyMsgArg rev-parse HEAD).Trim()) $preHeadMsgArg 'rejected trailing --message leaves main repo HEAD unchanged'

# --message immediately followed by another flag must NOT swallow that flag as the message value.
$msgSwallowOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') apply $statusApplyMsgArg.job_id --message --reset-author --state-root $localAppData
Assert-Equal $LASTEXITCODE 2 'apply <job> --message --reset-author -> exit 2 (next flag is not consumed as the message)'
Assert-True (($msgSwallowOutput -join "`n") -like '*--message requires a value*') 'flag-swallow exit-2 message names the flag'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepoApplyMsgArg 'msgarg-file.txt'))) 'rejected --message --reset-author does not land the worker patch'
Assert-Equal ((& git -C $gitRepoApplyMsgArg rev-parse HEAD).Trim()) $preHeadMsgArg 'rejected --message --reset-author leaves main repo HEAD unchanged'

# A real value still works through the dispatcher.
$msgValidOutput = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\ccodex.ps1') apply $statusApplyMsgArg.job_id --message 'land with a real subject' --state-root $localAppData
Assert-Equal $LASTEXITCODE 0 'apply <job> --message <value> -> exit 0'
Assert-Equal ((& git -C $gitRepoApplyMsgArg log -1 --format='%s').Trim()) 'land with a real subject' 'a real --message value sets the landed commit subject'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# ============================================================================
# Get-CcodexApplyRestoreState (shared rollback verification for the git-am and
# --message/--reset-author amend failure paths) (#12 hardening)
# ============================================================================

Write-Host "Get-CcodexApplyRestoreState: reports honest restored/not-restored state after a rollback"
$gitRepoRestore = Join-Path $tempRoot 'gitrepo-restore-verify'
New-CcodexTestGitRepo -Path $gitRepoRestore
$restorePreHead = (& git -C $gitRepoRestore rev-parse HEAD).Trim()

# Clean repo whose HEAD equals the pre-apply commit: a genuine, verified restoration.
$restoreClean = Get-CcodexApplyRestoreState -MainRepo $gitRepoRestore -PreHead $restorePreHead
Assert-True $restoreClean.Restored 'restore verification: clean repo at pre-apply HEAD -> Restored'
Assert-Equal $restoreClean.Head $restorePreHead 'restore verification: reports the actual current HEAD'
Assert-Equal $restoreClean.UnexpectedLines.Count 0 'restore verification: no unexpected working-tree lines when clean'

# HEAD advanced past the pre-apply commit (as it would be if `git reset --hard` failed to roll
# back after an amend failure): must be reported as NOT restored, naming the wrong HEAD.
[System.IO.File]::WriteAllText((Join-Path $gitRepoRestore 'stuck.txt'), "stuck`n", $utf8NoBomTest)
& git -C $gitRepoRestore add stuck.txt | Out-Null
& git -C $gitRepoRestore commit -q -m 'commit that a failed rollback would leave behind' | Out-Null
$restoreStuckHead = (& git -C $gitRepoRestore rev-parse HEAD).Trim()
$restoreStuck = Get-CcodexApplyRestoreState -MainRepo $gitRepoRestore -PreHead $restorePreHead
Assert-True (-not $restoreStuck.Restored) 'restore verification: HEAD ahead of pre-apply commit -> NOT Restored'
Assert-Equal $restoreStuck.Head $restoreStuckHead 'restore verification: names the actual (wrong) HEAD when not restored'

# Uncommitted tracked change without --allow-untracked is also unexpected -> NOT restored.
& git -C $gitRepoRestore reset --hard $restorePreHead -q | Out-Null
[System.IO.File]::WriteAllText((Join-Path $gitRepoRestore 'seed.txt'), "dirtied after rollback`n", $utf8NoBomTest)
$restoreDirty = Get-CcodexApplyRestoreState -MainRepo $gitRepoRestore -PreHead $restorePreHead
Assert-True (-not $restoreDirty.Restored) 'restore verification: dirty tracked tree -> NOT Restored'
Assert-True ($restoreDirty.UnexpectedLines.Count -gt 0) 'restore verification: surfaces the unexpected dirty line'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Complete-CcodexTests
