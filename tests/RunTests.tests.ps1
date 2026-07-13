# Tests for tests/run-tests.ps1 — the quick/full suite runner.
# The runner is dev tooling, but it gates every commit, so it is tested like install.ps1:
# against a temp directory of planted fake test files, never against the real tests/ tree.

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$runnerPath = Join-Path $PSScriptRoot 'run-tests.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ccodex-runtests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Write-Host "run-tests.ps1 exists next to the test files"
    Assert-True (Test-Path -LiteralPath $runnerPath -PathType Leaf) 'tests/run-tests.ps1 exists'

    Set-Content -LiteralPath (Join-Path $tempRoot 'Alpha.tests.ps1') -Value 'exit 0' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $tempRoot 'Beta.tests.ps1') -Value 'Write-Host "beta failing"; exit 1' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $tempRoot 'SlowGamma.tests.ps1') -Value 'exit 0' -Encoding utf8

    Write-Host "full suite runs every discovered file and exits with the failed-file count"
    $fullOut = & pwsh -NoLogo -NoProfile -File $runnerPath -Suite full -TestsPath $tempRoot -SlowFiles @('SlowGamma.tests.ps1') 2>&1
    $fullText = $fullOut -join "`n"
    Assert-Equal $LASTEXITCODE 1 'full suite exit code equals the number of failed files'
    Assert-True ($fullText -like '*Alpha.tests.ps1*') 'full suite ran Alpha'
    Assert-True ($fullText -like '*SlowGamma.tests.ps1*') 'full suite ran the slow-listed file too'
    Assert-True ($fullText -like '*FAIL*Beta.tests.ps1*') 'full suite reports the failing file by name'
    Assert-True ($fullText -like '*beta failing*') 'a failing file has its captured output echoed (flakes must self-document)'
    Assert-True ($fullText -like '*1 test file(s) failed*') 'full suite prints the failure count summary'

    Write-Host "quick suite skips slow-listed files, says so, and still reports failures"
    $quickOut = & pwsh -NoLogo -NoProfile -File $runnerPath -Suite quick -TestsPath $tempRoot -SlowFiles @('SlowGamma.tests.ps1') 2>&1
    $quickText = $quickOut -join "`n"
    Assert-Equal $LASTEXITCODE 1 'quick suite still exits nonzero when a run file fails'
    Assert-True ($quickText -like '*skipped*SlowGamma.tests.ps1*') 'quick suite names the skipped slow file (no silent skips)'
    Assert-True ($quickText -notlike '*PASS SlowGamma.tests.ps1*') 'quick suite did not run the slow file'
    Assert-True ($quickText -like '*FAIL*Beta.tests.ps1*') 'quick suite reports the failing file by name'

    Write-Host "quick suite over passing files exits 0"
    Remove-Item -LiteralPath (Join-Path $tempRoot 'Beta.tests.ps1') -Force
    & pwsh -NoLogo -NoProfile -File $runnerPath -Suite quick -TestsPath $tempRoot -SlowFiles @('SlowGamma.tests.ps1') *> $null
    Assert-Equal $LASTEXITCODE 0 'all-green quick suite exits 0'

    Write-Host "default suite is quick (slow files skipped without an explicit -Suite)"
    & pwsh -NoLogo -NoProfile -File $runnerPath -TestsPath $tempRoot -SlowFiles @('SlowGamma.tests.ps1') *> $null
    Assert-Equal $LASTEXITCODE 0 'runner defaults to the quick suite and exits 0 on green'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-CcodexTests
