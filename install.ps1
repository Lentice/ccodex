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

New-Item -ItemType Directory -Path $destScriptDir -Force | Out-Null
Copy-Item -Path (Join-Path $sourceRoot 'ccodex.ps1') -Destination $destScriptDir -Force
Copy-Item -Path (Join-Path $sourceRoot 'lib') -Destination $destScriptDir -Recurse -Force

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
# leave a ghost /ccodex:<name> command behind from a previous install.
Remove-Item -Path (Join-Path $claudeNamespacedDir '*.md') -Force -ErrorAction SilentlyContinue
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
