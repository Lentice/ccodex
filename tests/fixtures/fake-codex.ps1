param()
$null = [Console]::In.ReadToEnd()
$argsList = $args
$resultPath = $null
for ($i = 0; $i -lt $argsList.Count; $i++) {
    if ($argsList[$i] -eq '--output-last-message' -and ($i + 1) -lt $argsList.Count) {
        $resultPath = $argsList[$i + 1]
    }
}
# Record this process's own PID (before any delay) so hard-timeout tests can poll
# for the process tree being killed. Opt-in via CCODEX_FAKE_PIDFILE; absent = no-op.
if ($env:CCODEX_FAKE_PIDFILE) {
    [System.IO.File]::WriteAllText($env:CCODEX_FAKE_PIDFILE, "$PID", (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:CCODEX_FAKE_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:CCODEX_FAKE_DELAY_MS) }
Write-Output '{"type":"event","msg":"fake-codex ran"}'
if ($env:CCODEX_FAKE_STDERR) {
    [Console]::Error.WriteLine($env:CCODEX_FAKE_STDERR)
} else {
    [Console]::Error.WriteLine('fake-codex stderr line')
}
$exitCode = 0
if ($env:CCODEX_FAKE_EXIT_CODE) { $exitCode = [int]$env:CCODEX_FAKE_EXIT_CODE }
$resultText = if ($env:CCODEX_FAKE_RESULT) { $env:CCODEX_FAKE_RESULT } else { 'FAKE_RESULT_OK' }
if ($resultPath -and $exitCode -eq 0 -and $env:CCODEX_FAKE_SKIP_RESULT -ne '1') {
    [System.IO.File]::WriteAllText($resultPath, $resultText, (New-Object System.Text.UTF8Encoding($false)))
}
exit $exitCode
