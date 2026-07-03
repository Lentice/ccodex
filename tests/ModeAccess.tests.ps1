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

Write-Host "implement mode is blocked in Phase 1"
Assert-Throws { Resolve-CcodexAccess -Mode 'implement' -Access $null } 'implement mode is not available until Phase 4'
Assert-Throws { Resolve-CcodexAccess -Mode 'implement' -Access 'worktree' } 'implement mode is blocked even with an explicit access'

Write-Host "worktree access is blocked in Phase 1"
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'worktree' } 'worktree access is not available until Phase 4'

Write-Host "unknown mode/access"
Assert-Throws { Resolve-CcodexAccess -Mode 'bogus' -Access $null } 'throws on an unknown mode'
Assert-Throws { Resolve-CcodexAccess -Mode 'review' -Access 'bogus' } 'throws on an unknown access'

Write-Host "ConvertTo-CcodexSandboxFlag"
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'read-only') 'read-only' 'maps read-only straight through'
Assert-Equal (ConvertTo-CcodexSandboxFlag -Access 'workspace') 'workspace-write' 'maps workspace to workspace-write'

Write-Host "Build-CcodexCodexArgs"
$codexArgs = Build-CcodexCodexArgs -Access 'read-only' -RepoRoot 'D:\Repo' -ResultPath 'D:\Job\result.md'
Assert-Equal ($codexArgs -join '|') (@('--ask-for-approval', 'never', 'exec', '--sandbox', 'read-only', '--json', '--color', 'never', '-C', 'D:\Repo', '--output-last-message', 'D:\Job\result.md', '-') -join '|') 'produces the exact codex exec argument shape'

Complete-CcodexTests
