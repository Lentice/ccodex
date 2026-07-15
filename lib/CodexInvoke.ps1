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
    # A literal double-quote cannot be carried safely through the `cmd /d /s /c "<inner>"`
    # double-parse: the Win32/MSVCRT `\"` escaping ConvertTo-CcodexWin32QuotedArgument emits is
    # NOT honored by cmd.exe's own tokenizer, so an embedded quote lets cmd.exe close the quoted
    # region early and treat a following `&`/`|`/`<`/`>` as a command separator/redirection
    # (CVE-2024-24576 class). Windows paths can never contain a quote, but an
    # attacker-influenced value routed through here on the SYNC `run` path (e.g. `--model`) could,
    # and unlike the detached-worker launch it has no earlier guard. Reject it loudly rather than
    # emit a command line cmd.exe would mis-split. Mirrors lib/Detach.ps1's identical guard.
    if ($Argument.Contains('"')) {
        throw "ccodex: refusing to pass an argument containing a double-quote through cmd.exe (unsafe under the cmd.exe/MSVCRT double-parse): $Argument"
    }
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
        [int]$HardTimeoutMs = 0,
        # Best-effort periodic callback (the native worker uses it to refresh
        # last_heartbeat_at in status.json). Invoked from the wait loop every
        # $HeartbeatEveryPasses ~1s passes; exceptions are swallowed so a failing
        # heartbeat can never derail the run. $null (the default, used by `run`)
        # disables it entirely.
        [scriptblock]$OnHeartbeat = $null,
        [int]$HeartbeatEveryPasses = 30
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
    # Never allocate a console window for the codex child: when the parent has no visible
    # console (hidden detached worker) a console app would otherwise pop one up.
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    # Everything below runs with the codex child ALREADY launched. If any post-launch setup
    # (the stdin write, opening the events log, arming the async readers) or the wait loop
    # throws, the catch kills the whole process tree so a half-started codex can never keep
    # running — and, under workspace/worktree access, keep mutating files — after the wrapper
    # has bailed out. The events writer is created inside the try (a failure opening it must
    # still trigger the kill), so it starts $null and the finally only disposes it once it exists.
    $eventsWriter = $null
    try {
        $process.StandardInput.Write($PromptContent)
        $process.StandardInput.Close()

        # codex `exec --json` streams JSONL events line-by-line in real time, so stdout is
        # consumed with a line reader that appends each event to codex-events.jsonl AS IT
        # ARRIVES (single writer, this thread) instead of buffering the whole stream until
        # exit. That is what makes `ccodex tail` show live progress during a multi-minute run.
        # The writer is opened up-front (FileShare.ReadWrite so a concurrent Get-CcodexTailLines
        # reader is never blocked) which also creates the (possibly empty) events file
        # immediately — a hard-timeout kill that lands before Codex emits a line still leaves
        # the artifact on disk. NewLine is forced to LF and the file is UTF-8 without BOM to
        # match the raw codex JSONL every downstream parser (Get-CcodexCodexThreadId, tail)
        # expects; AutoFlush guarantees each line hits disk for the tail reader immediately.
        # stderr is NOT line-streamed: it stays a concurrent ReadToEndAsync drain (prevents a
        # pipe-buffer deadlock) written once at the end, exactly as before.
        $utf8NoBom2 = New-Object System.Text.UTF8Encoding($false)
        $eventsStream = [System.IO.File]::Open($EventsLogPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $eventsWriter = New-Object System.IO.StreamWriter($eventsStream, $utf8NoBom2)
        $eventsWriter.NewLine = "`n"
        $eventsWriter.AutoFlush = $true

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdoutEof = $false
        $pendingLine = $process.StandardOutput.ReadLineAsync()

        # Single 1s-granularity poll loop that carries THREE responsibilities:
        #   * drain every stdout line that has arrived so far (append + flush), always
        #     re-arming the next ReadLineAsync immediately so stdout back-pressure can
        #     never build up and stall Codex.
        #   * the job-level hard timeout ($HardTimeoutMs): once the deadline passes and
        #     Codex still has not exited, kill the tree and return the $null sentinel.
        #   * the periodic worker heartbeat: every $HeartbeatEveryPasses passes, invoke
        #     $OnHeartbeat best-effort (swallow any exception).
        # WaitForExit(1000) blocks up to a second, so the loop wakes ~once per second
        # regardless of whether a heartbeat or timeout is configured. IsCompleted is a
        # non-blocking check ($null result == EOF; '' is a legitimate empty line).
        $hardDeadline = if ($HardTimeoutMs -gt 0) { [DateTime]::UtcNow.AddMilliseconds($HardTimeoutMs) } else { $null }
        $passCount = 0
        while (-not $process.WaitForExit(1000)) {
            while (-not $stdoutEof -and $pendingLine.IsCompleted) {
                $line = $pendingLine.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdoutEof = $true; break }
                $eventsWriter.WriteLine($line)
                $pendingLine = $process.StandardOutput.ReadLineAsync()
            }
            $passCount++
            if ($null -ne $OnHeartbeat -and $HeartbeatEveryPasses -gt 0 -and ($passCount % $HeartbeatEveryPasses) -eq 0) {
                try { & $OnHeartbeat } catch { }
            }
            if ($null -ne $hardDeadline -and [DateTime]::UtcNow -ge $hardDeadline) {
                # Budget exceeded and Codex has not exited: kill the whole tree, then
                # drain whatever stdout/stderr is already buffered — but only for a short
                # grace window. A surviving grandchild can keep the pipe open past the
                # kill, so an unbounded await could hang; each drain is bounded and the
                # streams are force-disposed so the timeout can never be masked.
                Stop-CcodexProcessTree -ProcessId $process.Id
                try { $process.WaitForExit() } catch { }
                $graceDeadline = [DateTime]::UtcNow.AddSeconds(2)
                while (-not $stdoutEof -and [DateTime]::UtcNow -lt $graceDeadline) {
                    try {
                        if ($pendingLine.Wait(100)) {
                            $line = $pendingLine.GetAwaiter().GetResult()
                            if ($null -eq $line) { $stdoutEof = $true; break }
                            $eventsWriter.WriteLine($line)
                            $pendingLine = $process.StandardOutput.ReadLineAsync()
                        } else { break }
                    } catch { break }
                }
                $partialStderr = ''
                try { if ($stderrTask.Wait(2000)) { $partialStderr = $stderrTask.GetAwaiter().GetResult() } } catch { $partialStderr = '' }
                try { $process.StandardOutput.Close() } catch { }
                try { $process.StandardError.Close() } catch { }
                Write-CcodexTextFile -Path $StderrLogPath -Content $partialStderr
                # NOTE: no exit_code.txt on a hard-timeout kill (Codex never exited);
                # the events already streamed to disk are preserved (writer closed below).
                return $null
            }
        }

        # WaitForExit() (parameterless) after a WaitForExit(timeout) that returned true
        # guarantees the process is fully reaped and its pipes closed, so the remaining
        # ReadLineAsync calls resolve promptly (trailing lines, then $null at EOF).
        $process.WaitForExit()
        while (-not $stdoutEof) {
            $line = $pendingLine.GetAwaiter().GetResult()
            if ($null -eq $line) { $stdoutEof = $true; break }
            $eventsWriter.WriteLine($line)
            $pendingLine = $process.StandardOutput.ReadLineAsync()
        }

        $stderr = $stderrTask.GetAwaiter().GetResult()
        Write-CcodexTextFile -Path $StderrLogPath -Content $stderr
        Write-CcodexTextFile -Path $ExitCodeFilePath -Content "$($process.ExitCode)"

        return $process.ExitCode
    } catch {
        # Post-launch setup or the wait loop threw: kill the whole codex process tree so a
        # child launched at $process.Start() above cannot outlive the wrapper's failure (and,
        # under workspace/worktree access, keep mutating files). Best-effort, then rethrow the
        # original error for the caller to record as a wrapper-internal failure.
        try { Stop-CcodexProcessTree -ProcessId $process.Id } catch { }
        throw
    } finally {
        # Always dispose the events writer (and its underlying stream) so no partial run
        # ever leaks a file handle — normal exit, hard timeout, or an unexpected throw.
        if ($null -ne $eventsWriter) { try { $eventsWriter.Dispose() } catch { } }
    }
}
