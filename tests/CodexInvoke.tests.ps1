. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')

Write-Host "ConvertTo-CcodexWin32QuotedArgument"
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'plain') 'plain' 'no quoting needed for a plain argument'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a b') '"a b"' 'wraps an argument containing a space'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a"b') '"a\"b"' 'escapes an embedded quote'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument '') '""' 'empty argument becomes an empty quoted pair'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a&b') 'a&b' 'a cmd metacharacter alone does not trigger Win32 quoting'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument -Argument 'plain' -ForceQuote) '"plain"' '-ForceQuote quotes an otherwise-plain argument'

Write-Host "ConvertTo-CcodexCmdInnerArgument force-quotes cmd metacharacters"
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'plain') 'plain' 'plain argument is left bare for the cmd inner line'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'D:\A&B\repo') '"D:\A&B\repo"' 'ampersand (command separator) forces quoting'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'D:\A|B\repo') '"D:\A|B\repo"' 'pipe forces quoting'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'D:\A>B') '"D:\A>B"' 'redirection forces quoting'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'D:\A^B') '"D:\A^B"' 'caret (escape) forces quoting'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'D:\A%B') '"D:\A%B"' 'percent (var expansion) forces quoting'
Assert-Equal (ConvertTo-CcodexCmdInnerArgument 'a b') '"a b"' 'whitespace still triggers quoting via the Win32 path'

Write-Host "Get-CcodexProcessLaunchPlan for a .cmd target"
$plan = Get-CcodexProcessLaunchPlan -CodexPath 'C:\npm\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', '-C', 'D:\Repo With Space')
Assert-Equal $plan.FileName "$env:SystemRoot\System32\cmd.exe" '.cmd targets launch through cmd.exe'
Assert-Equal $plan.ArgumentList[0] '/d' 'first cmd.exe arg is /d'
Assert-Equal $plan.ArgumentList[1] '/s' 'second cmd.exe arg is /s'
Assert-Equal $plan.ArgumentList[2] '/c' 'third cmd.exe arg is /c'
Assert-True ($plan.ArgumentList[3] -like '*codex.cmd*') 'the wrapped command includes the codex.cmd path'
Assert-True ($plan.ArgumentList[3] -like '*"D:\Repo With Space"*') 'the wrapped command quotes the space-containing repo path'

Write-Host "Get-CcodexProcessLaunchPlan quotes cmd metacharacters in the wrapped command"
$planMeta = Get-CcodexProcessLaunchPlan -CodexPath 'C:\npm\codex.cmd' -Arguments @('-C', 'D:\A&B\repo')
Assert-True ($planMeta.ArgumentList[3] -like '*"D:\A&B\repo"*') 'a repo path containing & is quoted so cmd.exe cannot treat it as a command separator'
Assert-True (-not ($planMeta.ArgumentList[3] -like '*-C D:\A&B\repo*')) 'the & path is never left bare in the inner command line'

Write-Host "Get-CcodexProcessLaunchPlan for a non-.cmd target"
$plan2 = Get-CcodexProcessLaunchPlan -CodexPath 'C:\codex.exe' -Arguments @('exec')
Assert-Equal $plan2.FileName 'C:\codex.exe' 'non-.cmd targets launch directly'
Assert-Equal ($plan2.ArgumentList -join '|') 'exec' 'non-.cmd arguments pass through unchanged'

Write-Host "Invoke-CcodexCodexProcess against the fake-codex.ps1 fixture directly"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$eventsPath = Join-Path $tempRoot 'codex-events.jsonl'
$stderrPath = Join-Path $tempRoot 'stderr.log'
$exitCodeFilePath = Join-Path $tempRoot 'exit_code.txt'
$resultPath = Join-Path $tempRoot 'result.md'
$fixturePs1 = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'
$pwshPath = (Get-Command 'pwsh').Source

$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'hello from fake codex'
$exitCode = Invoke-CcodexCodexProcess -CodexPath $pwshPath -Arguments @('-NoProfile', '-File', $fixturePs1, '--output-last-message', $resultPath) -PromptContent 'the prompt' -EventsLogPath $eventsPath -StderrLogPath $stderrPath -ExitCodeFilePath $exitCodeFilePath
Assert-Equal $exitCode 0 'returns the fake process exit code'
Assert-True ((Get-Content -LiteralPath $eventsPath -Raw) -like '*fake-codex ran*') 'captures stdout into the events log'
Assert-True ((Get-Content -LiteralPath $stderrPath -Raw) -like '*fake-codex stderr line*') 'captures stderr into the stderr log'
Assert-Equal (Get-Content -LiteralPath $exitCodeFilePath -Raw) '0' 'writes the raw exit code to exit_code.txt'
Assert-Equal (Get-Content -LiteralPath $resultPath -Raw) 'hello from fake codex' 'the fixture wrote the expected result content'

