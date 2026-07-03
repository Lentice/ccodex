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

$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

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

Write-Host "mode 'implement' is rejected"
$result3 = Invoke-CcodexRunForTest -Overrides @{ Mode = 'implement' }
Assert-Equal $result3.WrapperExitCode 2 'exit code 2 for implement mode'

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

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
