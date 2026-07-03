# tests/JobStore.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobstore-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Write-CcodexTextFile writes UTF-8 without BOM"
$textPath = Join-Path $tempRoot 'prompt.md'
Write-CcodexTextFile -Path $textPath -Content '請審查'
$bytes = [System.IO.File]::ReadAllBytes($textPath)
Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'no UTF-8 BOM is written'
Assert-Equal ([System.Text.Encoding]::UTF8.GetString($bytes)) '請審查' 'content round-trips exactly'

Write-Host "Write-CcodexJsonFile / Write-CcodexJsonFileAtomic"
$jsonPath = Join-Path $tempRoot 'status.json'
Write-CcodexJsonFileAtomic -Path $jsonPath -Object ([ordered]@{ a = 1; b = 'x' })
$roundTrip = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Assert-Equal $roundTrip.a 1 'atomic JSON write round-trips field a'
Assert-Equal $roundTrip.b 'x' 'atomic JSON write round-trips field b'
$leftoverTemp = Get-ChildItem -LiteralPath $tempRoot -Filter 'status.json.tmp-*'
Assert-Equal $leftoverTemp.Count 0 'no leftover .tmp file after atomic write'

Write-Host "ConvertTo-CcodexCommandLineText"
$cmdText = ConvertTo-CcodexCommandLineText -Executable 'C:\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', 'a b')
Assert-Equal $cmdText 'C:\codex.cmd exec --sandbox read-only "a b"' 'quotes only arguments containing whitespace'

Write-Host "New-CcodexStatusObject"
$status = New-CcodexStatusObject -JobId 'job1' -Status 'running' -Mode 'review' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-03T00:00:00Z'
Assert-Equal $status.job_id 'job1' 'status object carries job_id'
Assert-Equal $status.status 'running' 'status object carries status'
Assert-Equal $status.codex_exit_code $null 'codex_exit_code defaults to null'

Write-Host "New-CcodexDebugObject"
$debugObj = New-CcodexDebugObject -JobId 'job1' -Repo 'D:\Repo' -JobDir 'D:\Job' -Mode 'review' -Access 'read-only' -CodexPath 'C:\codex.cmd' -CodexArgs @('exec')
Assert-Equal $debugObj.backend 'sync' 'debug object records sync backend'
Assert-Equal $debugObj.codex_path 'C:\codex.cmd' 'debug object records resolved codex path'

Write-Host "New-CcodexWorkerCompleteObject"
$complete = New-CcodexWorkerCompleteObject -JobId 'job1' -StatusCandidate 'done' -CodexExitCode 0 -WrapperExitCode 0 -ResultPresent $true -CompletedAt '2026-07-03T00:01:00Z'
Assert-Equal $complete.status_candidate 'done' 'worker-complete records the status candidate'
Assert-Equal $complete.result_present $true 'worker-complete records result presence'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
