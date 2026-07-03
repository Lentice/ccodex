function ConvertTo-CcodexWin32QuotedArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

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

function Get-CcodexProcessLaunchPlan {
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $extension = [System.IO.Path]::GetExtension($CodexPath).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $quotedParts = @($CodexPath) + $Arguments | ForEach-Object { ConvertTo-CcodexWin32QuotedArgument $_ }
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

function Invoke-CcodexCodexProcess {
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptContent,
        [Parameter(Mandatory)][string]$EventsLogPath,
        [Parameter(Mandatory)][string]$StderrLogPath,
        [Parameter(Mandatory)][string]$ExitCodeFilePath
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
    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    Write-CcodexTextFile -Path $EventsLogPath -Content $stdout
    Write-CcodexTextFile -Path $StderrLogPath -Content $stderr
    Write-CcodexTextFile -Path $ExitCodeFilePath -Content "$($process.ExitCode)"

    return $process.ExitCode
}
