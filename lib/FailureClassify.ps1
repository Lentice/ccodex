# lib/FailureClassify.ps1
#
# Conservative, HINT-only failure classification (design doc: "Failure-mode
# handling amendment (2026-07-05)"). Never throws; every function degrades to
# $null on missing/unreadable/unparseable input. `failure_reason` is never
# stamped for a successful (exit 0) run.

# Ordered signal table. Order IS precedence: first row whose literal pattern matches wins.
# Class order and alternative order reproduce the legacy class-level alternation regexes.
$script:CcodexFailureSignals = @(
    [pscustomobject]@{ Class='thread_expired';        Pattern='session not found';      Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='thread_expired';        Pattern='thread not found';       Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='thread_expired';        Pattern='no session';             Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='thread_expired';        Pattern='conversation not found'; Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='quota_or_rate_limit';   Pattern='usage limit';            Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='quota_or_rate_limit';   Pattern='rate limit';             Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='quota_or_rate_limit';   Pattern='quota';                  Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='quota_or_rate_limit';   Pattern='429';                    Confidence='low';    HttpCode=429 },
    [pscustomobject]@{ Class='auth';                  Pattern='login';                  Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='auth';                  Pattern='auth';                   Confidence='low';    HttpCode=$null },
    [pscustomobject]@{ Class='auth';                  Pattern='401';                    Confidence='low';    HttpCode=401 },
    [pscustomobject]@{ Class='auth';                  Pattern='unauthorized';           Confidence='high';   HttpCode=401 },
    [pscustomobject]@{ Class='auth';                  Pattern='credential';             Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='permission_or_sandbox'; Pattern='sandbox';                Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='permission_or_sandbox'; Pattern='denied';                 Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='permission_or_sandbox'; Pattern='approval';               Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='permission_or_sandbox'; Pattern='permission';             Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='network';               Pattern='network';                Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='network';               Pattern='connection';             Confidence='medium'; HttpCode=$null },
    [pscustomobject]@{ Class='network';               Pattern='dns';                    Confidence='high';   HttpCode=$null },
    [pscustomobject]@{ Class='network';               Pattern='502';                    Confidence='low';    HttpCode=502 },
    [pscustomobject]@{ Class='network';               Pattern='503';                    Confidence='low';    HttpCode=503 }
)

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

