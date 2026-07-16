# lib/Detach.ps1
#
# Start-CcodexDetachedWorker launches `ccodex.ps1 worker --job-id <id>` as a process that
# outlives the calling (submitting) process. Two mechanisms are supported:
#   - cim:         Invoke-CimMethod Win32_Process.Create. This is the production mechanism —
#                   CIM-created processes are parented outside the caller's Job Object by
#                   construction, so they survive even when the caller sits inside a Job Object
#                   with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE. CIM-launched children also get a
#                   FRESH user environment: env-var overrides made in the caller's process do
#                   NOT propagate. Callers that need deterministic fixture behavior under `cim`
#                   must pass it via command-line flags (--state-root/--codex-path), never env.
#   - startprocess: Start-Process. Used by tests (and available as a fallback) because it is
#                   simple and — for the same reason env doesn't propagate under `cim` — does
#                   inherit the caller's environment, so fixture env vars (e.g.
#                   CCODEX_FAKE_EXIT_CODE) keep working under this mechanism.
#
# Wait-CcodexWorkerLaunch is the startup sentinel: it proves the launched worker is actually
# alive and has taken ownership of the job (moved status.json off 'created') before the caller
# treats the launch as successful. Callers map launch failures and startup-sentinel failures
# (the process exits before stamping, or the timeout expires) to wrapper exit code 23.

function ConvertTo-CcodexQuotedLaunchArg {
    # Wrap a launch-line argument in double quotes, doubling any TRAILING run of backslashes so
    # the closing quote is not escaped by it (the MSVCRT/pwsh argv rule: `"C:\"` otherwise makes
    # the parser treat `\"` as a literal quote and swallow the following text). Embedded
    # double-quotes are rejected upstream in Start-CcodexDetachedWorker, so only the
    # trailing-backslash case needs handling here; interior backslashes are literal already.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '(\\+)$', '$1$1') + '"'
}

function Get-CcodexWorkerArgumentLine {
    # Shared quoting builder for the worker launch command line: `worker --job-id <id>`
    # plus the optional `--state-root`/`--codex-path` overrides, hand-quoted exactly once
    # here. ScriptPath/StateRoot/CodexPath are always wrapped in double quotes (harmless
    # for space-free paths, load-bearing for paths that contain spaces); JobId is never
    # quoted because job ids are wrapper-generated and never contain whitespace. Both the
    # `cim` (raw Win32_Process CommandLine) and `startprocess` (Start-Process -ArgumentList)
    # mechanisms below build their launch command from this SAME string so a space in
    # StateRoot/CodexPath/ScriptPath can never be re-split into extra argv entries by
    # either backend.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$JobId,
        [string]$StateRoot,
        [string]$CodexPath,
        [string]$Model,
        [string]$Effort
    )
    $line = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-CcodexQuotedLaunchArg $ScriptPath) worker --job-id $JobId"
    if ($StateRoot) { $line += " --state-root $(ConvertTo-CcodexQuotedLaunchArg $StateRoot)" }
    if ($CodexPath) { $line += " --codex-path $(ConvertTo-CcodexQuotedLaunchArg $CodexPath)" }
    # --model/--effort are per-invocation knobs that status.json deliberately never carries,
    # so the launch command line is their ONLY route into the detached worker. Model is quoted
    # like the path arguments (model names are an open set); effort is validated upstream to
    # minimal|low|medium|high and never needs quoting.
    if ($Model) { $line += " --model $(ConvertTo-CcodexQuotedLaunchArg $Model)" }
    if ($Effort) { $line += " --effort $Effort" }
    return $line
}