Write-Host "Invoke-CcodexCodexProcess against the fake-codex.cmd fixture (exercises the cmd.exe wrapping path)"
$env:CCODEX_FAKE_EXIT_CODE = '7'
Remove-Item Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$resultPath2 = Join-Path $tempRoot 'result2.md'
$eventsPath2 = Join-Path $tempRoot 'codex-events2.jsonl'
$stderrPath2 = Join-Path $tempRoot 'stderr2.log'
$exitCodeFilePath2 = Join-Path $tempRoot 'exit_code2.txt'
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'
$exitCode2 = Invoke-CcodexCodexProcess -CodexPath $fixtureCmd -Arguments @('--output-last-message', $resultPath2) -PromptContent 'another prompt' -EventsLogPath $eventsPath2 -StderrLogPath $stderrPath2 -ExitCodeFilePath $exitCodeFilePath2
Assert-Equal $exitCode2 7 'nonzero exit code survives the cmd.exe wrapping path'
Assert-Equal (Get-Content -LiteralPath $exitCodeFilePath2 -Raw) '7' 'exit_code.txt reflects the wrapped process exit code'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE -ErrorAction SilentlyContinue

Write-Host "Invoke-CcodexCodexProcess hard timeout kills the process tree and returns the null sentinel"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$env:CCODEX_FAKE_DELAY_MS = '8000'
$timeoutRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-timeout-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $timeoutRoot -Force | Out-Null
$toEvents = Join-Path $timeoutRoot 'codex-events.jsonl'
$toStderr = Join-Path $timeoutRoot 'stderr.log'
$toExit = Join-Path $timeoutRoot 'exit_code.txt'
$toResult = Join-Path $timeoutRoot 'result.md'
$toPidFile = Join-Path $timeoutRoot 'fake.pid'
$env:CCODEX_FAKE_PIDFILE = $toPidFile

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$toExitCode = Invoke-CcodexCodexProcess -CodexPath $pwshPath -Arguments @('-NoProfile', '-File', $fixturePs1, '--output-last-message', $toResult) -PromptContent 'slow prompt' -EventsLogPath $toEvents -StderrLogPath $toStderr -ExitCodeFilePath $toExit -HardTimeoutMs 1500
$sw.Stop()
Assert-True ($null -eq $toExitCode) 'hard timeout returns the null (sentinel) exit code'
Assert-True ($sw.ElapsedMilliseconds -lt 6000) 'hard timeout returns well before the 8s fake delay would elapse'
Assert-True (-not (Test-Path -LiteralPath $toExit -PathType Leaf)) 'no exit_code.txt is written on hard timeout'
Assert-True (Test-Path -LiteralPath $toPidFile -PathType Leaf) 'the fixture recorded its pid before being killed'
$toChildPid = [int]((Get-Content -LiteralPath $toPidFile -Raw).Trim())
$toDeadline = (Get-Date).AddSeconds(5)
$toAlive = $true
while ((Get-Date) -lt $toDeadline) {
    if (-not (Get-Process -Id $toChildPid -ErrorAction SilentlyContinue)) { $toAlive = $false; break }
    Start-Sleep -Milliseconds 100
}
Assert-True (-not $toAlive) 'the fake-codex process tree was terminated by the hard timeout'

