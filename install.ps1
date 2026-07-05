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

$claudeRulesDir = Join-Path $ClaudeDir 'rules'
New-Item -ItemType Directory -Path $claudeRulesDir -Force | Out-Null
$claudeRuleDest = Join-Path $claudeRulesDir 'ccodex-delegation.md'
Copy-Item -Path (Join-Path $sourceRoot 'templates\claude-rule-ccodex-delegation.md') -Destination $claudeRuleDest -Force

Write-Host "ccodex installed to $destScriptDir"
Write-Host "shim: $shimPath"
Write-Host "default template: $templateDest"
Write-Host "claude command: $claudeCommandDest"
Write-Host "claude delegation rule: $claudeRuleDest"
if (($env:PATH -split ';') -notcontains $InstallDir) {
    Write-Host "WARNING: $InstallDir is not on PATH. Add it to your user PATH to use 'ccodex' from any directory." -ForegroundColor Yellow
}
