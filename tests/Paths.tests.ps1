. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-paths-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Get-CcodexLocalAppDataRoot / Get-CcodexAppDataRoot"
Assert-Equal (Get-CcodexLocalAppDataRoot -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex' 'joins Root with ccodex'
Assert-Equal (Get-CcodexAppDataRoot -Root 'C:\Fake\Roaming') 'C:\Fake\Roaming\ccodex' 'joins Root with ccodex'

Write-Host "Get-CcodexRepoKey"
$repoA = Join-Path $tempRoot 'repoA'
$repoB = Join-Path $tempRoot 'repoB'
New-Item -ItemType Directory -Path $repoA -Force | Out-Null
New-Item -ItemType Directory -Path $repoB -Force | Out-Null
$keyA1 = Get-CcodexRepoKey -RepoRoot $repoA
$keyA2 = Get-CcodexRepoKey -RepoRoot $repoA
$keyB = Get-CcodexRepoKey -RepoRoot $repoB
Assert-Equal $keyA1 $keyA2 'repo key is deterministic for the same path'
Assert-True ($keyA1 -ne $keyB) 'different repo paths produce different keys'
Assert-True ($keyA1 -match '^[0-9a-f]{12}$') 'repo key is 12 lowercase hex chars'

Write-Host "Get-CcodexJobsDir / Get-CcodexJobDir / Get-CcodexIndexPath"
Assert-Equal (Get-CcodexJobsDir -RepoKey 'abc123' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\jobs\abc123' 'jobs dir under repo key'
Assert-Equal (Get-CcodexJobDir -RepoKey 'abc123' -JobId 'job1' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\jobs\abc123\job1' 'job dir under repo key/job id'
Assert-Equal (Get-CcodexIndexPath -JobId 'job1' -Root 'C:\Fake\Local') 'C:\Fake\Local\ccodex\index\job1.json' 'index path uses job id as filename'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
