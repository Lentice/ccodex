# tests/RunCommand.tests.ps1
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
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-runcommand-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
New-Item -ItemType Directory -Path $localAppData, $appData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '..\templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$repoRoot = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

# A real git repo (with one commit) is required for --access worktree runs (Phase 4 Task 3):
# New-CcodexJobWorktree detaches a worktree at the main repo's HEAD. Read-only/workspace runs
# keep using the plain $repoRoot above so their behavior stays byte-stable.
$utf8NoBomTest = New-Object System.Text.UTF8Encoding($false)
$gitRepo = Join-Path $tempRoot 'gitrepo'
New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
& git -C $gitRepo init -q 2>$null | Out-Null
& git -C $gitRepo config user.email 'test@example.com' | Out-Null
& git -C $gitRepo config user.name 'ccodex test' | Out-Null
[System.IO.File]::WriteAllText((Join-Path $gitRepo 'seed.txt'), "seed`n", $utf8NoBomTest)
& git -C $gitRepo add seed.txt | Out-Null
& git -C $gitRepo commit -q -m 'init' | Out-Null

$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'
$ccodexScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\ccodex.ps1')).Path

function Invoke-CcodexRunForTest {
    param([hashtable]$Overrides = @{})
    $base = @{
        Mode                   = 'review'
        Access                 = $null
        RepoOverride           = $repoRoot
        PromptFile             = $null
        PositionalTask         = 'do the review'
        PipelineExpected       = $false
        PipelineObjects        = $null
        CodexPath              = $fixtureCmd
        LocalAppDataRoot       = $localAppData
        AppDataRoot            = $appData
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return Invoke-CcodexRun @base
}

Write-Host "successful run: exit 0, job files written, only result printed"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'REVIEW: looks fine'
$result = Invoke-CcodexRunForTest
Assert-Equal $result.WrapperExitCode 0 'wrapper exit code is 0 on success'
Assert-True ($result.Stdout -like '*REVIEW: looks fine*') 'stdout carries only the fake result content'
Assert-True (-not ($result.Stdout -like '*fake-codex ran*')) 'raw JSONL events never reach stdout'

$jobDir = $result.JobDir
foreach ($file in @('prompt.md', 'command.txt', 'debug.json', 'status.json', 'codex-events.jsonl', 'stderr.log', 'exit_code.txt', 'worker-complete.json', 'result.md')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $jobDir $file) -PathType Leaf) "writes $file"
}
$statusJson = Get-Content -LiteralPath (Join-Path $jobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusJson.status 'done' 'final status.json status is done'
Assert-Equal $statusJson.codex_exit_code 0 'status.json records codex_exit_code separately'
Assert-Equal $statusJson.wrapper_exit_code 0 'status.json records wrapper_exit_code separately'

Write-Host "jobs are written under the global state root, not under the repo"
Assert-True ($jobDir -like "$localAppData*") 'job dir lives under the fake LOCALAPPDATA root'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.ccodex\jobs'))) 'no .ccodex/jobs is created inside the repo'

Write-Host "mode 'test' without --access workspace fails before invoking codex"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$result2 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'test'; Access = $null }
Assert-Equal $result2.WrapperExitCode 2 'exit code 2 for test mode without --access workspace'

Write-Host "mode 'implement' runs in an isolated worktree and snapshots the worker's changes"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'implement done'
$env:CCODEX_FAKE_WRITE_FILE = 'worker-change.txt'
$env:CCODEX_FAKE_WRITE_TEXT = 'worker wrote this'
$baseHead = (& git -C $gitRepo rev-parse HEAD).Trim()
$result3 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'implement'; RepoOverride = $gitRepo; PositionalTask = 'do the implement task' }
Assert-Equal $result3.WrapperExitCode 0 'exit code 0 for implement mode with worktree access'
$status3 = Get-Content -LiteralPath (Join-Path $result3.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $status3.status 'done' 'worktree implement run reaches terminal done'
Assert-Equal $status3.access 'worktree' 'implement run resolves to worktree access'
Assert-Equal $status3.main_repo $gitRepo 'status.json records main_repo as the target repo'
Assert-True (-not [string]::IsNullOrEmpty($status3.worktree_repo)) 'status.json records worktree_repo'
Assert-Equal $status3.base_commit $baseHead 'status.json records the base commit (main repo HEAD at creation)'
Assert-Equal $status3.worktree_committed $true 'worktree_committed is true when the worker changed a file'
# The worker file lands in the WORKTREE, never in the main repo.
Assert-True (Test-Path -LiteralPath (Join-Path $status3.worktree_repo 'worker-change.txt') -PathType Leaf) 'worker file exists inside the worktree'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $gitRepo 'worker-change.txt'))) 'worker file is absent from the main repo (never mutated)'
# The worktree lives under the state root, never inside the target repo.
Assert-True ($status3.worktree_repo -like "$localAppData*") 'the worktree lives under the state root'
# The main repo HEAD is untouched by the run.
Assert-Equal ((& git -C $gitRepo rev-parse HEAD).Trim()) $baseHead 'the main repo HEAD does not move during the run'
# The worktree HEAD is ahead of base by exactly the one snapshot commit.
$worktreeAhead = (& git -C $status3.worktree_repo rev-list --count "$baseHead..HEAD").Trim()
Assert-Equal $worktreeAhead '1' 'the worktree HEAD is exactly one snapshot commit ahead of base'
$worktreeCommitMsg = (& git -C $status3.worktree_repo log -1 '--format=%s').Trim()
Assert-True ($worktreeCommitMsg -like 'ccodex: worker output *') 'the snapshot commit uses the fixed ccodex message template'
Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue

