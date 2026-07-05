# tests/ReviewCommand.tests.ps1
#
# Task 2 (P2c): the `ccodex review` subcommand. Two layers:
#   (1) unit tests of Build-CcodexReviewPrompt (prompt composition + validation),
#   (2) a shim-level E2E against the fake-codex fixture with npm-shaped PATH staging
#       (mirrors RealInvocation.tests.ps1) proving `ccodex review` routes through the
#       existing run pipeline: exit 0, only the fixture result printed, and the job's
#       prompt.md carries the git-diff instruction with the exact scoped paths; an
#       invalid flag combo exits 2.
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ReviewPrompt.ps1')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Unit tests: self-diff (default) form -----------------------------------

Write-Host "self-diff form contains the exact scoped git diff command line"
$selfDiff = Build-CcodexReviewPrompt -Range 'abc..def' -Staged $false -Working $false -Paths @('lib/', 'src/x/') -Intent 'add scoping' -Focus 'null handling' -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True ($selfDiff -like '*git diff abc..def -- lib/ src/x/*') 'self-diff form embeds the exact `git diff abc..def -- lib/ src/x/` line'
Assert-True ($selfDiff -like '*add scoping*') 'intent is included when provided'
Assert-True ($selfDiff -like '*null handling*') 'focus is included when provided'
Assert-True ($selfDiff -like '*Critical*' -and $selfDiff -like '*Important*' -and $selfDiff -like '*Minor*') 'severity ordering (Critical/Important/Minor) is instructed'
Assert-True ($selfDiff -like '*file:line*') 'findings are instructed to carry file:line'
Assert-True ($selfDiff -like '*verdict*') 'a one-line verdict is instructed'
Assert-True ($selfDiff -like '*omission*' -or $selfDiff -like '*edge case*') 'hunting for omissions/edge cases is instructed'

Write-Host "intent/focus omitted when not provided"
$noMeta = Build-CcodexReviewPrompt -Range 'abc..def' -Staged $false -Working $false -Paths @() -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True (-not ($noMeta -like '*Change intent:*')) 'no Change intent line when intent is absent'
Assert-True (-not ($noMeta -like '*Additional focus:*')) 'no Additional focus line when focus is absent'
Assert-True ($noMeta -like '*git diff abc..def*') 'range form without paths omits the -- path suffix'

Write-Host "staged form uses git diff --staged"
$staged = Build-CcodexReviewPrompt -Range $null -Staged $true -Working $false -Paths @('lib/') -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True ($staged -like '*git diff --staged -- lib/*') 'staged form embeds `git diff --staged -- lib/`'

Write-Host "working form uses git diff (no range/--staged)"
$working = Build-CcodexReviewPrompt -Range $null -Staged $false -Working $true -Paths @('lib/') -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True ($working -like '*git diff -- lib/*') 'working form embeds `git diff -- lib/`'
Assert-True (-not ($working -like '*--staged*')) 'working form never mentions --staged'

# --- Unit tests: whitespace-bearing paths are quoted in the rendered command -------

Write-Host "self-diff form quotes a path containing whitespace"
$spacePath = Build-CcodexReviewPrompt -Range 'abc..def' -Staged $false -Working $false -Paths @('lib/My File.ps1') -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True ($spacePath -like '*git diff abc..def -- "lib/My File.ps1"*') 'path with whitespace is wrapped in double quotes in the rendered command'

Write-Host "self-diff form quotes only the paths that contain whitespace, leaving normal paths bare"
$mixedPaths = Build-CcodexReviewPrompt -Range 'abc..def' -Staged $false -Working $false -Paths @('lib/', 'lib/My File.ps1') -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo'
Assert-True ($mixedPaths -like '*git diff abc..def -- lib/ "lib/My File.ps1"*') 'normal paths stay unquoted while the whitespace-bearing path is quoted'

Write-Host "embed form quotes a whitespace-bearing path in the 'produced by' line too"
$embedSpace = Build-CcodexReviewPrompt -Range $null -Staged $false -Working $true -Paths @('lib/My File.ps1') -Intent $null -Focus $null -EmbedDiff $true -RepoRoot 'C:\repo'
Assert-True ($embedSpace -like '*produced by: git diff -- "lib/My File.ps1"*') 'embed form quotes the whitespace-bearing path in the produced-by line'

# --- Unit tests: validation --------------------------------------------------

