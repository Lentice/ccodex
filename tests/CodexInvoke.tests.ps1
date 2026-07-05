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
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
