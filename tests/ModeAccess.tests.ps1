# tests/ModeAccess.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')

Write-Host "default access per mode"
Assert-Equal (Resolve-CcodexAccess -Mode 'review' -Access $null) 'read-only' 'review defaults to read-only'
Assert-Equal (Resolve-CcodexAccess -Mode 'brainstorm' -Access $null) 'read-only' 'brainstorm defaults to read-only'

Write-Host "test mode requires an explicit access"
Assert-Throws { Resolve-CcodexAccess -Mode 'test' -Access $null } 'test mode has no default access'
Assert-Throws { Resolve-CcodexAccess -Mode 'test' -Access 'read-only' } 'test mode rejects read-only access'
Assert-Equal (Resolve-CcodexAccess -Mode 'test' -Access 'workspace') 'workspace' 'test mode accepts workspace access'

Write-Host "implement mode is unlocked with worktree access"
Assert-Equal (Resolve-CcodexAccess -Mode 'implement' -Access $null) 'worktree' 'implement mode defaults to worktree access'
Assert-Equal (Resolve-CcodexAccess -Mode 'implement' -Access 'worktree') 'worktree' 'implement mode accepts explicit worktree access'
Assert-Throws { Resolve-CcodexAccess -Mode 'implement' -Access 'workspace' } 'implement mode rejects workspace access (worktree only)'

Write-Host "test mode accepts explicit worktree access"
Assert-Equal (Resolve-CcodexAccess -Mode 'test' -Access 'worktree') 'worktree' 'test mode accepts worktree access'

Write-Host "worktree access is still invalid for read-only modes"
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'worktree' } 'review mode rejects worktree access'
Assert-Throws { Resolve-CcodexAccess -Mode 'brainstorm' -Access 'worktree' } 'brainstorm mode rejects worktree access'

Write-Host "unknown mode/access"
Assert-Throws { Resolve-CcodexAccess -Mode 'bogus' -Access $null } 'throws on an unknown mode'
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'bogus' } 'throws on an unknown access'

Write-Host "ConvertTo-CcodexSandboxFlag"
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'read-only') 'read-only' 'maps read-only straight through'
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'workspace') 'workspace-write' 'maps workspace to workspace-write'
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'worktree') 'workspace-write' 'maps worktree to workspace-write'

Write-Host "Build-CcodexCodexArgs"
$codexArgs = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md'
Assert-Equal ($codexArgs -join '|') (@('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-') -join '|') 'produces the exact codex exec argument shape'

Write-Host "Build-CcodexCodexArgs: --model only splices -m <model> in the exec-level segment before the trailing prompt positional"
$argsModel = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md' -Model 'gpt-5-codex'
$expectedModel = @('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-m', 'gpt-5-codex', '-')
Assert-Equal ($argsModel -join '|') ($expectedModel -join '|') '--model adds -m <model> after the exec options and before the trailing -'

Write-Host "Build-CcodexCodexArgs: --effort only splices -c model_reasoning_effort=<effort> as one bare element before the trailing prompt positional"
$argsEffort = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md' -Effort 'high'
$expectedEffort = @('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-c', 'model_reasoning_effort=high', '-')
Assert-Equal ($argsEffort -join '|') ($expectedEffort -join '|') '--effort adds -c model_reasoning_effort=<effort> (one bare unquoted element) before the trailing -'

Write-Host "Build-CcodexCodexArgs: --model and --effort together, model before effort, both before the trailing -"
$argsBoth = Build-CcodexCodexArgs -Access 'workspace' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md' -Model 'gpt-5-codex' -Effort 'low'
$expectedBoth = @('--ask-for-approval', 'never', 'exec', '--sandbox', 'workspace-write', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-m', 'gpt-5-codex', '-c', 'model_reasoning_effort=low', '-')
Assert-Equal ($argsBoth -join '|') ($expectedBoth -join '|') 'both flags splice -m then -c before the trailing prompt positional'

Write-Host "Build-CcodexCodexArgs: neither flag -> argv byte-identical to the pre-feature shape"
$argsNeither = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md' -Model $null -Effort ''
Assert-Equal ($argsNeither -join '|') (@('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-') -join '|') 'omitting both flags (null/empty) leaves the argv byte-identical'

Complete-CcodexTests