function Get-CcodexFailureSignal {
    # Conservative signature match over the LAST 8KB of stderr.log plus any
    # event lines that literally contain "error" (case-insensitive). $null
    # whenever $CodexExitCode is 0 (never classify a successful run) or when
    # neither source carries a recognized signal. Precedence when multiple
    # signature classes are present: thread_expired > quota > auth > permission > network.
    param(
        [Nullable[int]]$CodexExitCode,
        [string]$StderrPath,
        [string]$EventsPath
    )
    try {
        if ($CodexExitCode -eq 0) { return $null }

        $stderrText = ''
        $eventsText = ''

        try {
            if (-not [string]::IsNullOrEmpty($StderrPath) -and (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
                $maxBytes = 8192
                $bytes = [System.IO.File]::ReadAllBytes($StderrPath)
                if ($bytes.Length -gt $maxBytes) {
                    $tail = New-Object byte[] $maxBytes
                    [Array]::Copy($bytes, $bytes.Length - $maxBytes, $tail, 0, $maxBytes)
                    $bytes = $tail
                }
                $stderrText = [System.Text.Encoding]::UTF8.GetString($bytes)
            }
        } catch {
            # unreadable stderr contributes no signal; events remain independently usable
        }

        try {
            if (-not [string]::IsNullOrEmpty($EventsPath) -and (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
                $matchingEventLines = New-Object System.Collections.Generic.List[string]
                $lines = Get-Content -LiteralPath $EventsPath -ErrorAction Stop
                foreach ($line in $lines) {
                    if ($line -match '(?i)error') {
                        $matchingEventLines.Add($line)
                    }
                }
                $eventsText = [string]::Join("`n", $matchingEventLines)
            }
        } catch {
            # unreadable events contribute no signal; stderr remains independently usable
        }

        if ([string]::IsNullOrEmpty($stderrText) -and [string]::IsNullOrEmpty($eventsText)) { return $null }

        # Keep the legacy pooled-text shape: stderr, then one newline, then filtered events.
        $signalText = $stderrText + "`n" + $eventsText
        foreach ($row in $script:CcodexFailureSignals) {
            $pattern = '(?i)' + [regex]::Escape([string]$row.Pattern)
            if ($signalText -notmatch $pattern) { continue }

            $stderrMatched = $stderrText -match $pattern
            $eventsMatched = $eventsText -match $pattern
            $source = if ($stderrMatched -and $eventsMatched) {
                'both'
            } elseif ($stderrMatched) {
                'stderr'
            } else {
                'events'
            }

            $httpSourceText = if ($source -eq 'both') {
                $stderrText + "`n" + $eventsText
            } elseif ($source -eq 'stderr') {
                $stderrText
            } else {
                $eventsText
            }
            $httpCode = $null
            $httpMatch = [regex]::Match(
                $httpSourceText,
                '(?i)\b(?:http|status(?:\s+code)?|error)[\s:=]{0,3}(4\d\d|5\d\d)\b'
            )
            if ($httpMatch.Success) {
                $httpCode = [int]$httpMatch.Groups[1].Value
            } elseif ($null -ne $row.HttpCode) {
                $httpCode = [int]$row.HttpCode
            }

            return [ordered]@{
                reason         = [string]$row.Class
                matched_signal = [string]$row.Pattern
                source         = $source
                confidence     = [string]$row.Confidence
                http_code      = $httpCode
            }
        }
        return $null
    } catch {
        return $null
    }
}

function Get-CcodexFailureReason {
    # Compatibility wrapper: the existing string-or-null contract remains unchanged.
    param(
        [Nullable[int]]$CodexExitCode,
        [string]$StderrPath,
        [string]$EventsPath
    )
    $signal = Get-CcodexFailureSignal @PSBoundParameters
    if ($signal) { return $signal.reason }
    return $null
}

function Get-CcodexStderrTail {
    # Best-effort: the last few non-empty lines of stderr.log, indented for inclusion in a
    # failure Message. Used ONLY when Get-CcodexFailureReason returned no recognized signature
    # (so there is no Get-CcodexFailureHintLine to show) — it surfaces the actual cause (e.g.
    # "Not inside a trusted directory and --skip-git-repo-check was not specified.") in the CLI
    # output instead of leaving it buried in stderr.log for a manual dive. Returns $null on a
    # missing/unreadable/empty stderr so the caller adds nothing. Never throws.
    param(
        [string]$StderrPath,
        [int]$MaxLines = 8,
        [int]$MaxChars = 1200
    )
    if ([string]::IsNullOrEmpty($StderrPath) -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
        return $null
    }
    # Clamp to non-negative so a hostile/typo'd caller value can never make the selection or
    # truncation below throw (honours the module's "never throws" contract).
    if ($MaxLines -lt 0) { $MaxLines = 0 }
    if ($MaxChars -lt 0) { $MaxChars = 0 }
    try {
        # Read only a bounded trailing window (same pattern as Get-CcodexFailureReason) instead of
        # loading the whole log: a large failed-job stderr must not make diagnostic reporting
        # memory- or latency-heavy. The window is sized generously above MaxChars so line
        # selection still has enough material after decoding.
        $maxBytes = [Math]::Max(8192, $MaxChars * 4)
        $bytes = [System.IO.File]::ReadAllBytes($StderrPath)
        if ($bytes.Length -gt $maxBytes) {
            $tailBytes = New-Object byte[] $maxBytes
            [Array]::Copy($bytes, $bytes.Length - $maxBytes, $tailBytes, 0, $maxBytes)
            $bytes = $tailBytes
        }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return $null
    }
    $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $null }
    $tail = @($lines | Select-Object -Last $MaxLines)
    $joined = ($tail | ForEach-Object { "    $($_.TrimEnd())" }) -join "`n"
    if ($joined.Length -gt $MaxChars) {
        $joined = '    ...' + "`n" + $joined.Substring($joined.Length - $MaxChars)
    }
    return $joined
}

function Get-CcodexFailureHintLine {
    # One short, actionable hint line per failure_reason, appended to a
    # failure Message so Claude can react without reading logs. $null for an
    # absent/unrecognized reason (no hint line is added).
    param([string]$FailureReason)
    switch ($FailureReason) {
        'thread_expired' { return 'Codex session expired or was pruned - start a fresh ccodex run.' }
        'quota_or_rate_limit' { return 'Codex usage/rate limit reached - report to the user; do not auto-retry.' }
        'auth' { return 'Codex auth problem - run: codex login' }
        'permission_or_sandbox' { return 'Sandbox/permission denial - consider --access workspace or narrow the task.' }
        'network' { return 'Transient network failure - one retry is safe.' }
        default { return $null }
    }
}
