# install.ps1
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\bin'),
    [string]$TemplatesDir = (Join-Path $env:APPDATA 'ccodex\templates'),
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$destScriptDir = Join-Path $InstallDir 'ccodex'

# The script dir is mirrored (replaced, never merged) on upgrade, so refuse destinations the
# mirror delete must never touch: the job-state root (%LOCALAPPDATA%\ccodex — deleting it would
# destroy jobs, indexes, and worktrees), and any existing non-empty directory that doesn't look
# like a previous install (no ccodex.ps1 marker).
if ($env:LOCALAPPDATA) {
    $stateRoot = Join-Path $env:LOCALAPPDATA 'ccodex'
    if ([System.IO.Path]::GetFullPath($destScriptDir).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($stateRoot).TrimEnd('\')) {
        throw "install.ps1: refusing to install into '$destScriptDir' - it is the ccodex job-state root. Choose a different -InstallDir."
    }
}
if ((Test-Path -LiteralPath $destScriptDir) -and
    -not (Test-Path -LiteralPath (Join-Path $destScriptDir 'ccodex.ps1')) -and
    @(Get-ChildItem -LiteralPath $destScriptDir -Force).Count -gt 0) {
    throw "install.ps1: refusing to replace '$destScriptDir' - it exists but does not look like a previous ccodex install (no ccodex.ps1). Move its contents or choose a different -InstallDir."
}

# Stage the new copy next to the destination, then swap. The old install is removed only once
# the complete new tree exists, so a failed copy never leaves a half-installed CLI; the mirror
# swap guarantees a lib module (or any other file) renamed or deleted in a newer version never
# survives from a previous install. Safe while jobs run — pwsh reads scripts fully at startup,
# so already-running workers are unaffected.
$stagingDir = $destScriptDir + '.staging'
if (Test-Path -LiteralPath $stagingDir) {
    Remove-Item -LiteralPath $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
Copy-Item -Path (Join-Path $sourceRoot 'ccodex.ps1') -Destination $stagingDir -Force
Copy-Item -Path (Join-Path $sourceRoot 'lib') -Destination $stagingDir -Recurse -Force
if (Test-Path -LiteralPath $destScriptDir) {
    Remove-Item -LiteralPath $destScriptDir -Recurse -Force
}
Move-Item -LiteralPath $stagingDir -Destination $destScriptDir

$shimContent = @"
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$destScriptDir\ccodex.ps1" %*
exit /b %ERRORLEVEL%
"@
$shimPath = Join-Path $InstallDir 'ccodex.cmd'
[System.IO.File]::WriteAllText($shimPath, $shimContent, (New-Object System.Text.UTF8Encoding($false)))

New-Item -ItemType Directory -Path $TemplatesDir -Force | Out-Null
$templateDest = Join-Path $TemplatesDir 'worker-prompt.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\worker-prompt.md') -Destination $templateDest -Force

$claudeCommandsDir = Join-Path $ClaudeDir 'commands'
New-Item -ItemType Directory -Path $claudeCommandsDir -Force | Out-Null
$claudeCommandDest = Join-Path $claudeCommandsDir 'ccodex.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\claude-command-ccodex.md') -Destination $claudeCommandDest -Force

# Per-function namespaced commands: templates/claude-commands/<name>.md installs to
# commands/ccodex/<name>.md, which Claude Code exposes as /ccodex:<name>.
$claudeNamespacedDir = Join-Path $claudeCommandsDir 'ccodex'
New-Item -ItemType Directory -Path $claudeNamespacedDir -Force | Out-Null
# Mirror the source set exactly: a template renamed or deleted in a later version must not
# leave a ghost /ccodex:<name> command behind from a previous install. A wildcard with no
# matches is silent; a real deletion failure (lock/ACL) must stop the install, not hide a ghost.
Remove-Item -Path (Join-Path $claudeNamespacedDir '*.md') -Force
Copy-Item -Path (Join-Path $sourceRoot 'templates\claude-commands\*.md') -Destination $claudeNamespacedDir -Force

$claudeRulesDir = Join-Path $ClaudeDir 'rules'
New-Item -ItemType Directory -Path $claudeRulesDir -Force | Out-Null
$claudeRuleDest = Join-Path $claudeRulesDir 'ccodex-delegation.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\claude-rule-ccodex-delegation.md') -Destination $claudeRuleDest -Force

$claudeSkillDir = Join-Path $ClaudeDir 'skills\ccodex'
New-Item -ItemType Directory -Path $claudeSkillDir -Force | Out-Null
$claudeSkillDest = Join-Path $claudeSkillDir 'SKILL.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\claude-skill-ccodex.md') -Destination $claudeSkillDest -Force

Write-Host "ccodex installed to $destScriptDir"
Write-Host "shim: $shimPath"
Write-Host "default template: $templateDest"
Write-Host "claude command: $claudeCommandDest"
Write-Host "claude namespaced commands (/ccodex:<name>): $claudeNamespacedDir"
Write-Host "claude delegation rule: $claudeRuleDest"
Write-Host "claude skill: $claudeSkillDest"
if (($env:PATH -split ';') -notcontains $InstallDir) {
    Write-Host "WARNING: $InstallDir is not on PATH. Add it to your user PATH to use 'ccodex' from any directory." -ForegroundColor Yellow
}
