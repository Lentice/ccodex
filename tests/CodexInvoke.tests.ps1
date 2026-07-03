. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')

Write-Host "ConvertTo-CcodexWin32QuotedArgument"
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'plain') 'plain' 'no quoting needed for a plain argument'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a b') '"a b"' 'wraps an argument containing a space'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument 'a"b') '"a\"b"' 'escapes an embedded quote'
Assert-Equal (ConvertTo-CcodexWin32QuotedArgument '') '""' 'empty argument becomes an empty quoted pair'

Write-Host "Get-CcodexProcessLaunchPlan for a .cmd target"
$plan = Get-CcodexProcessLaunchPlan -CodexPath 'C:\npm\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', '-C', 'D:\Repo With Space')
Assert-Equal $plan.FileName "$env:SystemRoot\System32\cmd.exe" '.cmd targets launch through cmd.exe'
Assert-Equal $plan.ArgumentList[0] '/d' 'first cmd.exe arg is /d'
Assert-Equal $plan.ArgumentList[1] '/s' 'second cmd.exe arg is /s'
Assert-Equal $plan.ArgumentList[2] '/c' 'third cmd.exe arg is /c'
Assert-True ($plan.ArgumentList[3] -like '*codex.cmd*') 'the wrapped command includes the codex.cmd path'
Assert-True ($plan.ArgumentList[3] -like '*"D:\Repo With Space"*') 'the wrapped command quotes the space-containing repo path'

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
Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
