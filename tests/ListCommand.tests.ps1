# tests/ListCommand.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobList.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-listcmd-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

$nowIso = (Get-Date).ToUniversalTime().ToString('o')
$oldIso = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o')

function New-TestJob {
    param(
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$JobId,
        [string]$Status = 'done',
        [string]$LastHeartbeatAt = $null
    )
    $jobDir = Join-Path (Get-CcodexJobsDir -RepoKey $RepoKey -Root $localAppData) $JobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    $obj = New-CcodexStatusObject -JobId $JobId -Status $Status -Mode 'review' -Access 'read-only' `
        -Repo $targetRepo -CreatedAt (Get-Date).ToString('o') -LastHeartbeatAt $LastHeartbeatAt
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $obj
    return $jobDir
}

# Jobs live under the SAME repo key `list --repo $targetRepo` will compute, so the repo
# filter matches. (Resolve-CcodexRepo with an override needs no git — it just resolves the
# path — so no `git init` is required here.)
$targetKey = Get-CcodexRepoKey -RepoRoot $targetRepo
New-TestJob -RepoKey $targetKey -JobId '20260101T000001Z-aaaaaaaa-review' -Status 'done' | Out-Null
New-TestJob -RepoKey $targetKey -JobId '20260101T000002Z-bbbbbbbb-review' -Status 'running' -LastHeartbeatAt $oldIso | Out-Null
New-TestJob -RepoKey $targetKey -JobId '20260101T000003Z-cccccccc-review' -Status 'running' -LastHeartbeatAt $nowIso | Out-Null
# A job under a different repo key, to prove --repo filtering.
New-TestJob -RepoKey 'ffffffffffff' -JobId '20260101T000009Z-ffffffff-review' -Status 'done' | Out-Null

Write-Host "Invoke-CcodexListCommand: human output, one line per job, exit 0"
$human = Invoke-CcodexListCommand -StateRoot $localAppData
Assert-Equal $human.WrapperExitCode 0 'exit 0'
$humanLines = @($human.Stdout -split "`n")
Assert-Equal $humanLines.Count 4 'four jobs across all repos, one line each'

Write-Host "Invoke-CcodexListCommand: a running+stale job shows health=stale; running+ok shows no health="
$staleLine = $humanLines | Where-Object { $_ -like '*bbbbbbbb*' } | Select-Object -First 1
Assert-True ($staleLine -like '*health=stale*') 'stale running job flags health=stale'
$okLine = $humanLines | Where-Object { $_ -like '*cccccccc*' } | Select-Object -First 1
Assert-True ($okLine -notlike '*health=*') 'ok running job appends no health='

Write-Host "Invoke-CcodexListCommand: --repo narrows to that repo's jobs"
$scoped = Invoke-CcodexListCommand -RepoOverride $targetRepo -StateRoot $localAppData
$scopedLines = @($scoped.Stdout -split "`n")
Assert-Equal $scopedLines.Count 3 'only the three jobs under the target repo'

Write-Host "Invoke-CcodexListCommand: --state filter"
$onlyDone = Invoke-CcodexListCommand -State @('done') -StateRoot $localAppData
$onlyDoneLines = @($onlyDone.Stdout -split "`n")
Assert-Equal $onlyDoneLines.Count 2 'two done jobs (both repos)'

Write-Host "Invoke-CcodexListCommand: invalid --state is a usage error (exit 2)"
$badState = Invoke-CcodexListCommand -State @('bogus') -StateRoot $localAppData
Assert-Equal $badState.WrapperExitCode 2 'invalid state -> exit 2'
Assert-True ($badState.Message -like '*--state*') 'message names the flag'

Write-Host "Invoke-CcodexListCommand: --json envelope shape"
$json = Invoke-CcodexListCommand -Json -StateRoot $localAppData
Assert-Equal $json.WrapperExitCode 0 'json exit 0'
$parsed = $json.Stdout | ConvertFrom-Json
Assert-Equal $parsed.schema_version 1 'envelope schema_version = 1'
Assert-Equal $parsed.count 4 'envelope count = 4'
Assert-Equal $parsed.jobs.Count 4 'jobs array has 4 entries'
$aJob = $parsed.jobs | Where-Object { $_.job_id -eq '20260101T000001Z-aaaaaaaa-review' } | Select-Object -First 1
Assert-True ([bool]$aJob.job_dir) 'each job carries job_dir'
Assert-Equal $aJob.status 'done' 'each job carries its status'

Write-Host "Invoke-CcodexListCommand: zero jobs -> friendly line, exit 0"
$emptyLocal = Join-Path $tempRoot 'EmptyLocal'
New-Item -ItemType Directory -Path $emptyLocal -Force | Out-Null
$empty = Invoke-CcodexListCommand -StateRoot $emptyLocal
Assert-Equal $empty.WrapperExitCode 0 'empty exit 0'
Assert-Equal $empty.Stdout 'ccodex: no jobs found.' 'friendly empty line'
$emptyJson = Invoke-CcodexListCommand -Json -StateRoot $emptyLocal
$emptyParsed = $emptyJson.Stdout | ConvertFrom-Json
Assert-Equal $emptyParsed.count 0 'empty json count = 0'

Write-Host "ccodex list --json: dispatcher round-trip (shell) wires flags end-to-end"
$shellOut = & pwsh -NoLogo -NoProfile -File $ccodexPs list --json --state-root $localAppData 2>&1
$shellExit = $LASTEXITCODE
Assert-Equal $shellExit 0 'shell list --json exit 0'
$shellParsed = ($shellOut | Out-String) | ConvertFrom-Json
Assert-Equal $shellParsed.count 4 'shell round-trip lists 4 jobs'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
