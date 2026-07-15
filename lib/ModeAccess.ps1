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

function Get-CcodexModelEffortArgs {
    # The optional per-invocation model/effort segment shared by Build-CcodexCodexArgs and
    # Build-CcodexResumeArgs (lib/Resume.ps1). --model passes through verbatim as `-m <model>`;
    # --effort becomes `-c model_reasoning_effort=<effort>` as ONE bare argv element — the value
    # is deliberately NOT quoted TOML (`"high"`): a bare value fails Codex's TOML parse and is
    # then used as a literal string, which sidesteps the cmd.exe-shim quote-layering entirely.
    # Effort validation (minimal|low|medium|high, case-sensitive) happens at the dispatcher
    # (ConvertTo-CcodexEffort); by the time a value reaches here it is passed through verbatim.
    # Both absent (null/empty) => empty array, leaving callers' argv byte-identical.
    param(
        [string]$Model,
        [string]$Effort
    )
    $extra = @()
    if (-not [string]::IsNullOrEmpty($Model)) { $extra += @('-m', $Model) }
    if (-not [string]::IsNullOrEmpty($Effort)) { $extra += @('-c', "model_reasoning_effort=$Effort") }
    return , $extra
}

function Build-CcodexCodexArgs {
    param(
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ResultPath,
        # Optional per-invocation knobs; both must sit in the exec-level options segment,
        # BEFORE the trailing `-` prompt positional (clap resolves them at the exec level).
        [string]$Model = $null,
        [string]$Effort = $null,
        # When set, add codex exec's `--skip-git-repo-check` so a target that is not a git
        # repository (or a git dir codex does not consider "trusted") is accepted instead of
        # failing with "Not inside a trusted directory and --skip-git-repo-check was not
        # specified." Opt-in per invocation (ccodex run --skip-git-repo-check); off by default
        # => argv byte-identical to before this switch existed, so the trusted-directory guard
        # still applies to every normal run.
        [switch]$SkipGitRepoCheck
    )
    $sandbox = ConvertTo-CcodexSandboxFlag -Access $Access
    $skipGitArgs = if ($SkipGitRepoCheck) { @('--skip-git-repo-check') } else { @() }
    return @(
        '--ask-for-approval', 'never',
        'exec',
        '--sandbox', $sandbox,
        '--json',
        '--color', 'never',
        '-C', $RepoRoot,
        '--output-last-message', $ResultPath
    ) + $skipGitArgs + (Get-CcodexModelEffortArgs -Model $Model -Effort $Effort) + @('-')
}
