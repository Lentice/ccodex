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
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Complete-CcodexTests
