# tests/Registry.tests.ps1
#
# Guards lib/CommandRegistry.ps1 (backlog #14 / issue #1). Asserts the registry's data shape and
# router contract ONLY — never a command's observable behavior (that stays in the per-command
# shell-level suites and tests/Characterization.tests.ps1). Prior art for the style: Help.tests.ps1
# asserting Get-CcodexCommandNames.
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Help.ps1')
. (Join-Path $PSScriptRoot '..\lib\CommandRegistry.ps1')
# -ImportOnly so every migrated handler function is defined in scope for the resolvability check
# below, without executing a command (the dot-source guard this refactor must preserve).
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly

# The full dispatch inventory: every command the CLI recognizes. `worker` is the internal
# entrypoint — dispatchable but hidden from help. This list is the completeness oracle: every
# arm the dispatcher can reach must have a registry spec.
$expectedVisible = @(
    'run', 'review', 'resume', 'submit', 'list', 'status', 'wait', 'read',
    'cancel', 'diff', 'apply', 'tail', 'cleanup', 'doctor', 'debug'
)
$expectedFull = $expectedVisible + @('worker')

Write-Host 'Get-CcodexCommandRegistry: full ordered inventory = visible commands then internal worker'
$registry = Get-CcodexCommandRegistry
Assert-Equal (@($registry.Keys) -join ',') ($expectedFull -join ',') 'registry inventory is complete and ordered'

Write-Host 'Get-CcodexRegistryCommandNames: matches the ordered inventory'
Assert-Equal ((Get-CcodexRegistryCommandNames) -join ',') ($expectedFull -join ',') 'registry command-name inventory'

Write-Host 'visible entries carry VisibleInHelp=true / Internal=false and match Get-CcodexCommandNames'
Assert-Equal (@(Get-CcodexCommandNames) -join ',') ($expectedVisible -join ',') 'help-visible inventory is the derivation source (no drift)'
foreach ($name in $expectedVisible) {
    $entry = $registry[$name]
    Assert-True ($entry.VisibleInHelp) "$name is VisibleInHelp"
    Assert-True (-not $entry.Internal) "$name is not Internal"
    Assert-Equal $entry.Name $name "$name entry Name matches key"
}

Write-Host 'worker is an internal, help-hidden entry that is still a recognized command'
$workerEntry = $registry['worker']
Assert-True (-not $workerEntry.VisibleInHelp) 'worker is not VisibleInHelp'
Assert-True ($workerEntry.Internal) 'worker is Internal'
Assert-True (@(Get-CcodexCommandNames) -notcontains 'worker') 'worker is absent from the help-visible list'
Assert-True (Test-CcodexRegistryHasCommand -Command 'worker') 'worker is a recognized command'

Write-Host 'Get-CcodexRegistryEntry / Test-CcodexRegistryHasCommand: known vs unknown vs empty'
Assert-True ($null -ne (Get-CcodexRegistryEntry -Command 'run')) 'run resolves to an entry'
Assert-True ($null -eq (Get-CcodexRegistryEntry -Command 'bogus')) 'unknown command resolves to null'
Assert-True ($null -eq (Get-CcodexRegistryEntry -Command '')) 'empty command resolves to null'
Assert-True (Test-CcodexRegistryHasCommand -Command 'run') 'run is recognized'
Assert-True (-not (Test-CcodexRegistryHasCommand -Command 'bogus')) 'bogus is not recognized'
Assert-True (-not (Test-CcodexRegistryHasCommand -Command '')) 'empty is not recognized'

Write-Host 'migrated commands are routed to a resolvable handler; unmigrated commands are not routed'
foreach ($name in $expectedFull) {
    $entry = $registry[$name]
    if ([string]::IsNullOrEmpty($entry.HandlerFunction)) {
        # Not yet migrated (still handled by the legacy switch): the dispatcher must not route it.
        Assert-True (-not (Test-CcodexRegistryCommandRouted -Command $name)) "$name is not routed while unmigrated"
        Assert-True ($null -eq (Get-CcodexRegistryHandlerName -Command $name)) "$name has no handler name while unmigrated"
    } else {
        Assert-True (Test-CcodexRegistryCommandRouted -Command $name) "$name is routed once migrated"
        $handlerName = Get-CcodexRegistryHandlerName -Command $name
        Assert-Equal $handlerName $entry.HandlerFunction "$name routes to its declared handler name"
        Assert-True ($null -ne (Get-Command -Name $handlerName -ErrorAction SilentlyContinue)) `
            "$name handler function '$handlerName' is defined"
        # The migrated handler must accept the dispatch contract: -Context and a [ref] -ExitCode.
        $handlerParams = (Get-Command -Name $handlerName).Parameters
        Assert-True ($handlerParams.ContainsKey('Context')) "$name handler declares -Context"
        Assert-True ($handlerParams.ContainsKey('ExitCode')) "$name handler declares -ExitCode"
        Assert-True ($handlerParams['ExitCode'].ParameterType -eq [ref]) "$name handler -ExitCode is a [ref]"
    }
}

Write-Host 'unknown commands are neither recognized nor routed (caller owns the unknown-command message)'
Assert-True (-not (Test-CcodexRegistryCommandRouted -Command 'bogus')) 'unknown command is not routed'
Assert-True ($null -eq (Get-CcodexRegistryHandlerName -Command 'bogus')) 'unknown command has no handler name'

Complete-CcodexTests
