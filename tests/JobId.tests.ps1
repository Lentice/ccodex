# tests/JobId.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobId.ps1')

Write-Host "New-CcodexRandomSuffix"
$suffix = New-CcodexRandomSuffix -Length 8
Assert-True ($suffix -match '^[a-z0-9]{8}$') 'suffix is 8 lowercase alphanumeric chars'
Assert-True ((New-CcodexRandomSuffix -Length 8) -ne (New-CcodexRandomSuffix -Length 8)) 'two calls produce different suffixes (probabilistic)'

Write-Host "New-CcodexJobId"
$jobId = New-CcodexJobId -Mode 'review'
Assert-True ($jobId -match '^\d{8}T\d{6}Z-[a-z0-9]{8}-review$') 'job id matches YYYYMMDDTHHMMSSZ-suffix-mode'

Write-Host "Reserve-CcodexJobDir"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobid-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$reservation = Reserve-CcodexJobDir -RepoKey 'deadbeef0000' -Mode 'test' -Root $tempRoot
Assert-True (Test-Path -LiteralPath $reservation.JobDir -PathType Container) 'reservation creates the job directory'
Assert-Equal $reservation.JobDir (Get-CcodexJobDir -RepoKey 'deadbeef0000' -JobId $reservation.JobId -Root $tempRoot) 'JobDir matches Get-CcodexJobDir for the returned JobId'

$reservation2 = Reserve-CcodexJobDir -RepoKey 'deadbeef0000' -Mode 'test' -Root $tempRoot
Assert-True ($reservation2.JobId -ne $reservation.JobId) 'a second reservation gets a distinct job id'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
