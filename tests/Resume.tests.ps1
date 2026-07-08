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
$expectedReadOnly = @('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', 'resume', 'thread-abc', '-')
Assert-Equal ($argsReadOnly -join '|') ($expectedReadOnly -join '|') 'read-only access produces the exact spliced resume argument shape'

Write-Host "Build-CcodexResumeArgs: exact spliced argument shape for workspace access"
$argsWorkspace = Build-CcodexResumeArgs -ThreadId 'thread-xyz' -Access 'workspace' -RepoRoot 'D:\OtherRepo' -ResultPath 'D:\Job2\result.md'
$expectedWorkspace = @('--ask-for-approval', 'never', 'exec', '--sandbox', 'workspace-write', '--json', '--color', 'never', '-C', 'D:\OtherRepo', '--output-last-message', 'D:\Job2\result.md', 'resume', 'thread-xyz', '-')
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
Assert-True ($childCommand -like '*--output-last-message*resume thread-parent*') 'command.txt splices resume <thread id> after the exec-level options (clap rejects exec options placed after the resume token)'

# Parent job dir is strictly read-only to resume: its status.json is unchanged.
$parentStatusAfter = Get-Content -LiteralPath (Join-Path (Get-CcodexJobRecord -JobId 'cmd-parent-done' -Root $cmdStateRoot).JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $parentStatusAfter.status 'done' 'parent status is untouched by resume'
Assert-True ([string]::IsNullOrEmpty($parentStatusAfter.parent_job_id)) 'parent never gains a parent_job_id from being resumed'

Write-Host "Invoke-CcodexResume: child inherits the parent's thread id when its own run emits NO thread event"
# No CCODEX_FAKE_THREAD_ID => the fixture emits no thread.started event, so Get-CcodexCodexThreadId
# finds nothing and the child must fall back to the parent's thread id (a resume continues the SAME
# thread). Without the fallback the child would end with a blank codex_thread_id and be un-resumable.
Remove-Item Env:\CCODEX_FAKE_THREAD_ID -ErrorAction SilentlyContinue
New-CcodexTestParentJob -JobId 'cmd-parent-nofallback' -Status 'done' -Mode 'review' -Access 'read-only' -Repo $realRepo -CodexThreadId 'thread-parent-inherited' -Root $cmdStateRoot | Out-Null
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'answer with no thread event'
$noEventResume = Invoke-CcodexResume -ParentJobId 'cmd-parent-nofallback' -PositionalTask 'follow up' `
    -PipelineExpected $false -PipelineObjects $null -CodexPath $fixtureCmd -LocalAppDataRoot $cmdStateRoot -AppDataRoot $cmdAppData
Assert-Equal $noEventResume.WrapperExitCode 0 'resume with no thread event still exits 0'
$noEventChildStatus = Get-Content -LiteralPath (Join-Path $noEventResume.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $noEventChildStatus.codex_thread_id 'thread-parent-inherited' 'child codex_thread_id falls back to the parent thread id when no thread event was emitted'
# The child is now itself resumable: a second resume addressing the child passes the thread-id precondition.
$noEventChildId = $noEventResume.JobId
$secondCtx = Get-CcodexResumeContext -ParentJobId $noEventChildId -StateRoot $cmdStateRoot
Assert-Equal $secondCtx.ThreadId 'thread-parent-inherited' 'resuming the child inherits the same thread id (chaining works)'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

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

Write-Host "shell-level: resume rejects --repo/--mode/--access (inherited from parent) and extra positionals -> exit 2"
# A resumable parent so that WITHOUT the guard these invocations would run to exit 0 (silently
# ignoring the flag / dropping the extra positional). The guard makes each exit 2 before any work.
New-CcodexTestParentJob -JobId 'cmd-parent-reject' -Status 'done' -Mode 'review' -Access 'read-only' -Repo $realRepo -CodexThreadId 'thread-reject' -Root $cmdStateRoot | Out-Null
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'should not run'

$rejRepo = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-reject --repo $realRepo --state-root $cmdStateRoot --codex-path $fixtureCmd 2>&1
Assert-Equal $LASTEXITCODE 2 'resume with --repo exits 2'
Assert-True ((($rejRepo -join "`n")) -like '*--repo*') 'resume --repo rejection names --repo'

$rejMode = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-reject --mode brainstorm --state-root $cmdStateRoot --codex-path $fixtureCmd 2>&1
Assert-Equal $LASTEXITCODE 2 'resume with --mode exits 2'
Assert-True ((($rejMode -join "`n")) -like '*--mode*') 'resume --mode rejection names --mode'

$rejAccess = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-reject --access workspace --state-root $cmdStateRoot --codex-path $fixtureCmd 2>&1
Assert-Equal $LASTEXITCODE 2 'resume with --access exits 2'
Assert-True ((($rejAccess -join "`n")) -like '*--access*') 'resume --access rejection names --access'

$rejPositional = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-reject extratext --state-root $cmdStateRoot --codex-path $fixtureCmd 2>&1
Assert-Equal $LASTEXITCODE 2 'resume with an extra positional after the job id exits 2'
Assert-True ((($rejPositional -join "`n")) -like '*extra positional*') 'extra-positional rejection mentions extra positional arguments'

# The plain piped-follow-up form (no rejected flags/positionals) is still accepted -> exit 0.
$rejOk = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath resume cmd-parent-reject --state-root $cmdStateRoot --codex-path $fixtureCmd 2>&1
Assert-Equal $LASTEXITCODE 0 'plain piped resume (no rejected flags) still exits 0'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_THREAD_ID -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $cmdRoot -Recurse -Force
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
