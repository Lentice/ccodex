# tests/JobIndex.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobindex-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Get-CcodexJobRecord round-trips an index entry"
$jobId = 'job-abc123'
$repoKey = 'deadbeefcafe'
$jobDir = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $tempRoot) $jobId
New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
$indexPath = Get-CcodexIndexPath -JobId $jobId -Root $tempRoot
New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })

$record = Get-CcodexJobRecord -JobId $jobId -Root $tempRoot
Assert-Equal $record.JobId $jobId 'record carries job_id'
Assert-Equal $record.RepoKey $repoKey 'record carries repo_key'
Assert-Equal $record.JobDir $jobDir 'record carries job_dir'

Write-Host "Get-CcodexJobRecord throws when index file is missing"
Assert-Throws { Get-CcodexJobRecord -JobId 'no-such-job' -Root $tempRoot } 'missing index entry throws'

Write-Host "Get-CcodexJobRecord throws when job dir is missing"
$jobId2 = 'job-def456'
$jobDir2 = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $tempRoot) $jobId2
$indexPath2 = Get-CcodexIndexPath -JobId $jobId2 -Root $tempRoot
Write-CcodexJsonFileAtomic -Path $indexPath2 -Object ([ordered]@{ job_id = $jobId2; repo_key = $repoKey; job_dir = $jobDir2 })
Assert-Throws { Get-CcodexJobRecord -JobId $jobId2 -Root $tempRoot } 'missing job dir throws'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