Write-Host "mode 'implement' with no worker changes -> worktree_committed=false, worktree HEAD stays at base"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'nothing to change'
$baseHeadNoWrite = (& git -C $gitRepo rev-parse HEAD).Trim()
$resultNoWrite = Invoke-CcodexRunForTest -Overrides @{ Mode = 'implement'; RepoOverride = $gitRepo; PositionalTask = 'inspect only' }
Assert-Equal $resultNoWrite.WrapperExitCode 0 'no-write implement run still exits 0'
$statusNoWrite = Get-Content -LiteralPath (Join-Path $resultNoWrite.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusNoWrite.worktree_committed $false 'worktree_committed is false when the worker wrote nothing'
Assert-Equal ((& git -C $statusNoWrite.worktree_repo rev-parse HEAD).Trim()) $baseHeadNoWrite 'worktree HEAD stays at base when nothing was committed'

Write-Host "mode 'implement' rejects --access workspace (worktree only)"
$result3b = Invoke-CcodexRunForTest -Overrides @{ Mode = 'implement'; Access = 'workspace' }
Assert-Equal $result3b.WrapperExitCode 2 'exit code 2 for implement mode with --access workspace'

Write-Host "mode 'test' with --access workspace creates an artifacts dir and injects it into the prompt"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'artifact test done'
$result4 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'test'; Access = 'workspace'; PositionalTask = 'run the browser test' }
Assert-Equal $result4.WrapperExitCode 0 'workspace access succeeds against the fixture'
Assert-True (Test-Path -LiteralPath (Join-Path $result4.JobDir 'artifacts') -PathType Container) 'creates <job_dir>/artifacts'
$promptContent = Get-Content -LiteralPath (Join-Path $result4.JobDir 'prompt.md') -Raw
Assert-True ($promptContent -like "*$(Join-Path $result4.JobDir 'artifacts')*") 'prompt.md references the absolute artifact directory'

Write-Host "codex exit nonzero -> wrapper exit code 10, worker-complete.json still written"
$env:CCODEX_FAKE_EXIT_CODE = '3'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$result5 = Invoke-CcodexRunForTest
Assert-Equal $result5.WrapperExitCode 10 'wrapper exit code is 10 when codex exits nonzero'
Assert-True (Test-Path -LiteralPath (Join-Path $result5.JobDir 'worker-complete.json') -PathType Leaf) 'worker-complete.json exists on the failure path too'

