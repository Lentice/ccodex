# tests/Worker.tests.ps1
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
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-worker-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

function New-CcodexTestJob {
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$PromptContent = 'test worker prompt body'
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $PromptContent
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status 'created' -Mode $Mode -Access $Access -Repo $targetRepo -CreatedAt $createdAt)
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

# --- (a) successful in-process worker run ---

Write-Host "Invoke-CcodexWorker: success path stamps native backend and reaches done"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'WORKER RESULT OK'
$jobA = New-CcodexTestJob
$resultA = Invoke-CcodexWorker -JobId $jobA.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultA.WrapperExitCode 0 'wrapper exit code is 0 on success'

$statusA = Get-Content -LiteralPath (Join-Path $jobA.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusA.status 'done' 'final status is done'
Assert-Equal $statusA.backend 'native' 'backend is stamped native'
Assert-True (-not [string]::IsNullOrEmpty($statusA.backend_id)) 'backend_id is set'
Assert-True (Test-CcodexWorkerAlive -BackendId $statusA.backend_id) 'backend_id matches the current (still-running) process'
Assert-True (-not [string]::IsNullOrEmpty($statusA.started_at)) 'started_at is set'
Assert-True (-not [string]::IsNullOrEmpty($statusA.finished_at)) 'finished_at is set'

$resultMdA = Get-Content -LiteralPath (Join-Path $jobA.JobDir 'result.md') -Raw
Assert-True ($resultMdA -like '*WORKER RESULT OK*') 'result.md carries the fixture result content'

# --- (b) fake codex exit 3 -> wrapper 10, terminal failed ---

Write-Host "Invoke-CcodexWorker: nonzero codex exit -> wrapper 10, status failed"
$env:CCODEX_FAKE_EXIT_CODE = '3'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$jobB = New-CcodexTestJob
$resultB = Invoke-CcodexWorker -JobId $jobB.JobId -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultB.WrapperExitCode 10 'wrapper exit code is 10 when codex exits nonzero'
$statusB = Get-Content -LiteralPath (Join-Path $jobB.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusB.status 'failed' 'final status is failed'
Assert-Equal $statusB.backend 'native' 'backend is stamped native on the failure path too'

# --- (c) unknown job id -> wrapper 3 ---

Write-Host "Invoke-CcodexWorker: unknown job id -> wrapper 3"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$resultC = Invoke-CcodexWorker -JobId 'does-not-exist-12345' -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $resultC.WrapperExitCode 3 'wrapper exit code is 3 for an unknown job id'

# --- (d) shell-level: pwsh -File ccodex.ps1 worker --job-id ... ---

Write-Host "shell-level: ccodex.ps1 worker --job-id <id> --state-root <root> --codex-path <fixture>"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHELL WORKER OK'
$jobD = New-CcodexTestJob
& pwsh -NoLogo -NoProfile -File $ccodexPs worker --job-id $jobD.JobId --state-root $localAppData --codex-path $fixtureCmd
Assert-Equal $LASTEXITCODE 0 'shell-level worker invocation exits 0'
$statusD = Get-Content -LiteralPath (Join-Path $jobD.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusD.status 'done' 'shell-level worker reaches terminal done status'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
