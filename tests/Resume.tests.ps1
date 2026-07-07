# tests/Resume.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot '..\lib\Resume.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-resume-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CcodexTestParentJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$Repo = 'D:\Repo',
        [string]$CodexThreadId = $null
    )
    $repoKey = 'deadbeefcafe'
    $jobDir = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $tempRoot) $JobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null

    $statusObject = New-CcodexStatusObject -JobId $JobId -Status $Status -Mode $Mode -Access $Access -Repo $Repo `
        -CreatedAt (Get-Date).ToUniversalTime().ToString('o') -CodexThreadId $CodexThreadId
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObject

    $indexPath = Get-CcodexIndexPath -JobId $JobId -Root $tempRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $JobId; repo_key = $repoKey; job_dir = $jobDir })

    return $jobDir
}

# --- Get-CcodexResumeContext ---

Write-Host "Get-CcodexResumeContext: terminal 'done' parent with a thread id returns full context"
New-CcodexTestParentJob -JobId 'parent-done' -Status 'done' -Mode 'brainstorm' -Access 'workspace' -Repo 'D:\SomeRepo' -CodexThreadId 'thread-111' | Out-Null
$ctx = Get-CcodexResumeContext -ParentJobId 'parent-done' -StateRoot $tempRoot
Assert-Equal $ctx.ParentJobId 'parent-done' 'context carries the parent job id'
Assert-Equal $ctx.ThreadId 'thread-111' 'context carries the codex thread id'
Assert-Equal $ctx.Mode 'brainstorm' 'context carries the parent mode verbatim'
Assert-Equal $ctx.Access 'workspace' 'context carries the parent access verbatim'
Assert-Equal $ctx.Repo 'D:\SomeRepo' 'context carries the parent repo verbatim'

Write-Host "Get-CcodexResumeContext: still-running parent throws a not-terminal error"
New-CcodexTestParentJob -JobId 'parent-running' -Status 'running' -CodexThreadId 'thread-222' | Out-Null
Assert-Throws { Get-CcodexResumeContext -ParentJobId 'parent-running' -StateRoot $tempRoot } 'running parent is rejected'
Assert-True ($script:CcodexLastError -like "*parent-running*" -and $script:CcodexLastError -like '*running*') 'not-terminal message names the job id and its current status'

Write-Host "Get-CcodexResumeContext: scrubbed (null) thread id throws the distinct scrub message"
New-CcodexTestParentJob -JobId 'parent-scrubbed' -Status 'done' -CodexThreadId $null | Out-Null
Assert-Throws { Get-CcodexResumeContext -ParentJobId 'parent-scrubbed' -StateRoot $tempRoot } 'scrubbed thread id is rejected'
Assert-Equal $script:CcodexLastError "ccodex: job 'parent-scrubbed' has no codex thread id (absent or scrubbed by cleanup) - start a fresh run." 'scrub message is exact'

Write-Host "Get-CcodexResumeContext: unknown job id throws the standard not-found message"
Assert-Throws { Get-CcodexResumeContext -ParentJobId 'no-such-parent' -StateRoot $tempRoot } 'unknown parent id is rejected'
Assert-Equal $script:CcodexLastError "ccodex: job 'no-such-parent' not found (no index entry)." 'not-found message is exact and reused from Get-CcodexJobRecord'

Write-Host "Get-CcodexResumeContext: a FAILED parent WITH a thread id is allowed (answering a failure follow-up)"
New-CcodexTestParentJob -JobId 'parent-failed' -Status 'failed' -Mode 'test' -Access 'read-only' -Repo 'D:\FailRepo' -CodexThreadId 'thread-333' | Out-Null
$ctxFailed = Get-CcodexResumeContext -ParentJobId 'parent-failed' -StateRoot $tempRoot
Assert-Equal $ctxFailed.ThreadId 'thread-333' 'a failed parent with a thread id yields full context'
Assert-Equal $ctxFailed.Mode 'test' 'failed-parent context still carries its mode'

Write-Host "Get-CcodexResumeContext: worktree-access parent throws the distinct not-supported message"
New-CcodexTestParentJob -JobId 'parent-worktree' -Status 'done' -Mode 'implement' -Access 'worktree' -CodexThreadId 'thread-444' | Out-Null
Assert-Throws { Get-CcodexResumeContext -ParentJobId 'parent-worktree' -StateRoot $tempRoot } 'worktree-access parent is rejected'
Assert-Equal $script:CcodexLastError "ccodex: job 'parent-worktree' ran in worktree access mode - resume is not supported for worktree jobs; start a fresh run." 'worktree-not-supported message is exact'

# --- Build-CcodexResumeArgs ---

Write-Host "Build-CcodexResumeArgs: exact spliced argument shape for read-only access"
$argsReadOnly = Build-CcodexResumeArgs -ThreadId 'thread-abc' -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md'
$expectedReadOnly = @('--ask-for-approval', 'never', 'exec', 'resume', 'thread-abc', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-')
Assert-Equal ($argsReadOnly -join '|') ($expectedReadOnly -join '|') 'read-only access produces the exact spliced resume argument shape'

Write-Host "Build-CcodexResumeArgs: exact spliced argument shape for workspace access"
$argsWorkspace = Build-CcodexResumeArgs -ThreadId 'thread-xyz' -Access 'workspace' -RepoRoot 'D:\OtherRepo' -ResultPath 'D:\Job2\result.md'
$expectedWorkspace = @('--ask-for-approval', 'never', 'exec', 'resume', 'thread-xyz', '--sandbox', 'workspace-write', '--json', '--color', 'never', '-C', 'D:\OtherRepo', '--output-last-message', 'D:\Job2\result.md', '-')
Assert-Equal ($argsWorkspace -join '|') ($expectedWorkspace -join '|') 'workspace access produces the exact spliced resume argument shape (sandbox mapped via ConvertTo-CcodexSandboxFlag)'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
