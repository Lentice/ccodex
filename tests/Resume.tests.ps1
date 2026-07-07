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
        [string]$CodexThreadId = $null,
        [string]$Root = $tempRoot
    )
    $repoKey = 'deadbeefcafe'
    $jobDir = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $Root) $JobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null

    $statusObject = New-CcodexStatusObject -JobId $JobId -Status $Status -Mode $Mode -Access $Access -Repo $Repo `
        -CreatedAt (Get-Date).ToUniversalTime().ToString('o') -CodexThreadId $CodexThreadId
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObject

    $indexPath = Get-CcodexIndexPath -JobId $JobId -Root $Root
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

# --- Invoke-CcodexResume (command level) ---

# Bring in the full wrapper (dot-sources every lib and defines Invoke-CcodexResume /
# Invoke-CcodexJobExecution) plus the remaining libs the command path needs.
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\lib\FailureClassify.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly

$cmdRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-resume-cmd-test-$([Guid]::NewGuid().ToString('N'))"
$cmdStateRoot = Join-Path $cmdRoot 'Local'
$cmdAppData = Join-Path $cmdRoot 'Roaming'
$realRepo = Join-Path $cmdRoot 'repo'
New-Item -ItemType Directory -Path $cmdStateRoot, $cmdAppData, $realRepo -Force | Out-Null

$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'
$ccodexScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ccodex.ps1')).Path

Write-Host "Invoke-CcodexResume: happy path resumes a done parent, exits 0, prints only the result"
New-CcodexTestParentJob -JobId 'cmd-parent-done' -Status 'done' -Mode 'brainstorm' -Access 'read-only' -Repo $realRepo -CodexThreadId 'thread-parent' -Root $cmdStateRoot | Out-Null
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'resumed answer text'
$env:CCODEX_FAKE_THREAD_ID = 'child-thread-999'
$resumeResult = Invoke-CcodexResume -ParentJobId 'cmd-parent-done' -PositionalTask 'follow up question' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $resumeResult.WrapperExitCode 0 'resume of a done parent exits 0'
Assert-True ($resumeResult.Stdout -like '*resumed answer text*') 'stdout carries the resumed result content'
Assert-True (-not ($resumeResult.Stdout -like '*fake-codex ran*')) 'raw JSONL events never reach stdout on resume'
Assert-True ($resumeResult.JobId -ne 'cmd-parent-done') 'resume creates a NEW job id (never the parent id)'

$childDir = $resumeResult.JobDir
$childStatus = Get-Content -LiteralPath (Join-Path $childDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $childStatus.status 'done' 'child terminal status is done'
Assert-Equal $childStatus.parent_job_id 'cmd-parent-done' 'child status carries parent_job_id'
Assert-Equal $childStatus.mode 'brainstorm' 'child inherits the parent mode'
Assert-Equal $childStatus.access 'read-only' 'child inherits the parent access'
Assert-Equal $childStatus.repo $realRepo 'child inherits the parent repo'
Assert-Equal $childStatus.codex_thread_id 'child-thread-999' 'child captures its OWN new thread id from events'

$childPrompt = [System.IO.File]::ReadAllText((Join-Path $childDir 'prompt.md'))
Assert-Equal $childPrompt 'follow up question' 'prompt.md is exactly the follow-up text (no worker-prompt template)'

$childCommand = Get-Content -LiteralPath (Join-Path $childDir 'command.txt') -Raw
Assert-True ($childCommand -like '*exec resume thread-parent*') 'command.txt invokes exec resume against the parent thread id'

# Parent job dir is strictly read-only to resume: its status.json is unchanged.
$parentStatusAfter = Get-Content -LiteralPath (Join-Path (Get-CcodexJobRecord -JobId 'cmd-parent-done' -Root $cmdStateRoot).JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $parentStatusAfter.status 'done' 'parent status is untouched by resume'
Assert-True ([string]::IsNullOrEmpty($parentStatusAfter.parent_job_id)) 'parent never gains a parent_job_id from being resumed'

Write-Host "Invoke-CcodexResume: still-running parent -> exit 4 (not-terminal precondition)"
New-CcodexTestParentJob -JobId 'cmd-parent-running' -Status 'running' -Repo $realRepo -CodexThreadId 'thread-run' -Root $cmdStateRoot | Out-Null
$runningResume = Invoke-CcodexResume -ParentJobId 'cmd-parent-running' -PositionalTask 'q' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $runningResume.WrapperExitCode 4 'resume of a running parent exits 4'

Write-Host "Invoke-CcodexResume: scrubbed (null) thread id -> exit 2 with the scrub message"
New-CcodexTestParentJob -JobId 'cmd-parent-scrubbed' -Status 'done' -Repo $realRepo -CodexThreadId $null -Root $cmdStateRoot | Out-Null
$scrubbedResume = Invoke-CcodexResume -ParentJobId 'cmd-parent-scrubbed' -PositionalTask 'q' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $scrubbedResume.WrapperExitCode 2 'resume of a scrubbed parent exits 2'
Assert-True ($scrubbedResume.Message -like '*no codex thread id (absent or scrubbed by cleanup)*') 'scrub message surfaces to the caller'

Write-Host "Invoke-CcodexResume: unknown parent id -> exit 3 (not found)"
$unknownResume = Invoke-CcodexResume -ParentJobId 'cmd-no-such-parent' -PositionalTask 'q' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $unknownResume.WrapperExitCode 3 'resume of an unknown parent exits 3'
Assert-True ($unknownResume.Message -like '*not found (no index entry)*') 'not-found message surfaces to the caller'

Write-Host "Invoke-CcodexResume: multiple prompt sources -> exit 2 (usage error, same message as run)"
$multiPromptFile = Join-Path $cmdRoot 'followup.txt'
[System.IO.File]::WriteAllText($multiPromptFile, 'from file', (New-Object System.Text.UTF8Encoding($false)))
$multiResume = Invoke-CcodexResume -ParentJobId 'cmd-parent-done' -PositionalTask 'from positional' -PromptFile $multiPromptFile `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $multiResume.WrapperExitCode 2 'multiple prompt sources on resume exits 2'
Assert-True ($multiResume.Message -like '*multiple prompt sources*') 'usage error names the multiple-prompt-source conflict'

Write-Host "shell-level: piped follow-up through the dispatcher resumes a done parent -> exit 0"
New-CcodexTestParentJob -JobId 'cmd-parent-shell' -Status 'done' -Mode 'review' -Access 'read-only' -Repo $realRepo -CodexThreadId 'thread-shell' -Root $cmdStateRoot | Out-Null
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'shell resumed answer'
$shellOut = 'piped follow up text' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-shell --state-root $cmdStateRoot --codex-path $fixtureCmd
Assert-Equal $LASTEXITCODE 0 'shell-level resume exits 0'
Assert-True ((($shellOut -join "`n")) -like '*shell resumed answer*') 'shell-level resume prints the resumed result'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_THREAD_ID -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $cmdRoot -Recurse -Force
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