function Start-CcodexDetachedWorker {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$StateRoot,
        [string]$CodexPath,
        [ValidateSet('cim', 'startprocess')][string]$Mechanism = 'cim',
        [string]$Model,
        [string]$Effort
    )

    # Dogfood #4: a double-quote is illegal in a Windows path and would corrupt the
    # hand-built CIM command line below (or, less catastrophically but still wrong, silently
    # mis-tokenize a Start-Process argument). Fail loudly here rather than launching a
    # broken/ambiguous worker process. Model rides the same quoted-argument path, so the
    # same guard applies to it.
    foreach ($pathArg in @($ScriptPath, $StateRoot, $CodexPath, $Model)) {
        if ($pathArg -and $pathArg.Contains('"')) {
            throw "ccodex: internal error: path argument contains an illegal double-quote character: $pathArg"
        }
    }

    $argumentLine = Get-CcodexWorkerArgumentLine -ScriptPath $ScriptPath -JobId $JobId -StateRoot $StateRoot -CodexPath $CodexPath -Model $Model -Effort $Effort

    # Launch the CURRENTLY-RUNNING pwsh by absolute path, never a bare `pwsh`. Both backends
    # below set CurrentDirectory to the target repo, and Windows process resolution searches the
    # current directory, so a bare name could execute a `pwsh.exe` planted in an untrusted repo
    # instead of the real shell. $PSHOME is the running interpreter's own directory.
    $pwshExe = Join-Path $PSHOME 'pwsh.exe'

    if ($Mechanism -eq 'cim') {
        $commandLine = "$(ConvertTo-CcodexQuotedLaunchArg $pwshExe) $argumentLine"

        # ShowWindow = 0 (SW_HIDE): without an explicit Win32_ProcessStartup the created
        # console worker gets a visible console window that flashes up at the user. The
        # startup instance is ClientOnly — it is marshalled as the method's startup info,
        # never persisted to WMI.
        $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine               = $commandLine
            CurrentDirectory          = $WorkingDirectory
            ProcessStartupInformation = $startup
        }
        if ($result.ReturnValue -ne 0) {
            throw "ccodex: native backend failed to launch the worker (Win32_Process.Create returned $($result.ReturnValue))."
        }
        return [int]$result.ProcessId
    }

    # Dogfood #3 (triaged false positive): -WindowStyle Hidden allocates the child its own
    # separate (hidden) console, rather than sharing the caller's console/stdout handles.
    # The worker's own stdout/stderr therefore cannot interleave with the submitting
    # process's stdout — Wait-CcodexWorkerLaunch/status polling, not shared streams, is how
    # the caller observes worker progress. tests/AsyncE2E.tests.ps1 asserts submit's stdout
    # is exactly the job-id/job-dir lines for this reason.
    #
    # -ArgumentList is passed a SINGLE pre-quoted string (not a string[] of raw elements):
    # Start-Process joins a multi-element -ArgumentList with plain spaces and quotes
    # nothing, so a StateRoot/CodexPath containing a space would otherwise be re-split into
    # extra argv entries by the child process. Passing the whole already-quoted line as one
    # element sidesteps that re-join entirely, matching the `cim` command line exactly.
    $proc = Start-Process -FilePath $pwshExe -ArgumentList $argumentLine -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    return $proc.Id
}

function Wait-CcodexWorkerLaunch {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [int]$TimeoutSec = 120,
        [int]$ProcessId
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $status = Read-CcodexStatusFile -JobDir $JobDir
        if ($status -and $status.status -ne 'created') {
            return $status
        }
        if ((Get-Date) -ge $deadline) {
            throw "ccodex: worker did not start within ${TimeoutSec}s; job left in 'created' state for diagnosis."
        }
        if ($PSBoundParameters.ContainsKey('ProcessId')) {
            $workerProcess = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $workerProcess) {
                # Close the narrow race where the worker stamped status.json and then exited
                # between the first status read and this liveness check.
                Start-Sleep -Milliseconds 500
                $statusAfterExit = Read-CcodexStatusFile -JobDir $JobDir
                if ($statusAfterExit -and $statusAfterExit.status -ne 'created') {
                    return $statusAfterExit
                }
                if ($statusAfterExit -and $statusAfterExit.status -eq 'created') {
                    throw "ccodex: worker process exited before stamping startup; job left in 'created' state for diagnosis."
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
}
