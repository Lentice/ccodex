param()
$null = [Console]::In.ReadToEnd()
$argsList = $args

# Task 8 (doctor): the doctor command probes plain `codex --version` and
# `codex doctor` argv (no `exec`, no --output-last-message) in addition to the
# normal exec-mode invocation handled below. Both are answered from env vars so
# tests can simulate ok/FAIL outcomes without a second fixture. Purely additive:
# any other argv (e.g. the existing `--ask-for-approval never exec ...` shape)
# falls through unchanged to the exec-mode behavior beneath.
if ($argsList.Count -ge 1 -and $argsList[0] -eq '--version') {
    # Optional hang for doctor probe-timeout tests (additive; no-op when unset).
    if ($env:CCODEX_FAKE_VERSION_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:CCODEX_FAKE_VERSION_DELAY_MS) }
    $versionText = if ($env:CCODEX_FAKE_VERSION) { $env:CCODEX_FAKE_VERSION } else { 'codex-cli 0.0.0-fake' }
    Write-Output $versionText
    $exitCode = 0
    if ($env:CCODEX_FAKE_VERSION_EXIT) { $exitCode = [int]$env:CCODEX_FAKE_VERSION_EXIT }
    exit $exitCode
}

if ($argsList.Count -ge 1 -and $argsList[0] -eq 'doctor') {
    # Optional hang for doctor probe-timeout tests (additive; no-op when unset).
    if ($env:CCODEX_FAKE_DOCTOR_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:CCODEX_FAKE_DOCTOR_DELAY_MS) }
    $doctorText = if ($env:CCODEX_FAKE_DOCTOR_OUTPUT) { $env:CCODEX_FAKE_DOCTOR_OUTPUT } else { "codex doctor: all checks passed" }
    Write-Output $doctorText
    $exitCode = 0
    if ($env:CCODEX_FAKE_DOCTOR_EXIT) { $exitCode = [int]$env:CCODEX_FAKE_DOCTOR_EXIT }
    exit $exitCode
}

$resultPath = $null
# Phase 4 Task 3: parse the working-directory flag Codex is invoked with (`-C <dir>`) so a
# worktree run can be simulated writing a file INTO the worktree the wrapper created. Purely
# additive — every existing knob/behavior below is untouched when the write env vars are unset.
$workDir = $null
for ($i = 0; $i -lt $argsList.Count; $i++) {
    if ($argsList[$i] -eq '--output-last-message' -and ($i + 1) -lt $argsList.Count) {
        $resultPath = $argsList[$i + 1]
    }
    if ($argsList[$i] -eq '-C' -and ($i + 1) -lt $argsList.Count) {
        $workDir = $argsList[$i + 1]
    }
}
# Record this process's own PID (before any delay) so hard-timeout tests can poll
# for the process tree being killed. Opt-in via CCODEX_FAKE_PIDFILE; absent = no-op.
if ($env:CCODEX_FAKE_PIDFILE) {
    [System.IO.File]::WriteAllText($env:CCODEX_FAKE_PIDFILE, "$PID", (New-Object System.Text.UTF8Encoding($false)))
}
if ($env:CCODEX_FAKE_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:CCODEX_FAKE_DELAY_MS) }
# Phase 4 Task 3: simulate a worker file edit inside the working directory (`-C <dir>`),
# opt-in via CCODEX_FAKE_WRITE_FILE (relative path). Additive: absent env var = no-op.
if ($env:CCODEX_FAKE_WRITE_FILE -and $workDir) {
    $writeText = if ($env:CCODEX_FAKE_WRITE_TEXT) { $env:CCODEX_FAKE_WRITE_TEXT } else { 'fake-codex worker change' }
    $writeTarget = Join-Path $workDir $env:CCODEX_FAKE_WRITE_FILE
    $writeTargetDir = Split-Path -Parent $writeTarget
    if ($writeTargetDir -and -not (Test-Path -LiteralPath $writeTargetDir)) {
        New-Item -ItemType Directory -Path $writeTargetDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($writeTarget, $writeText, (New-Object System.Text.UTF8Encoding($false)))
}
# Phase 5 (resume): optionally emit a thread.started event so the wrapper can capture a
# codex_thread_id for the job (Get-CcodexCodexThreadId reads the first thread.started line).
# Opt-in via CCODEX_FAKE_THREAD_ID; additive — absent env var = no thread event emitted.
if ($env:CCODEX_FAKE_THREAD_ID) {
    Write-Output "{`"type`":`"thread.started`",`"thread_id`":`"$($env:CCODEX_FAKE_THREAD_ID)`"}"
}
# Progress-streaming support: emit N JSONL lines over time so a test can observe
# codex-events.jsonl growing WHILE the process is still running (real codex
# `exec --json` streams events line-by-line). Written straight to the redirected
# stdout with an explicit flush after each line so nothing is buffered until exit;
# CCODEX_FAKE_STREAM_DELAY_MS spaces the lines out. Additive: absent env var = no-op.
if ($env:CCODEX_FAKE_STREAM_LINES) {
    $streamCount = [int]$env:CCODEX_FAKE_STREAM_LINES
    $streamDelay = if ($env:CCODEX_FAKE_STREAM_DELAY_MS) { [int]$env:CCODEX_FAKE_STREAM_DELAY_MS } else { 0 }
    for ($s = 0; $s -lt $streamCount; $s++) {
        [Console]::Out.WriteLine("{`"type`":`"item.completed`",`"seq`":$s}")
        [Console]::Out.Flush()
        if ($streamDelay -gt 0) { Start-Sleep -Milliseconds $streamDelay }
    }
}
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
