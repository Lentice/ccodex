# lib/FailureClassify.ps1
#
# Conservative, HINT-only failure classification (design doc: "Failure-mode
# handling amendment (2026-07-05)"). Never throws; every function degrades to
# $null on missing/unreadable/unparseable input. `failure_reason` is never
# stamped for a successful (exit 0) run.

function Get-CcodexCodexThreadId {
    # thread_id of the first `thread.started` event in the raw Codex JSONL
    # events log, so a job's status.json can carry it for both success and
    # failure (future `codex exec resume` integration + post-mortem debugging).
    param([string]$EventsPath)
    if ([string]::IsNullOrEmpty($EventsPath) -or -not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        return $null
    }
    try {
        $lines = Get-Content -LiteralPath $EventsPath -ErrorAction Stop
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $eventObj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if ($eventObj.type -eq 'thread.started' -and $eventObj.thread_id) {
            return [string]$eventObj.thread_id
        }
    }
    return $null
}

function Get-CcodexFailureReason {
    # Conservative signature match over the LAST 8KB of stderr.log plus any
    # event lines that literally contain "error" (case-insensitive). $null
    # whenever $CodexExitCode is 0 (never classify a successful run) or when
    # neither source carries a recognized signal. Precedence when multiple
    # signature classes are present: quota > auth > permission > network.
    param(
        [Nullable[int]]$CodexExitCode,
        [string]$StderrPath,
        [string]$EventsPath
    )
    if ($CodexExitCode -eq 0) { return $null }

    $signalText = ''

    if (-not [string]::IsNullOrEmpty($StderrPath) -and (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
        try {
            $maxBytes = 8192
            $bytes = [System.IO.File]::ReadAllBytes($StderrPath)
            if ($bytes.Length -gt $maxBytes) {
                $tail = New-Object byte[] $maxBytes
                [Array]::Copy($bytes, $bytes.Length - $maxBytes, $tail, 0, $maxBytes)
                $bytes = $tail
            }
            $signalText += [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            # unreadable stderr contributes no signal
        }
    }

    if (-not [string]::IsNullOrEmpty($EventsPath) -and (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        try {
            $lines = Get-Content -LiteralPath $EventsPath -ErrorAction Stop
            foreach ($line in $lines) {
                if ($line -match '(?i)error') {
                    $signalText += "`n$line"
                }
            }
        } catch {
            # unreadable/unparseable events contribute no additional signal
        }
    }

    if ([string]::IsNullOrEmpty($signalText)) { return $null }

    if ($signalText -match '(?i)usage limit|rate limit|quota|429') { return 'quota_or_rate_limit' }
    if ($signalText -match '(?i)login|auth|401|unauthorized|credential') { return 'auth' }
    if ($signalText -match '(?i)sandbox|denied|approval|permission') { return 'permission_or_sandbox' }
    if ($signalText -match '(?i)network|connection|dns|502|503') { return 'network' }
    return $null
}

function Get-CcodexFailureHintLine {
    # One short, actionable hint line per failure_reason, appended to a
    # failure Message so Claude can react without reading logs. $null for an
    # absent/unrecognized reason (no hint line is added).
    param([string]$FailureReason)
    switch ($FailureReason) {
        'quota_or_rate_limit' { return 'Codex usage/rate limit reached - report to the user; do not auto-retry.' }
        'auth' { return 'Codex auth problem - run: codex login' }
        'permission_or_sandbox' { return 'Sandbox/permission denial - consider --access workspace or narrow the task.' }
        'network' { return 'Transient network failure - one retry is safe.' }
        default { return $null }
    }
}
