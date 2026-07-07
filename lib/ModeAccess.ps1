# lib/ModeAccess.ps1
$script:CcodexValidModes = @('review', 'brainstorm', 'test', 'implement')
$script:CcodexValidAccess = @('read-only', 'workspace', 'worktree')
$script:CcodexDefaultAccessByMode = @{
    review     = 'read-only'
    brainstorm = 'read-only'
    test       = $null
    implement  = 'worktree'
}

function Resolve-CcodexAccess {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [string]$Access
    )
    if ($Mode -notin $script:CcodexValidModes) {
        throw "ccodex: unknown mode '$Mode'. Valid modes: $($script:CcodexValidModes -join ', ')."
    }

    if (-not $Access) {
        $default = $script:CcodexDefaultAccessByMode[$Mode]
        if (-not $default) {
            throw "ccodex: mode '$Mode' has no default access. Pass --access explicitly (e.g. --access workspace)."
        }
        return $default
    }

    if ($Access -notin $script:CcodexValidAccess) {
        throw "ccodex: unknown access '$Access'. Valid access modes: $($script:CcodexValidAccess -join ', ')."
    }
    if ($Access -eq 'worktree' -and $Mode -notin @('implement', 'test')) {
        throw "ccodex: --access worktree is only valid for modes 'implement' and 'test'."
    }
    if ($Mode -eq 'implement' -and $Access -ne 'worktree') {
        throw "ccodex: mode 'implement' requires --access worktree (worktree isolation only)."
    }
    if ($Mode -eq 'test' -and $Access -eq 'read-only') {
        throw "ccodex: mode 'test' cannot use --access read-only. Browser/test tasks need --access workspace before worktree support."
    }

    return $Access
}

function ConvertTo-CcodexSandboxFlag {
    param([Parameter(Mandatory)][ValidateSet('read-only', 'workspace', 'worktree')][string]$Access)
    switch ($Access) {
        'read-only' { return 'read-only' }
        'workspace' { return 'workspace-write' }
        'worktree'  { return 'workspace-write' }
    }
}

function Build-CcodexCodexArgs {
    param(
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ResultPath
    )
    $sandbox = ConvertTo-CcodexSandboxFlag -Access $Access
    return @(
        '--ask-for-approval', 'never',
        'exec',
        '--sandbox', $sandbox,
        '--json',
        '--color', 'never',
        '-C', $RepoRoot,
        '--output-last-message', $ResultPath,
        '-'
    )
}
