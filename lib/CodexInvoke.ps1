function ConvertTo-CcodexWin32QuotedArgument {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Argument,
        [switch]$ForceQuote
    )
    if ($Argument.Length -eq 0) { return '""' }
    if (-not $ForceQuote -and $Argument -notmatch '[\s"]') { return $Argument }

    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$result.Append('\' * (($backslashes * 2) + 1))
            [void]$result.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$result.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$result.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$result.Append('\' * ($backslashes * 2)) }
    [void]$result.Append('"')
    return $result.ToString()
}

function Resolve-CcodexCodexPath {
    # PowerShell command precedence ranks ExternalScript (.ps1) ABOVE Application
    # (.cmd/.exe). A standard npm install of Codex ships codex, codex.cmd AND
    # codex.ps1, so a bare `(Get-Command 'codex').Source` returns codex.ps1 — which
    # System.Diagnostics.Process with UseShellExecute=$false cannot launch (it
    # throws "not a valid application for this OS platform"), and which
    # Get-CcodexProcessLaunchPlan has no launch strategy for. Restrict resolution to
    # CommandType Application so we get the launchable codex.cmd/.exe (PATH order),
    # which the .cmd/.bat branch below already knows how to wrap through cmd.exe.
    $candidates = @(Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        throw "ccodex: could not find an executable 'codex' (codex.cmd or codex.exe) on PATH. Install the Codex CLI, or pass an explicit path."
    }
    return $candidates[0].Source
}

function ConvertTo-CcodexCmdInnerArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    # Quoting for a single element of the `cmd /d /s /c "<inner>"` command line.
    # The inner line is parsed twice: first by cmd.exe, then by the target's
    # MSVCRT argv parser. ConvertTo-CcodexWin32QuotedArgument only handles the
    # second parser and only force-quotes on whitespace/quote, so an argument
    # such as `D:\A&B\repo` (a cmd metacharacter but no whitespace) is left bare
    # and cmd.exe treats `&` as a command separator, `|` as a pipe, `<`/`>` as
    # redirection, `(`/`)` as grouping, `^` as an escape, and `%` as variable
    # expansion. Force-quoting any argument that contains a cmd metacharacter
    # makes cmd.exe treat those characters as literal text (the receiving MSVCRT
    # parser then strips the outer quotes). Windows paths cannot contain a literal
    # double-quote, so the residual MSVCRT/cmd embedded-quote mismatch
    # (CVE-2024-24576 class) is not reachable through repo/result path arguments.
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]' -and $Argument -match '[&|<>()^%]') {
        return ConvertTo-CcodexWin32QuotedArgument -Argument $Argument -ForceQuote
    }
    return ConvertTo-CcodexWin32QuotedArgument -Argument $Argument
}

function Get-CcodexProcessLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $extension = [System.IO.Path]::GetExtension($CodexPath).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $quotedParts = @($CodexPath) + $Arguments | ForEach-Object { ConvertTo-CcodexCmdInnerArgument $_ }
        $innerCommand = $quotedParts -join ' '
        return [pscustomobject]@{
            FileName     = "$env:SystemRoot\System32\cmd.exe"
            ArgumentList = @('/d', '/s', '/c', "`"$innerCommand`"")
        }
    }
    return [pscustomobject]@{
        FileName     = $CodexPath
        ArgumentList = $Arguments
    }
}

function Stop-CcodexProcessTree {
    # Force-kill an entire process tree by root pid. `taskkill /T` walks the
    # child chain (so the cmd.exe /d /s /c shim's launched codex/pwsh child is
    # covered too) and `/F` terminates unconditionally. Best-effort: a tree that
    # already exited yields a nonzero taskkill exit which is intentionally
    # swallowed (native commands never throw, and there is nothing left to kill).
    param([Parameter(Mandatory)][int]$ProcessId)
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    & $taskkill '/PID' $ProcessId '/T' '/F' 2>&1 | Out-Null
}

function Invoke-CcodexCodexProcess {
    # Returns the raw Codex process exit code, or the $null sentinel when a
    # job-level hard timeout ($HardTimeoutMs -gt 0) expired and the process tree
    # was force-killed. Non-null return values behave exactly as before (existing
    # callers treat non-null as the real exit code). On a hard-timeout kill,
    # exit_code.txt is deliberately NOT written (Codex never exited), while any
    # partial stdout/stderr already captured is still flushed to the log files so
    # the job's artifacts stay diagnosable.
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptContent,
        [Parameter(Mandatory)][string]$EventsLogPath,
        [Parameter(Mandatory)][string]$StderrLogPath,
        [Parameter(Mandatory)][string]$ExitCodeFilePath,
        [int]$HardTimeoutMs = 0
    )
    $plan = Get-CcodexProcessLaunchPlan -CodexPath $CodexPath -Arguments $Arguments

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $plan.FileName
    if ($plan.FileName -eq "$env:SystemRoot\System32\cmd.exe") {
        # .NET's ArgumentList re-quotes each element itself, which corrupts the
        # already-fully-quoted "<inner command>" element built for the cmd.exe
        # /d /s /c wrapping trick (it backslash-escapes the embedded quote
        # characters, which cmd.exe's /s stripping does not undo). Assigning
        # the pre-quoted argument text via the raw Arguments string instead
        # avoids that double-quoting.
        $psi.Arguments = $plan.ArgumentList -join ' '
    } else {
        foreach ($arg in $plan.ArgumentList) { [void]$psi.ArgumentList.Add($arg) }
    }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardInputEncoding = $utf8NoBom
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    $process.StandardInput.Write($PromptContent)
    $process.StandardInput.Close()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if ($HardTimeoutMs -gt 0) {
        if (-not $process.WaitForExit($HardTimeoutMs)) {
            # Budget exceeded and Codex has not exited: kill the whole tree, then
            # wait (parameterless) for the killed process object to reap so the
            # async stdout/stderr readers can drain the now-closed pipes. Each
            # await/close is guarded so a partial read never masks the timeout.
            Stop-CcodexProcessTree -ProcessId $process.Id
            try { $process.WaitForExit() } catch { }
            $partialStdout = ''
            $partialStderr = ''
            try { $partialStdout = $stdoutTask.GetAwaiter().GetResult() } catch { $partialStdout = '' }
            try { $partialStderr = $stderrTask.GetAwaiter().GetResult() } catch { $partialStderr = '' }
            try { $process.StandardOutput.Close() } catch { }
            try { $process.StandardError.Close() } catch { }
            Write-CcodexTextFile -Path $EventsLogPath -Content $partialStdout
            Write-CcodexTextFile -Path $StderrLogPath -Content $partialStderr
            # NOTE: no exit_code.txt on a hard-timeout kill (Codex never exited).
            return $null
        }
    }

    # WaitForExit() (parameterless) after a WaitForExit(timeout) that returned
    # true guarantees the async output handlers have fully flushed before we read.
    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    Write-CcodexTextFile -Path $EventsLogPath -Content $stdout
    Write-CcodexTextFile -Path $StderrLogPath -Content $stderr
    Write-CcodexTextFile -Path $ExitCodeFilePath -Content "$($process.ExitCode)"

    return $process.ExitCode
}
