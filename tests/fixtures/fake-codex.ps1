param()
$null = [Console]::In.ReadToEnd()
$argsList = $args
$resultPath = $null
for ($i = 0; $i -lt $argsList.Count; $i++) {
    if ($argsList[$i] -eq '--output-last-message' -and ($i + 1) -lt $argsList.Count) {
        $resultPath = $argsList[$i + 1]
    }
}
Write-Output '{"type":"event","msg":"fake-codex ran"}'
[Console]::Error.WriteLine('fake-codex stderr line')
$exitCode = 0
if ($env:CCODEX_FAKE_EXIT_CODE) { $exitCode = [int]$env:CCODEX_FAKE_EXIT_CODE }
$resultText = if ($env:CCODEX_FAKE_RESULT) { $env:CCODEX_FAKE_RESULT } else { 'FAKE_RESULT_OK' }
if ($resultPath -and $exitCode -eq 0 -and $env:CCODEX_FAKE_SKIP_RESULT -ne '1') {
    [System.IO.File]::WriteAllText($resultPath, $resultText, (New-Object System.Text.UTF8Encoding($false)))
}
exit $exitCode
