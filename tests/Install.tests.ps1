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

    # Run twice to prove idempotence. Between the runs, plant files an older version could
    # have left behind: the second run is an upgrade and must mirror the source exactly,
    # never merge over a previous install.
    Invoke-Install | Out-Null
    $staleLibModule = Join-Path $installDir 'ccodex\lib\RemovedInANewerVersion.ps1'
    Set-Content -LiteralPath $staleLibModule -Value '# stale lib module from an older install'
    $staleTopLevel = Join-Path $installDir 'ccodex\stale-helper.ps1'
    Set-Content -LiteralPath $staleTopLevel -Value '# stale top-level file from an older install'
    $staleNamespacedCommand = Join-Path $claudeDir 'commands\ccodex\removed-command.md'
    Set-Content -LiteralPath $staleNamespacedCommand -Value '# ghost /ccodex:removed-command'
    Invoke-Install | Out-Null

    Assert-True (-not (Test-Path -LiteralPath $staleLibModule)) "upgrade removes a lib module the newer version no longer ships"
    Assert-True (-not (Test-Path -LiteralPath $staleTopLevel)) "upgrade removes a stale top-level file in the install dir"
    Assert-True (-not (Test-Path -LiteralPath $staleNamespacedCommand)) "upgrade removes a ghost /ccodex:<name> command"

    $namespacedDir = Join-Path $claudeDir 'commands\ccodex'
    $sourceCommandNames = (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'templates\claude-commands') -Filter *.md | Sort-Object Name).Name -join ','
    $installedCommandNames = (Get-ChildItem -LiteralPath $namespacedDir -Filter *.md | Sort-Object Name).Name -join ','
    Assert-Equal $installedCommandNames $sourceCommandNames "installed /ccodex:<name> commands mirror templates/claude-commands exactly"

    $sourceLibNames = (Get-ChildItem -LiteralPath (Join-Path $repoRoot 'lib') -Filter *.ps1 | Sort-Object Name).Name -join ','
    $installedLibNames = (Get-ChildItem -LiteralPath (Join-Path $installDir 'ccodex\lib') -Filter *.ps1 | Sort-Object Name).Name -join ','
    Assert-Equal $installedLibNames $sourceLibNames "installed lib/ mirrors the repo lib/ exactly"

    # The staged-swap upgrade must not leave its staging directory behind.
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installDir 'ccodex.staging'))) "no staging directory left after install"

    # Refusal guards: the mirror delete must never run against a directory that is not a
    # previous ccodex install.
    $foreignInstallDir = Join-Path $tempRoot 'foreign'
    $foreignDataFile = Join-Path $foreignInstallDir 'ccodex\user-data.txt'
    New-Item -ItemType Directory -Path (Join-Path $foreignInstallDir 'ccodex') -Force | Out-Null
    Set-Content -LiteralPath $foreignDataFile -Value 'precious user data'
    Assert-Throws { & $installScript -InstallDir $foreignInstallDir -TemplatesDir $templatesDir -ClaudeDir $claudeDir } "install refuses an existing ccodex dir that is not a previous install (no ccodex.ps1 marker)"
    Assert-True (Test-Path -LiteralPath $foreignDataFile) "refusal leaves the foreign directory's content untouched"

    # State-root collision: -InstallDir pointed at %LOCALAPPDATA% would make the script dir the
    # job-state root (%LOCALAPPDATA%\ccodex); the installer must refuse, never delete job state.
    $fakeLocalAppData = Join-Path $tempRoot 'localappdata'
    $fakeJobsMarker = Join-Path $fakeLocalAppData 'ccodex\jobs\somekey\job-1\status.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fakeJobsMarker) -Force | Out-Null
    Set-Content -LiteralPath $fakeJobsMarker -Value '{}'
    $savedLocalAppData = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $fakeLocalAppData
        Assert-Throws { & $installScript -InstallDir $fakeLocalAppData -TemplatesDir $templatesDir -ClaudeDir $claudeDir } "install refuses -InstallDir colliding with the job-state root"
    } finally {
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    Assert-True (Test-Path -LiteralPath $fakeJobsMarker) "state-root refusal leaves job state untouched"

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
