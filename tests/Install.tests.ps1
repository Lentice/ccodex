# tests/Install.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$installScript = Join-Path $repoRoot 'install.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ccodex-install-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $installDir = Join-Path $tempRoot 'install'
    $templatesDir = Join-Path $tempRoot 'templates'
    $claudeDir = Join-Path $tempRoot 'claude'

    function Invoke-Install {
        & $installScript -InstallDir $installDir -TemplatesDir $templatesDir -ClaudeDir $claudeDir
    }

    # Run twice to prove idempotence.
    Invoke-Install | Out-Null
    Invoke-Install | Out-Null

    $ruleDest = Join-Path $claudeDir 'rules\ccodex-delegation.md'
    $ruleSource = Join-Path $repoRoot 'templates\claude-rule-ccodex-delegation.md'
    Assert-True (Test-Path -LiteralPath $ruleDest -PathType Leaf) "delegation rule copied to $ruleDest"
    if (Test-Path -LiteralPath $ruleDest -PathType Leaf) {
        $ruleBytesMatch = [System.IO.File]::ReadAllBytes($ruleDest) -join ',' -eq ([System.IO.File]::ReadAllBytes($ruleSource) -join ',')
        Assert-True $ruleBytesMatch "delegation rule byte-matches template"
    }

    $commandDest = Join-Path $claudeDir 'commands\ccodex.md'
    $commandSource = Join-Path $repoRoot 'templates\claude-command-ccodex.md'
    Assert-True (Test-Path -LiteralPath $commandDest -PathType Leaf) "claude command copied to $commandDest"
    if (Test-Path -LiteralPath $commandDest -PathType Leaf) {
        $commandBytesMatch = [System.IO.File]::ReadAllBytes($commandDest) -join ',' -eq ([System.IO.File]::ReadAllBytes($commandSource) -join ',')
        Assert-True $commandBytesMatch "claude command byte-matches template"
    }

    $skillDest = Join-Path $claudeDir 'skills\ccodex\SKILL.md'
    $skillSource = Join-Path $repoRoot 'templates\claude-skill-ccodex.md'
    Assert-True (Test-Path -LiteralPath $skillSource -PathType Leaf) "skill template exists at $skillSource"
    Assert-True (Test-Path -LiteralPath $skillDest -PathType Leaf) "claude skill copied to $skillDest"
    if ((Test-Path -LiteralPath $skillDest -PathType Leaf) -and (Test-Path -LiteralPath $skillSource -PathType Leaf)) {
        $skillBytesMatch = [System.IO.File]::ReadAllBytes($skillDest) -join ',' -eq ([System.IO.File]::ReadAllBytes($skillSource) -join ',')
        Assert-True $skillBytesMatch "claude skill byte-matches template"
        $skillHead = [System.IO.File]::ReadAllLines($skillDest)[0]
        Assert-Equal '---' $skillHead "SKILL.md starts with YAML frontmatter"
    }

    $workerPromptDest = Join-Path $templatesDir 'worker-prompt.md'
    $workerPromptSource = Join-Path $repoRoot 'templates\worker-prompt.md'
    Assert-True (Test-Path -LiteralPath $workerPromptDest -PathType Leaf) "worker prompt template copied to $workerPromptDest"
    if (Test-Path -LiteralPath $workerPromptDest -PathType Leaf) {
        $workerPromptBytesMatch = [System.IO.File]::ReadAllBytes($workerPromptDest) -join ',' -eq ([System.IO.File]::ReadAllBytes($workerPromptSource) -join ',')
        Assert-True $workerPromptBytesMatch "worker prompt byte-matches template"
    }

    $scriptDest = Join-Path $installDir 'ccodex\ccodex.ps1'
    Assert-True (Test-Path -LiteralPath $scriptDest -PathType Leaf) "ccodex.ps1 copied to $scriptDest"

    $shimDest = Join-Path $installDir 'ccodex.cmd'
    Assert-True (Test-Path -LiteralPath $shimDest -PathType Leaf) "shim copied to $shimDest"

    # Never touch the real user profile.
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude\rules\ccodex-delegation.md-ccodex-install-test-marker'))) "sanity: no stray marker in real profile"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-CcodexTests
