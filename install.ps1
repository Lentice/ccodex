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
    $stateRootFull = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ccodex')).TrimEnd('\')
    $destFull = [System.IO.Path]::GetFullPath($destScriptDir).TrimEnd('\')
    # Refuse the job-state root itself OR any directory inside it (equal-or-descendant, compared
    # case-insensitively on full paths): the mirror delete on upgrade would otherwise destroy
    # jobs/indexes/worktrees, and a later job cleanup could delete the install out from under itself.
    if ($destFull -ieq $stateRootFull -or $destFull.StartsWith($stateRootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "install.ps1: refusing to install into '$destScriptDir' - it is inside the ccodex job-state root ('$stateRootFull'). Choose a different -InstallDir."
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
$stagingDir = $destScriptDir + '.staging-' + [Guid]::NewGuid().ToString('N')
$backupDir = $destScriptDir + '.old-' + [Guid]::NewGuid().ToString('N')
$installLive = $false
try {
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceRoot 'ccodex.ps1') -Destination $stagingDir -Force
    Copy-Item -Path (Join-Path $sourceRoot 'lib') -Destination $stagingDir -Recurse -Force

    # Swap by RENAME, never delete-then-move: move the live install aside to a backup first, then
    # move staging into place, and only drop the backup once the new tree is in place. If the
    # second move fails (AV lock, ACL, disk), restore the backup so the previous install keeps
    # working instead of being left absent (a plain `Remove-Item $dest; Move-Item` would strand
    # the CLI with no ccodex.ps1 if the move failed). A per-run GUID staging name also avoids
    # clobbering an unrelated `ccodex.staging` directory a user might already have under -InstallDir.
    if (Test-Path -LiteralPath $destScriptDir) {
        Move-Item -LiteralPath $destScriptDir -Destination $backupDir
    }
    try {
        Move-Item -LiteralPath $stagingDir -Destination $destScriptDir
        $installLive = $true
    } catch {
        # The new-install move failed: restore the previous copy so the CLI keeps working. Only
        # mark the install live again if the restore actually succeeds.
        if ((Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $destScriptDir)) {
            Move-Item -LiteralPath $backupDir -Destination $destScriptDir
            $installLive = $true
        }
        throw
    }
} finally {
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    # Delete the backup ONLY when a live install is confirmed in place. If BOTH the swap and the
    # restore failed, the backup is the only working copy — never delete it; preserve it and tell
    # the user where it is so the install can be recovered by hand.
    if (Test-Path -LiteralPath $backupDir) {
        if ($installLive) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "install.ps1: upgrade failed and the previous install could not be restored automatically. Your previous working copy is preserved at: $backupDir"
        }
    }
}

$shimContent = @"
@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$destScriptDir\ccodex.ps1" %*
exit /b %ERRORLEVEL%
"@
$shimPath = Join-Path $InstallDir 'ccodex.cmd'
# Write to a sibling temp file then move it into place, so an interrupted or failed write can't
# truncate the live shim and leave the CLI unusable mid-upgrade.
$shimTmp = $shimPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
[System.IO.File]::WriteAllText($shimTmp, $shimContent, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $shimTmp -Destination $shimPath -Force

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
# Only files that correspond to an installed source template are managed. This preserves local
# /ccodex:<name> commands while still updating every command the installer owns; the source set is
# enumerated so adding a template requires no hardcoded managed-file list.
$claudeCommandTemplates = @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'templates\claude-commands') -Filter '*.md' -File -ErrorAction Stop)
foreach ($template in $claudeCommandTemplates) {
    Copy-Item -LiteralPath $template.FullName -Destination (Join-Path $claudeNamespacedDir $template.Name) -Force
}

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