Write-Host "codex launch failure -> wrapper exit 12 with terminal failed status.json + worker-complete.json"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$missingCodex = Join-Path $tempRoot 'no-such-codex.exe'
$result6 = Invoke-CcodexRunForTest -Overrides @{ CodexPath = $missingCodex }
Assert-Equal $result6.WrapperExitCode 12 'wrapper exit code is 12 when the codex process cannot be launched'
$failDir = $result6.JobDir
Assert-True (Test-Path -LiteralPath (Join-Path $failDir 'worker-complete.json') -PathType Leaf) 'worker-complete.json is written on the launch-failure path'
Assert-True (Test-Path -LiteralPath (Join-Path $failDir 'status.json') -PathType Leaf) 'status.json is written on the launch-failure path'
$failStatus = Get-Content -LiteralPath (Join-Path $failDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $failStatus.status 'failed' 'launch-failure status.json is terminal failed'
Assert-Equal $failStatus.wrapper_exit_code 12 'launch-failure status.json records wrapper_exit_code 12'
Assert-True ($null -eq $failStatus.codex_exit_code) 'launch-failure status.json leaves codex_exit_code null'
$failComplete = Get-Content -LiteralPath (Join-Path $failDir 'worker-complete.json') -Raw | ConvertFrom-Json
Assert-Equal $failComplete.status_candidate 'failed' 'launch-failure worker-complete.json status_candidate is failed'
Assert-Equal $failComplete.wrapper_exit_code 12 'launch-failure worker-complete.json records wrapper_exit_code 12'

Write-Host "run --hard-timeout-sec 1 against a sleeping fixture -> wrapper 24, terminal timed_out, codex_exit_code null"
$env:CCODEX_FAKE_DELAY_MS = '8000'
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'should never be written'
$resultTimeout = Invoke-CcodexRunForTest -Overrides @{ HardTimeoutSec = 1 }
Assert-Equal $resultTimeout.WrapperExitCode 24 'wrapper exit code is 24 on a hard timeout'
$timeoutDir = $resultTimeout.JobDir
$timeoutStatus = Get-Content -LiteralPath (Join-Path $timeoutDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $timeoutStatus.status 'timed_out' 'status.json status is timed_out'
Assert-True ($null -eq $timeoutStatus.codex_exit_code) 'codex_exit_code stays null on a hard timeout'
Assert-Equal $timeoutStatus.wrapper_exit_code 24 'status.json records wrapper_exit_code 24'
Assert-True ($timeoutStatus.timeout_reason -like '*hard_timeout_sec=1*') 'timeout_reason names the exceeded budget'
Assert-True (-not [string]::IsNullOrEmpty($timeoutStatus.terminated_at)) 'terminated_at is stamped'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $timeoutDir 'exit_code.txt') -PathType Leaf)) 'no exit_code.txt is written on a hard timeout'
Assert-True (Test-Path -LiteralPath (Join-Path $timeoutDir 'worker-complete.json') -PathType Leaf) 'worker-complete.json is written on the timeout path'
$timeoutComplete = Get-Content -LiteralPath (Join-Path $timeoutDir 'worker-complete.json') -Raw | ConvertFrom-Json
Assert-Equal $timeoutComplete.status_candidate 'timed_out' 'worker-complete.json status_candidate is timed_out'
Assert-Equal $timeoutComplete.wrapper_exit_code 24 'worker-complete.json records wrapper_exit_code 24'
Remove-Item Env:\CCODEX_FAKE_DELAY_MS, Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

Write-Host "ConvertTo-CcodexHardTimeoutSec: 0 and positive integers parse; negative/non-numeric throw naming the flag"
Assert-Equal (ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '0') 0 '0 (never) parses as a valid value'
Assert-Equal (ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '120') 120 'a positive integer parses through unchanged'
Assert-Throws { ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '-1' } 'a negative value throws instead of silently becoming 0/never'
Assert-True ($script:CcodexLastError -like '*--hard-timeout-sec*') 'the negative-value error names the flag'
Assert-Throws { ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText 'abc' } 'non-numeric text throws instead of an unrelated internal error'
Assert-True ($script:CcodexLastError -like '*--hard-timeout-sec*') 'the non-numeric-value error names the flag'

Write-Host "shell-level: run --hard-timeout-sec -1 / non-numeric is a usage error (exit 2), never reaches codex"
# Dispatcher-level check: the flag-parsing/validation lives in ccodex.ps1's own `switch
# ($Command)` block (before Invoke-CcodexRun is ever called), so it can only be exercised
# through a real process invocation, not through Invoke-CcodexRun directly (that function
# already takes a typed [int]$HardTimeoutSec, hence the direct ConvertTo-CcodexHardTimeoutSec
# unit test above for the parsing rule itself). LOCALAPPDATA/APPDATA are still pointed at the
# temp roots (never the real profile) purely as a defensive measure in case validation
# regresses and control falls through to job creation; stdin is piped so a regression can
# never block waiting for interactive input either.
$savedLocalAppDataForHardTimeout = $env:LOCALAPPDATA
$savedAppDataForHardTimeout = $env:APPDATA
try {
    $env:LOCALAPPDATA = $localAppData
    $env:APPDATA = $appData

    $negativeOut = "unused task text" | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath run --mode review --repo $repoRoot --hard-timeout-sec -1
    Assert-Equal $LASTEXITCODE 2 '--hard-timeout-sec -1 exits 2'
    Assert-True ((($negativeOut -join "`n")) -like '*--hard-timeout-sec*') 'usage error names the --hard-timeout-sec flag (negative value)'

    $nonNumericOut = "unused task text" | & pwsh -NoLogo -NoProfile -File $ccodexScriptPath run --mode review --repo $repoRoot --hard-timeout-sec abc
    Assert-Equal $LASTEXITCODE 2 '--hard-timeout-sec abc exits 2'
    Assert-True ((($nonNumericOut -join "`n")) -like '*--hard-timeout-sec*') 'usage error names the --hard-timeout-sec flag (non-numeric value)'
} finally {
    $env:LOCALAPPDATA = $savedLocalAppDataForHardTimeout
    $env:APPDATA = $savedAppDataForHardTimeout
}

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
