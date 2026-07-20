# lib/CommandRegistry.ps1
#
# Data-driven command registry (backlog #14 / issue #1). Single source of truth for:
#   * the dispatch INVENTORY — every command the CLI recognizes, INCLUDING the internal
#     `worker` entrypoint, which must be dispatchable but hidden from help (VisibleInHelp/
#     Internal metadata; amendment 3);
#   * WHICH commands are router-dispatched vs still handled by the legacy switch
#     (a HandlerFunction present => migrated; amendment 4), so there is never a second
#     parallel inventory during the command-by-command migration;
#   * ROUTING a recognized, migrated command to its handler and returning its exit code.
#
# Design constraints baked in from the issue amendments:
#   * Help TEXT stays authored in lib/Help.ps1 (amendment 9). This module derives its VISIBLE
#     inventory from Get-CcodexCommandNames so the two can never drift; the dependency on the
#     help module is explicit — dot-source lib/Help.ps1 BEFORE this module (amendment 11).
#   * Per-command argument parsing/validation stays in each handler (amendments 6/7). The router
#     does NOT parse arguments and does NOT centrally reject unknown flags or extra positionals
#     (amendment 5) — each command keeps its exact current permissiveness.
#   * Output policy is per-command (amendment 8): each handler writes its own stdout/stderr,
#     byte-for-byte as the legacy switch arm did, and returns only the integer exit code.
#
# A handler function has the signature
#   param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][ref]$ExitCode)
# It writes its own stdout/stderr with Write-Output/Write-Host EXACTLY as the legacy switch arm
# did, sets $ExitCode.Value to the command's exit code, and returns nothing on the success stream.
# The [ref] (rather than a normal return value) is load-bearing: PowerShell merges a function's
# return value into its success/output stream, so a handler that both printed via Write-Output AND
# returned an int would have its stdout captured together with the int by any caller that assigned
# the call — swallowing the stdout and corrupting the exit code. The dispatcher therefore invokes
# the handler INLINE and UNCAPTURED (see ccodex.ps1) so Write-Output flows straight to the real
# console, and reads the exit code back through the [ref]. Do not wrap handler invocation in a
# value-returning function for the same reason.
#
# $Context is the pre-bound dispatch context (see ccodex.ps1) exposing
# .Command/.PositionalTask/.Mode/.Access/.Repo/.PromptFile/.Args — the state left after the
# top-level plain param() binding, which handlers must work with as-is and NOT re-derive
# (amendment 2). Handlers read leftover flags from .Args via the existing Get-CcodexArgValue* /
# ConvertTo-Ccodex* helpers, exactly as the arms did.

# Command name -> dispatch handler function name. A command is "migrated" (router-dispatched)
# exactly when it appears here; absent => the legacy switch still owns it. This map is grown one
# command at a time across the migration commits; the switch is deleted once every command has an
# entry. Keeping the mapping here (not a Migrated boolean scattered per entry) makes the migration
# state a single readable list.
$script:CcodexCommandHandlers = @{
    # e.g. status = 'Invoke-CcodexStatusDispatch'  (populated per migration commit)
}

# Internal (non-help-visible) commands: valid to dispatch, but must NOT appear in the help
# inventory or the unknown-command "Supported commands" list. `worker` is launched only by the
# detached submit process and by tests.
$script:CcodexInternalCommands = @('worker')

function Get-CcodexCommandRegistry {
    # Build the ordered dispatch inventory on demand: the help-visible commands first (in their
    # canonical Help.ps1 order), then the internal commands. Derived from Get-CcodexCommandNames
    # so the visible set is never a hand-maintained parallel list. Requires lib/Help.ps1.
    $registry = [ordered]@{}
    foreach ($name in (Get-CcodexCommandNames)) {
        $registry[$name] = [pscustomobject]@{
            Name            = $name
            VisibleInHelp   = $true
            Internal        = $false
            HandlerFunction = $script:CcodexCommandHandlers[$name]
        }
    }
    foreach ($name in $script:CcodexInternalCommands) {
        $registry[$name] = [pscustomobject]@{
            Name            = $name
            VisibleInHelp   = $false
            Internal        = $true
            HandlerFunction = $script:CcodexCommandHandlers[$name]
        }
    }
    return $registry
}

function Get-CcodexRegistryCommandNames {
    # Full dispatch inventory (visible + internal), for completeness checks and the end-state
    # unknown-command decision. NOTE: the user-facing "Supported commands" list stays
    # Get-CcodexCommandNames (visible only) — this superset additionally contains `worker`.
    return @((Get-CcodexCommandRegistry).Keys)
}

function Get-CcodexRegistryEntry {
    param([AllowNull()][AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrEmpty($Command)) { return $null }
    $registry = Get-CcodexCommandRegistry
    if ($registry.Contains($Command)) { return $registry[$Command] }
    return $null
}

function Test-CcodexRegistryHasCommand {
    param([AllowNull()][AllowEmptyString()][string]$Command)
    return ($null -ne (Get-CcodexRegistryEntry -Command $Command))
}

function Test-CcodexRegistryCommandRouted {
    # True iff $Command is a recognized command with a migrated (router-dispatched) handler. The
    # dispatcher uses this to decide whether to run the handler inline (see the handler contract
    # above) or fall through to the legacy switch. Deliberately does NOT invoke the handler — a
    # value-returning function cannot invoke a handler without capturing its stdout (see above).
    param([AllowNull()][AllowEmptyString()][string]$Command)
    $entry = Get-CcodexRegistryEntry -Command $Command
    return ($null -ne $entry -and -not [string]::IsNullOrEmpty($entry.HandlerFunction))
}

function Get-CcodexRegistryHandlerName {
    # The migrated handler function name for $Command, or $null if the command is unknown or not
    # yet migrated. The dispatcher resolves this to a command and invokes it inline/uncaptured.
    param([AllowNull()][AllowEmptyString()][string]$Command)
    $entry = Get-CcodexRegistryEntry -Command $Command
    if ($null -eq $entry) { return $null }
    return $entry.HandlerFunction
}
