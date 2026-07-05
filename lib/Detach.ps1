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
# treats the launch as successful. Callers map both launch failures (Start-CcodexDetachedWorker
# throwing) and sentinel timeouts (Wait-CcodexWorkerLaunch throwing) to wrapper exit code 23.

function Start-CcodexDetachedWorker {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$StateRoot,
        [string]$CodexPath,
        [ValidateSet('cim', 'startprocess')][string]$Mechanism = 'cim'
    )

    if ($Mechanism -eq 'cim') {
        $commandLine = "pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" worker --job-id $JobId"
        if ($StateRoot) { $commandLine += " --state-root `"$StateRoot`"" }
        if ($CodexPath) { $commandLine += " --codex-path `"$CodexPath`"" }

        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine      = $commandLine
            CurrentDirectory = $WorkingDirectory
        }
        if ($result.ReturnValue -ne 0) {
            throw "ccodex: native backend failed to launch the worker (Win32_Process.Create returned $($result.ReturnValue))."
        }
        return [int]$result.ProcessId
    }

    $argumentList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, 'worker', '--job-id', $JobId)
    if ($StateRoot) { $argumentList += @('--state-root', $StateRoot) }
    if ($CodexPath) { $argumentList += @('--codex-path', $CodexPath) }

    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $argumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    return $proc.Id
}

function Wait-CcodexWorkerLaunch {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [int]$TimeoutSec = 20
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
        Start-Sleep -Milliseconds 250
    }
}
