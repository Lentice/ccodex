# tests/ResultValidation.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-resultvalidation-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Host "codex exit 0 with a non-empty result -> done/0"
$resultPath = Join-Path $tempRoot 'result-ok.md'
[System.IO.File]::WriteAllText($resultPath, 'the answer', $utf8NoBom)
$v = Test-CcodexResult -CodexExitCode 0 -ResultPath $resultPath
Assert-Equal $v.Status 'done' 'status is done'
Assert-Equal $v.WrapperExitCode 0 'wrapper exit code is 0'
Assert-Equal $v.ResultPresent $true 'result present is true'
Assert-Equal $v.ResultContent 'the answer' 'result content is returned'

Write-Host "codex exit 0 with a missing result -> failed/11"
$missingPath = Join-Path $tempRoot 'does-not-exist.md'
$v2 = Test-CcodexResult -CodexExitCode 0 -ResultPath $missingPath
Assert-Equal $v2.Status 'failed' 'status is failed'
Assert-Equal $v2.WrapperExitCode 11 'wrapper exit code is 11'
Assert-Equal $v2.ResultPresent $false 'result present is false'

Write-Host "codex exit 0 with an empty (whitespace-only) result -> failed/11"
$emptyPath = Join-Path $tempRoot 'result-empty.md'
[System.IO.File]::WriteAllText($emptyPath, "   `n", $utf8NoBom)
$v3 = Test-CcodexResult -CodexExitCode 0 -ResultPath $emptyPath
Assert-Equal $v3.Status 'failed' 'whitespace-only result counts as empty'
Assert-Equal $v3.WrapperExitCode 11 'wrapper exit code is 11 for an empty result'

Write-Host "nonzero codex exit code -> failed/10 regardless of result presence"
$v4 = Test-CcodexResult -CodexExitCode 5 -ResultPath $resultPath
Assert-Equal $v4.Status 'failed' 'status is failed on nonzero codex exit'
Assert-Equal $v4.WrapperExitCode 10 'wrapper exit code is 10'
Assert-Equal $v4.ResultPresent $true 'result presence is still reported accurately'

$v5 = Test-CcodexResult -CodexExitCode 5 -ResultPath $missingPath
Assert-Equal $v5.WrapperExitCode 10 'nonzero exit code takes precedence over a missing result (still 10, not 11)'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
