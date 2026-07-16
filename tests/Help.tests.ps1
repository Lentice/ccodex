# tests/Help.tests.ps1
param([switch]$IncludeDispatch)

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Help.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$expectedCommands = @(
    'run', 'review', 'resume', 'submit', 'list', 'status', 'wait', 'read',
    'cancel', 'diff', 'apply', 'tail', 'cleanup', 'doctor', 'debug'
)

Write-Host 'Get-CcodexCommandNames: returns the canonical ordered command inventory'
$commandNames = @(Get-CcodexCommandNames)
Assert-Equal ($commandNames -join ',') ($expectedCommands -join ',') 'full ordered command list'

Write-Host 'Get-CcodexTopLevelHelpText: includes synopsis, every command, and every common flag'
$topLevelHelp = Get-CcodexTopLevelHelpText
Assert-True ($topLevelHelp.Contains('Usage: ccodex <command> [options]')) 'top-level synopsis is present'
foreach ($commandName in $expectedCommands) {
    Assert-True ($topLevelHelp -match "(?m)\b$([regex]::Escape($commandName))\b") "top-level help names $commandName"
}
foreach ($flag in @('--json', '--repo', '--model', '--effort', '--state-root', '--group', '--label', '--hard-timeout-sec')) {
    Assert-True ($topLevelHelp -like "*$flag*") "top-level help names $flag"
}
Assert-True ($topLevelHelp -like '*ccodex <command> --help*') 'top-level help points to per-command help'

Write-Host 'Get-CcodexCommandHelpText: known command has usage, flags, and example; unknown is null'
$runHelp = Get-CcodexCommandHelpText -Command 'run'
Assert-True ($runHelp -like '*Usage: ccodex run*') 'run help has a usage line'
Assert-True ($runHelp -like '*--mode*') 'run help has at least one flag'
Assert-True ($runHelp -like '*review/brainstorm: read-only*test: workspace or worktree*implement: worktree*') 'run help includes the mode/access matrix'
Assert-True ($runHelp -like '*Example:*') 'run help has an example'
$submitHelp = Get-CcodexCommandHelpText -Command 'submit'
Assert-True ($submitHelp -like '*review/brainstorm: read-only (default)*test: workspace or worktree (required)*implement: worktree (default)*') 'submit help includes mode/access defaults'
$applyHelp = Get-CcodexCommandHelpText -Command 'apply'
Assert-True ($applyHelp -like '*--allow-untracked*') 'apply help names the opt-in untracked-file override'
Assert-True ($null -eq (Get-CcodexCommandHelpText -Command 'bogus')) 'unknown command returns null'

if ($IncludeDispatch) {
    function Invoke-CcodexHelpCase {
        param([string[]]$Arguments)
        $output = & pwsh -NoLogo -NoProfile -File $ccodexPs @Arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text     = ($output -join "`n")
        }
    }

    Write-Host 'dispatch: bare invocation and top-level help aliases exit 0 with top-level help'
    foreach ($arguments in @(
        [string[]]@(),
        [string[]]@('--help'),
        [string[]]@('-h'),
        [string[]]@('help')
    )) {
        $result = Invoke-CcodexHelpCase -Arguments $arguments
        Assert-Equal $result.ExitCode 0 "'$($arguments -join ' ')' exits 0"
        Assert-True ($result.Text.Contains('Usage: ccodex <command> [options]')) "'$($arguments -join ' ')' prints top-level help"
    }

    Write-Host 'dispatch: help <command> and command help flags exit 0 with per-command help'
    foreach ($arguments in @(
        [string[]]@('help', 'run'),
        [string[]]@('run', '--help'),
        [string[]]@('apply', '-h')
    )) {
        $result = Invoke-CcodexHelpCase -Arguments $arguments
        $helpedCommand = if ($arguments[0] -eq 'help') { $arguments[1] } else { $arguments[0] }
        Assert-Equal $result.ExitCode 0 "'$($arguments -join ' ')' exits 0"
        Assert-True ($result.Text -like "*Usage: ccodex $helpedCommand*") "'$($arguments -join ' ')' prints $helpedCommand help"
    }

    Write-Host 'dispatch: unknown-under-help and unknown command exit 2 with canonical inventory'
    $expectedInventory = $expectedCommands -join ', '
    foreach ($arguments in @(
        [string[]]@('help', 'bogus'),
        [string[]]@('bogus', '--help'),
        [string[]]@('bogus')
    )) {
        $result = Invoke-CcodexHelpCase -Arguments $arguments
        Assert-Equal $result.ExitCode 2 "'$($arguments -join ' ')' exits 2"
        Assert-True ($result.Text -like "*command 'bogus' is not implemented*") "'$($arguments -join ' ')' prints unknown-command message"
        Assert-True ($result.Text -like "*Supported commands: $expectedInventory.*") "'$($arguments -join ' ')' uses canonical inventory"
    }
}

Complete-CcodexTests
