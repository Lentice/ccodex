# tests/RealInvocation.tests.ps1
#
# Regression guard for the redirected-stdin defect: every other test dot-sources
# Invoke-CcodexRun directly and passes -PipelineObjects, which bypasses the real
# `pwsh -File ccodex.ps1` argument/stdin-binding path that the ccodex.cmd shim
# actually uses. This test shells out through that real path against the
# fake-codex fixture, so a regression to an advanced ([CmdletBinding()]) script
# or to reading $input (either of which consumes redirected stdin before the
# OS-stream reader runs) would be caught here.
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fakePs = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-realinvoke-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$binDir = Join-Path $tempRoot 'bin'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $binDir, $targetRepo, (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$exitLine = 'exit /' + 'b %ERRORLEVEL%'  # split literal to keep it plain text
# codex.cmd on PATH resolves to the fake-codex fixture.
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), "@echo off`r`npwsh -NoProfile -File `"$fakePs`" %*`r`n$exitLine", $utf8NoBom)
# ccodex.cmd shim mirrors the installed PATH shim exactly.
[System.IO.File]::WriteAllText((Join-Path $binDir 'ccodex.cmd'), "@echo off`r`nsetlocal`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ccodexPs`" %*`r`n$exitLine", $utf8NoBom)

$savedPath = $env:PATH
$savedLocal = $env:LOCALAPPDATA
$savedApp = $env:APPDATA
$savedExit = $env:CCODEX_FAKE_EXIT_CODE
$savedResult = $env:CCODEX_FAKE_RESULT
try {
    $env:PATH = "$binDir;$env:PATH"
    $env:LOCALAPPDATA = $localAppData
    $env:APPDATA = $appData
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'OK'

    Write-Host "piped ASCII task via pwsh -File reaches codex and prints only result"
    $out = "Reply with exactly the word OK." | & pwsh -NoLogo -NoProfile -File $ccodexPs run --mode review --repo $targetRepo
    Assert-Equal $LASTEXITCODE 0 'piped ASCII task exits 0'
    Assert-True ($out -join "`n" -like '*OK*') 'result.md content is printed to stdout'
    Assert-True (-not (($out -join "`n") -like '*fake-codex ran*')) 'raw JSONL events never reach stdout'

    Write-Host "piped Traditional Chinese is written byte-exact to prompt.md (no mojibake)"
    $zh = '請用一句話總結你能做什麼，並且只回覆這一句話。'
    $out2 = $zh | & pwsh -NoLogo -NoProfile -File $ccodexPs run --mode brainstorm --repo $targetRepo
    Assert-Equal $LASTEXITCODE 0 'piped Chinese task exits 0'
    $promptFiles = Get-ChildItem -Recurse -Path (Join-Path $localAppData 'ccodex\jobs') -Filter prompt.md | Sort-Object LastWriteTime
    $promptText = [System.IO.File]::ReadAllText($promptFiles[-1].FullName, $utf8NoBom)
    Assert-True ($promptText.Contains($zh)) 'prompt.md contains the Traditional Chinese text byte-exact'

    Write-Host "redirected empty stdin (< NUL) fails fast with exit 2 via the OS-stream reader"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nulOut = cmd /c "`"$binDir\ccodex.cmd`" run --mode review --repo `"$targetRepo`" 0< NUL"
    $nulExit = $LASTEXITCODE
    $sw.Stop()
    Assert-Equal $nulExit 2 'empty redirected stdin exits 2'
    Assert-True (($nulOut -join "`n") -like '*redirected stdin produced no data*') 'empty stdin hits the OS-stream no-data message'
    Assert-True ($sw.ElapsedMilliseconds -lt 2000) 'empty stdin fails within the 2s first-byte timeout window'

    Write-Host "explicit positional task wins over redirected stdin and does not hang"
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $posOut = cmd /c "`"$binDir\ccodex.cmd`" run --mode review --repo `"$targetRepo`" `"do the review`" 0< NUL"
    $posExit = $LASTEXITCODE
    $sw2.Stop()
    Assert-Equal $posExit 0 'positional task with redirected stdin exits 0'
    Assert-True (($posOut -join "`n") -like '*OK*') 'positional task path still prints the result'
} finally {
    $env:PATH = $savedPath
    $env:LOCALAPPDATA = $savedLocal
    $env:APPDATA = $savedApp
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_RESULT = $savedResult
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

Complete-CcodexTests