Remove-Item Env:\CCODEX_FAKE_PIDFILE, Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $timeoutRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Invoke-CcodexCodexProcess invokes the heartbeat scriptblock periodically during a long run"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$env:CCODEX_FAKE_DELAY_MS = '3000'
$hbRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-heartbeat-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $hbRoot -Force | Out-Null
$hbEvents = Join-Path $hbRoot 'codex-events.jsonl'
$hbStderr = Join-Path $hbRoot 'stderr.log'
$hbExit = Join-Path $hbRoot 'exit_code.txt'
$hbResult = Join-Path $hbRoot 'result.md'
# A closure-captured counter object survives regardless of which session state the
# scriptblock is invoked from inside Invoke-CcodexCodexProcess.
$hbCounter = [pscustomobject]@{ Count = 0 }
$hbBlock = { $hbCounter.Count++ }.GetNewClosure()
# HeartbeatEveryPasses=1 fires the block on every ~1s poll pass; a ~3s fake run yields
# at least two full passes (t=1s, t=2s) before the process exits.
$hbExitCode = Invoke-CcodexCodexProcess -CodexPath $pwshPath -Arguments @('-NoProfile', '-File', $fixturePs1, '--output-last-message', $hbResult) -PromptContent 'hb prompt' -EventsLogPath $hbEvents -StderrLogPath $hbStderr -ExitCodeFilePath $hbExit -OnHeartbeat $hbBlock -HeartbeatEveryPasses 1
Assert-Equal $hbExitCode 0 'heartbeat run returns the fake exit code'
Assert-True ($hbCounter.Count -ge 2) "heartbeat scriptblock invoked at least twice during the run (was $($hbCounter.Count))"
Remove-Item Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $hbRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Invoke-CcodexCodexProcess with a heartbeat that throws is best-effort (does not fail the run)"
$env:CCODEX_FAKE_DELAY_MS = '2500'
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'hb throw ok'
$hbThrowRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-hbthrow-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $hbThrowRoot -Force | Out-Null
$hbtEvents = Join-Path $hbThrowRoot 'codex-events.jsonl'
$hbtStderr = Join-Path $hbThrowRoot 'stderr.log'
$hbtExit = Join-Path $hbThrowRoot 'exit_code.txt'
$hbtResult = Join-Path $hbThrowRoot 'result.md'
$hbtBlock = { throw 'boom from heartbeat' }
$hbtExitCode = Invoke-CcodexCodexProcess -CodexPath $pwshPath -Arguments @('-NoProfile', '-File', $fixturePs1, '--output-last-message', $hbtResult) -PromptContent 'hbt prompt' -EventsLogPath $hbtEvents -StderrLogPath $hbtStderr -ExitCodeFilePath $hbtExit -OnHeartbeat $hbtBlock -HeartbeatEveryPasses 1
Assert-Equal $hbtExitCode 0 'a throwing heartbeat is swallowed; the run still returns the real exit code'
Assert-Equal (Get-Content -LiteralPath $hbtResult -Raw) 'hb throw ok' 'the run completed normally despite the throwing heartbeat'
Remove-Item Env:\CCODEX_FAKE_DELAY_MS, Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $hbThrowRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Invoke-CcodexCodexProcess streams stdout to codex-events.jsonl line-by-line while the process is still running"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_DELAY_MS -ErrorAction SilentlyContinue
$streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-codexinvoke-stream-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
$streamEvents = Join-Path $streamRoot 'codex-events.jsonl'
$streamStderr = Join-Path $streamRoot 'stderr.log'
$streamExit = Join-Path $streamRoot 'exit_code.txt'
$streamResult = Join-Path $streamRoot 'result.md'
$libStore = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')).Path
$libInvoke = (Resolve-Path (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')).Path

# A file-share-tolerant line counter: opens FileShare.ReadWrite exactly like
# Get-CcodexTailLines does, so it can read the events file WHILE the writer holds it.
$countLines = {
    param($path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        $text = $sr.ReadToEnd()
        $sr.Dispose()
    } finally { $fs.Dispose() }
    return (@($text -split "`n" | Where-Object { $_ -ne '' })).Count
}

# 5 streamed lines, 400ms apart (~2s) so a 100ms poll from this thread reliably
# catches an intermediate state. Run the (blocking) function in a background
# runspace and poll the events file for growth from here.
$env:CCODEX_FAKE_STREAM_LINES = '5'
$env:CCODEX_FAKE_STREAM_DELAY_MS = '400'
$streamPs = [powershell]::Create()
[void]$streamPs.AddScript({
    param($ls, $li, $codex, $fixture, $events, $stderr, $exit, $result)
    . $ls
    . $li
    Invoke-CcodexCodexProcess -CodexPath $codex -Arguments @('-NoProfile', '-File', $fixture, '--output-last-message', $result) -PromptContent 'stream prompt' -EventsLogPath $events -StderrLogPath $stderr -ExitCodeFilePath $exit
}).AddParameters(@{ ls = $libStore; li = $libInvoke; codex = $pwshPath; fixture = $fixturePs1; events = $streamEvents; stderr = $streamStderr; exit = $streamExit; result = $streamResult }) | Out-Null
$streamHandle = $streamPs.BeginInvoke()
$sawPartial = $false
$streamPollDeadline = (Get-Date).AddSeconds(20)
while (-not $streamHandle.IsCompleted -and (Get-Date) -lt $streamPollDeadline) {
    $n = & $countLines $streamEvents
    if ($n -ge 1 -and $n -lt 6) { $sawPartial = $true }
    Start-Sleep -Milliseconds 100
}
if (-not $streamHandle.IsCompleted) {
    # The poll deadline elapsed with the runspace still running. A blocking EndInvoke here would
    # hang the whole suite on a stdout-reader/process regression instead of surfacing it. Stop the
    # runspace and record a failure, then continue so the remaining assertions report too.
    try { [void]$streamPs.Stop() } catch { }
    $streamPs.Dispose()
    Assert-True $false 'streaming run completed within the 20s poll deadline (did not hang)'
    $streamExitCode = $null
} else {
    $streamOutput = $streamPs.EndInvoke($streamHandle)
    $streamPs.Dispose()
    $streamExitCode = @($streamOutput)[-1]
}
Remove-Item Env:\CCODEX_FAKE_STREAM_LINES, Env:\CCODEX_FAKE_STREAM_DELAY_MS -ErrorAction SilentlyContinue

Assert-Equal $streamExitCode 0 'streaming run returns the fake exit code'
Assert-True $sawPartial 'codex-events.jsonl grew incrementally while codex was still running (>=1 and <all lines observed mid-run)'
$streamFinal = Get-Content -LiteralPath $streamEvents -Raw
Assert-True ($streamFinal -like '*"seq":0*') 'the first streamed event line was captured'
Assert-True ($streamFinal -like '*"seq":4*') 'the last streamed event line was captured'
Assert-True ($streamFinal -like '*fake-codex ran*') 'the trailing (post-stream) event line was captured'
Assert-Equal (& $countLines $streamEvents) 6 'all 5 streamed lines plus the trailing event line are present at the end'
Assert-Equal (Get-Content -LiteralPath $streamExit -Raw) '0' 'exit_code.txt is written on normal completion of a streaming run'
Remove-Item -LiteralPath $streamRoot -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
