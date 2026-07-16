# tests/JobList.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobList.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-joblist-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$repoKeyA = 'aaaaaaaaaaaa'
$repoKeyB = 'bbbbbbbbbbbb'

function New-TestJob {
    param(
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$JobId,
        [string]$Status = 'done',
        [string]$LastHeartbeatAt = $null,
        [string]$StartedAt = $null,
        [switch]$NoStatus
    )
    $jobDir = Join-Path (Get-CcodexJobsDir -RepoKey $RepoKey -Root $tempRoot) $JobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    if (-not $NoStatus) {
        $obj = New-CcodexStatusObject -JobId $JobId -Status $Status -Mode 'review' -Access 'read-only' `
            -Repo 'C:\some\repo' -CreatedAt (Get-Date).ToString('o') -StartedAt $StartedAt -LastHeartbeatAt $LastHeartbeatAt
        Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $obj
    }
    return $jobDir
}

$nowIso = (Get-Date).ToUniversalTime().ToString('o')
$oldIso = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o')

# Seed: 2 jobs under repo A, 1 under repo B, with a spread of statuses/heartbeats.
New-TestJob -RepoKey $repoKeyA -JobId '20260101T000001Z-aaaaaaaa-review' -Status 'done'  | Out-Null
New-TestJob -RepoKey $repoKeyA -JobId '20260101T000002Z-bbbbbbbb-review' -Status 'running' -LastHeartbeatAt $nowIso | Out-Null
New-TestJob -RepoKey $repoKeyB -JobId '20260101T000003Z-cccccccc-review' -Status 'failed' | Out-Null

Write-Host "Get-CcodexJobList: global enumeration returns every job across repo keys"
$all = Get-CcodexJobList -Root $tempRoot
Assert-Equal $all.Count 3 'three jobs total across both repo keys'

Write-Host "Get-CcodexJobList: newest-first by job_id descending"
Assert-Equal $all[0].job_id '20260101T000003Z-cccccccc-review' 'largest job_id first'
Assert-Equal $all[2].job_id '20260101T000001Z-aaaaaaaa-review' 'smallest job_id last'

Write-Host "Get-CcodexJobList: RepoKey filter narrows to one repo subtree"
$onlyA = Get-CcodexJobList -Root $tempRoot -RepoKey $repoKeyA
Assert-Equal $onlyA.Count 2 'repo A has two jobs'

Write-Host "Get-CcodexJobList: single --state filter"
$running = Get-CcodexJobList -Root $tempRoot -State @('running')
Assert-Equal $running.Count 1 'one running job'
Assert-Equal $running[0].status 'running' 'the running job'

Write-Host "Get-CcodexJobList: multiple --state filter"
$twoStates = Get-CcodexJobList -Root $tempRoot -State @('done', 'failed')
Assert-Equal $twoStates.Count 2 'done + failed'

Write-Host "Get-CcodexJobList: normal entry carries status fields + job_dir + health"
$doneJob = $all | Where-Object { $_.status -eq 'done' } | Select-Object -First 1
Assert-Equal $doneJob.mode 'review' 'entry carries mode from status.json'
Assert-Equal $doneJob.access 'read-only' 'entry carries access from status.json'
Assert-True ([bool]$doneJob.job_dir) 'entry carries job_dir'
Assert-True ($null -eq $doneJob.health) 'health is null for a non-running job'

Write-Host "Get-CcodexJobList: running job health derives from heartbeat (ok vs stale)"
$okRunning = $all | Where-Object { $_.job_id -eq '20260101T000002Z-bbbbbbbb-review' } | Select-Object -First 1
Assert-Equal $okRunning.health 'ok' 'recent heartbeat -> ok'
New-TestJob -RepoKey $repoKeyB -JobId '20260101T000004Z-dddddddd-review' -Status 'running' -LastHeartbeatAt $oldIso | Out-Null
$staleRunning = (Get-CcodexJobList -Root $tempRoot) | Where-Object { $_.job_id -eq '20260101T000004Z-dddddddd-review' } | Select-Object -First 1
Assert-Equal $staleRunning.health 'stale' 'old heartbeat -> stale'

Write-Host "Get-CcodexJobList: unreadable status.json yields an unknown entry, does not abort"
New-TestJob -RepoKey $repoKeyA -JobId '20260101T000000Z-eeeeeeee-review' -NoStatus | Out-Null
$withUnknown = Get-CcodexJobList -Root $tempRoot
$unknown = $withUnknown | Where-Object { $_.job_id -eq '20260101T000000Z-eeeeeeee-review' } | Select-Object -First 1
Assert-Equal $unknown.status 'unknown' 'missing status.json -> unknown'
Assert-True ([bool]$unknown.error) 'unknown entry carries an error string'

Write-Host "Get-CcodexJobList: structurally-invalid (valid-JSON, non-object) status.json -> unknown"
$badJobDir = New-TestJob -RepoKey $repoKeyB -JobId '20260101T000005Z-ffffffff-review' -NoStatus
Set-Content -LiteralPath (Join-Path $badJobDir 'status.json') -Value '[]' -NoNewline
$withBad = Get-CcodexJobList -Root $tempRoot
$bad = $withBad | Where-Object { $_.job_id -eq '20260101T000005Z-ffffffff-review' } | Select-Object -First 1
Assert-Equal $bad.status 'unknown' 'valid-JSON-but-not-an-object -> unknown'
Assert-True ([bool]$bad.error) 'malformed entry carries an error string'

Write-Host "Get-CcodexJobList: empty state root returns an empty array"
$emptyRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-joblist-empty-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
$none = Get-CcodexJobList -Root $emptyRoot
Assert-Equal $none.Count 0 'no jobs dir -> empty array'
Remove-Item -LiteralPath $emptyRoot -Recurse -Force

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