Write-Host "validation: exactly one of range/staged/working"
Assert-Throws { Build-CcodexReviewPrompt -Range $null -Staged $false -Working $false -Paths @() -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo' } 'zero selectors throws a usage error'
Assert-True ($script:CcodexLastError -like '*--range*' -and $script:CcodexLastError -like '*--staged*' -and $script:CcodexLastError -like '*--working*') 'zero-selector error names all three options'
Assert-Throws { Build-CcodexReviewPrompt -Range 'abc..def' -Staged $true -Working $false -Paths @() -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo' } 'two selectors throws a usage error'

Write-Host "validation: range must be <a>..<b> shape"
Assert-Throws { Build-CcodexReviewPrompt -Range 'abcdef' -Staged $false -Working $false -Paths @() -Intent $null -Focus $null -EmbedDiff $false -RepoRoot 'C:\repo' } 'range without .. throws'

# --- Unit test: embed-diff form (real temp git repo with a small diff) -------

Write-Host "embed-diff form contains the stat block, the cap note, and the actual diff"
$gitRepo = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-review-embed-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
try {
    Push-Location $gitRepo
    & git init -q 2>$null | Out-Null
    & git config user.email 'test@example.com' | Out-Null
    & git config user.name 'ccodex test' | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $gitRepo 'sample.txt'), "line1`n", $utf8NoBom)
    & git add sample.txt | Out-Null
    & git commit -q -m 'init' | Out-Null
    # Uncommitted working-tree change -> `git diff` (working form) shows it.
    [System.IO.File]::WriteAllText((Join-Path $gitRepo 'sample.txt'), "line1`nline2-added`n", $utf8NoBom)
    Pop-Location

    $embed = Build-CcodexReviewPrompt -Range $null -Staged $false -Working $true -Paths @('sample.txt') -Intent 'embed check' -Focus $null -EmbedDiff $true -RepoRoot $gitRepo
    Assert-True ($embed -like '*git diff --stat*') 'embed form includes a git diff --stat block'
    Assert-True ($embed -like '*sample.txt*') 'embed stat/diff references the changed file'
    Assert-True ($embed -like '*line2-added*') 'embed form contains the actual added diff content'
    Assert-True ($embed -like '*capped at 100 KB total*') 'embed form carries the whole-diff 100 KB cap note'
    Assert-True (-not ($embed -like '*per-file*')) 'cap note does not claim per-file truncation (the implementation caps the whole diff, not per file)'
} finally {
    Set-Location ([System.IO.Path]::GetTempPath())
    Remove-Item -Recurse -Force -LiteralPath $gitRepo -ErrorAction SilentlyContinue
}

# --- Shim-level E2E (npm-shaped PATH staging, mirrors RealInvocation) ---------

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fakePs = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-review-e2e-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$binDir = Join-Path $tempRoot 'bin'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $binDir, $targetRepo, (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$exitLine = 'exit /' + 'b %ERRORLEVEL%'  # split literal to keep it plain text
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), "@echo off`r`npwsh -NoProfile -File `"$fakePs`" %*`r`n$exitLine", $utf8NoBom)
# npm-shaped decoy: codex.ps1 outranks codex.cmd in command precedence but cannot be
# launched by Process.Start; ccodex must resolve the .cmd (same guard as RealInvocation).
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.ps1'), "param() Write-Error 'ccodex resolved codex.ps1 instead of codex.cmd'; exit 3`r`n", $utf8NoBom)

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
    $env:CCODEX_FAKE_RESULT = 'REVIEW: no blocking issues. Verdict: ship it.'

    Write-Host "ccodex review --range --path --intent routes through the run pipeline: exit 0, only result printed"
    $out = & pwsh -NoLogo -NoProfile -File $ccodexPs review --range abc..def --path lib/ --intent 'check scoping' --repo $targetRepo
    Assert-Equal $LASTEXITCODE 0 'review exits 0 against the fake-codex fixture'
    $outText = $out -join "`n"
    Assert-True ($outText -like '*Verdict: ship it.*') 'review prints the fixture result content to stdout'
    Assert-True (-not ($outText -like '*fake-codex ran*')) 'raw JSONL events never reach stdout'
    Assert-True (-not ($outText -like '*codex.ps1 instead*')) 'ccodex never resolved the shadowing codex.ps1'

    Write-Host "the job's prompt.md carries the scoped git-diff instruction with the exact paths"
    $promptFiles = Get-ChildItem -Recurse -Path (Join-Path $localAppData 'ccodex\jobs') -Filter prompt.md | Sort-Object LastWriteTime
    $promptText = [System.IO.File]::ReadAllText($promptFiles[-1].FullName, $utf8NoBom)
    Assert-True ($promptText -like '*git diff abc..def -- lib/*') 'prompt.md contains the scoped git diff instruction'
    Assert-True ($promptText -like '*check scoping*') 'prompt.md carries the change intent'

    Write-Host "invalid flag combo (no range/staged/working) exits 2 without invoking codex"
    $badOut = & pwsh -NoLogo -NoProfile -File $ccodexPs review --repo $targetRepo
    Assert-Equal $LASTEXITCODE 2 'missing selector exits 2'
    Assert-True (($badOut -join "`n") -like '*--range*') 'usage error names the --range option'
} finally {
    $env:PATH = $savedPath
    $env:LOCALAPPDATA = $savedLocal
    $env:APPDATA = $savedApp
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_RESULT = $savedResult
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

Complete-CcodexTests
