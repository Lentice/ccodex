# tests/FailureClassify.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\FailureClassify.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-failureclassify-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-TestFile {
    param([string]$Name, [string]$Content)
    $path = Join-Path $tempRoot $Name
    Write-CcodexTextFile -Path $path -Content $Content
    return $path
}

# --- Get-CcodexCodexThreadId ---

Write-Host "Get-CcodexCodexThreadId: reads thread_id from the first thread.started event"
$eventsOk = New-TestFile 'events-ok.jsonl' "{`"type`":`"thread.started`",`"thread_id`":`"thread-abc-123`"}`n{`"type`":`"event`",`"msg`":`"other`"}"
Assert-Equal (Get-CcodexCodexThreadId -EventsPath $eventsOk) 'thread-abc-123' 'extracts thread_id from thread.started line'

Write-Host "Get-CcodexCodexThreadId: returns null when no thread.started event is present"
$eventsNoThread = New-TestFile 'events-no-thread.jsonl' "{`"type`":`"event`",`"msg`":`"fake-codex ran`"}"
Assert-Equal (Get-CcodexCodexThreadId -EventsPath $eventsNoThread) $null 'no thread.started event -> null'

Write-Host "Get-CcodexCodexThreadId: returns null when the events file is missing"
$missingEvents = Join-Path $tempRoot 'no-such-events.jsonl'
Assert-Equal (Get-CcodexCodexThreadId -EventsPath $missingEvents) $null 'missing events file -> null'

Write-Host "Get-CcodexCodexThreadId: returns null on unparseable/garbage content"
$eventsGarbage = New-TestFile 'events-garbage.jsonl' "not json at all`n{ also not json"
Assert-Equal (Get-CcodexCodexThreadId -EventsPath $eventsGarbage) $null 'unparseable events content -> null'

Write-Host "Get-CcodexCodexThreadId: returns null for an empty/null path"
Assert-Equal (Get-CcodexCodexThreadId -EventsPath $null) $null 'null path -> null'
Assert-Equal (Get-CcodexCodexThreadId -EventsPath '') $null 'empty path -> null'

# --- Get-CcodexFailureReason ---

Write-Host "Get-CcodexFailureReason: exit code 0 is never classified even with signal text present"
$stderrQuotaButSuccess = New-TestFile 'stderr-quota-success.log' 'usage limit reached, rate limit exceeded'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 0 -StderrPath $stderrQuotaButSuccess -EventsPath $null) $null 'exit code 0 never classified, regardless of stderr content'

Write-Host "Get-CcodexFailureReason: absent stderr/events paths -> null"
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath (Join-Path $tempRoot 'nope.log') -EventsPath (Join-Path $tempRoot 'nope.jsonl')) $null 'absent paths -> null'

Write-Host "Get-CcodexFailureReason: null exit code with absent paths -> null"
Assert-Equal (Get-CcodexFailureReason -CodexExitCode $null -StderrPath $null -EventsPath $null) $null 'null exit code + null paths -> null'

Write-Host "Get-CcodexFailureReason: nonzero exit + no matching signal -> null"
$stderrNoSignal = New-TestFile 'stderr-no-signal.log' 'some unrelated failure with no known signature'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrNoSignal -EventsPath $null) $null 'no recognizable signature -> null'

Write-Host "Get-CcodexFailureReason: quota signature classes"
foreach ($signal in @('usage limit reached', 'rate limit exceeded', 'quota exhausted')) {
    $p = New-TestFile "stderr-quota-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'quota_or_rate_limit' "quota signature '$signal' classifies as quota_or_rate_limit"
}

Write-Host "Get-CcodexFailureReason: auth signature classes"
foreach ($signal in @('please login again', 'HTTP 401 unauthorized', 'invalid credential')) {
    $p = New-TestFile "stderr-auth-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'auth' "auth signature '$signal' classifies as auth"
}

Write-Host "Get-CcodexFailureReason: permission signature classes"
foreach ($signal in @('sandbox violation', 'permission denied', 'approval required', 'access permission missing')) {
    $p = New-TestFile "stderr-perm-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'permission_or_sandbox' "permission signature '$signal' classifies as permission_or_sandbox"
}

Write-Host "Get-CcodexFailureReason: network signature classes"
foreach ($signal in @('network unreachable', 'connection reset', 'dns lookup failed')) {
    $p = New-TestFile "stderr-net-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'network' "network signature '$signal' classifies as network"
}

Write-Host "Get-CcodexFailureReason: dropped confidence:low bare-token signatures no longer classify (precision over recall)"
foreach ($case in @(
    @{ Text='HTTP 429 Too Many Requests';   Why='bare 429 (removed quota row)' },
    @{ Text='got 401';                        Why='bare 401 (removed auth row)' },
    @{ Text='auth token expired';             Why='bare auth token (removed auth row)' },
    @{ Text='HTTP 502 Bad Gateway';           Why='bare 502 (removed network row)' },
    @{ Text='HTTP 503 Service Unavailable';   Why='bare 503 (removed network row)' },
    @{ Text='reauthorize completed: request id 5021 502xx';  Why='bare tokens embedded in unrelated output must not classify' }
)) {
    $p = New-TestFile "stderr-droppedlow-$([Guid]::NewGuid().ToString('N')).log" $case.Text
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) $null "$($case.Why) -> no failure_reason"
    # The whole structured signal must be null, not merely its reason (contract: no classification).
    Assert-Equal (Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $p -EventsPath $null) $null "$($case.Why) -> no structured signal"
}

Write-Host "Get-CcodexFailureSignal: a removed bare token in an error-bearing EVENT line also yields no signal"
$eventsBare429 = New-TestFile 'events-bare-429.jsonl' '{"type":"error","msg":"upstream returned 429"}'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $null -EventsPath $eventsBare429) $null 'events-only bare 429 -> no failure_reason'
Assert-Equal (Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $null -EventsPath $eventsBare429) $null 'events-only bare 429 -> no structured signal'

Write-Host "Get-CcodexFailureReason: thread_expired signature classes"
foreach ($signal in @('session not found', 'thread not found', 'no session', 'conversation not found')) {
    $p = New-TestFile "stderr-threadexp-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'thread_expired' "thread_expired signature '$signal' classifies as thread_expired"
}

Write-Host "Get-CcodexFailureReason: thread_expired signature is case-insensitive"
$stderrThreadExpUpper = New-TestFile 'stderr-threadexp-upper.log' 'SESSION NOT FOUND'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrThreadExpUpper -EventsPath $null) 'thread_expired' 'thread_expired matching is case-insensitive'

Write-Host "Get-CcodexFailureReason: precedence - thread_expired beats quota when both present"
$stderrThreadExpAndQuota = New-TestFile 'stderr-threadexp-and-quota.log' 'rate limit exceeded; also session not found'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrThreadExpAndQuota -EventsPath $null) 'thread_expired' 'thread_expired takes precedence over quota'

Write-Host "Get-CcodexFailureReason: case-insensitive matching"
$stderrUpper = New-TestFile 'stderr-upper.log' 'RATE LIMIT EXCEEDED'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrUpper -EventsPath $null) 'quota_or_rate_limit' 'matching is case-insensitive'

Write-Host "Get-CcodexFailureReason: precedence - quota beats auth when both present"
$stderrBoth = New-TestFile 'stderr-quota-and-auth.log' 'auth login failed; also rate limit exceeded'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrBoth -EventsPath $null) 'quota_or_rate_limit' 'quota takes precedence over auth'

Write-Host "Get-CcodexFailureReason: precedence - auth beats permission when both present"
$stderrAuthPerm = New-TestFile 'stderr-auth-and-perm.log' 'sandbox denied; unauthorized 401'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrAuthPerm -EventsPath $null) 'auth' 'auth takes precedence over permission'

Write-Host "Get-CcodexFailureReason: precedence - permission beats network when both present"
$stderrPermNet = New-TestFile 'stderr-perm-and-net.log' 'network connection dropped; sandbox denied'
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrPermNet -EventsPath $null) 'permission_or_sandbox' 'permission takes precedence over network'

Write-Host "Get-CcodexFailureReason: matches an error-bearing event line when stderr has no signal"
$eventsError = New-TestFile 'events-error.jsonl' "{`"type`":`"error`",`"message`":`"Rate limit exceeded, please retry later`"}"
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $null -EventsPath $eventsError) 'quota_or_rate_limit' 'error-bearing event line contributes signal text'

Write-Host "Get-CcodexFailureReason: ignores event lines that do not contain 'error'"
$eventsNoErrorWord = New-TestFile 'events-no-error-word.jsonl' "{`"type`":`"info`",`"message`":`"quota update: nothing wrong here`"}"
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $null -EventsPath $eventsNoErrorWord) $null 'event lines without the literal "error" are not scanned for signatures'

Write-Host "Get-CcodexFailureReason: only scans the LAST 8KB of stderr.log"
$padding = 'x' * 8300
$stderrTailOnly = New-TestFile 'stderr-tail.log' ("rate limit exceeded" + $padding)
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrTailOnly -EventsPath $null) $null 'a signature outside the last 8KB is not matched'

$stderrTailMatch = New-TestFile 'stderr-tail-match.log' ($padding + "rate limit exceeded")
Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $stderrTailMatch -EventsPath $null) 'quota_or_rate_limit' 'a signature within the last 8KB is matched'

# Table-driven regression corpus: every legacy alternative, adjacent-class precedence,
# known-fragile substring behavior, and guards. Get-CcodexFailureSignal must agree exactly
# with the compatibility Get-CcodexFailureReason result for every input.
Write-Host "Get-CcodexFailureReason/Get-CcodexFailureSignal: full legacy regression corpus"
$legacyCorpus = @(
    @{ Name='session-not-found'; Text='session not found'; Exit=1; Expected='thread_expired' },
    @{ Name='thread-not-found'; Text='thread not found'; Exit=1; Expected='thread_expired' },
    @{ Name='no-session'; Text='no session'; Exit=1; Expected='thread_expired' },
    @{ Name='conversation-not-found'; Text='conversation not found'; Exit=1; Expected='thread_expired' },
    @{ Name='usage-limit'; Text="You've hit your usage limit"; Exit=1; Expected='quota_or_rate_limit' },
    @{ Name='rate-limit'; Text='rate limit exceeded'; Exit=1; Expected='quota_or_rate_limit' },
    @{ Name='quota'; Text='quota exhausted'; Exit=1; Expected='quota_or_rate_limit' },
    @{ Name='429-dropped'; Text='HTTP 429 Too Many Requests'; Exit=1; Expected=$null },
    @{ Name='login'; Text='please login again'; Exit=1; Expected='auth' },
    @{ Name='auth-token-dropped'; Text='auth token expired'; Exit=1; Expected=$null },
    @{ Name='401-dropped'; Text='got 401'; Exit=1; Expected=$null },
    @{ Name='unauthorized'; Text='stream error: unauthorized'; Exit=1; Expected='auth' },
    @{ Name='credential'; Text='credential rejected'; Exit=1; Expected='auth' },
    @{ Name='sandbox'; Text='sandbox blocked write'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='denied'; Text='write denied'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='approval'; Text='approval required'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='permission'; Text='permission missing'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='network'; Text='network unreachable'; Exit=1; Expected='network' },
    @{ Name='connection'; Text='connection reset'; Exit=1; Expected='network' },
    @{ Name='dns'; Text='dns lookup failed'; Exit=1; Expected='network' },
    @{ Name='502-dropped'; Text='HTTP 502 Bad Gateway'; Exit=1; Expected=$null },
    @{ Name='503-dropped'; Text='HTTP 503 Service Unavailable'; Exit=1; Expected=$null },
    @{ Name='precedence-thread-quota'; Text='session not found; quota exhausted'; Exit=1; Expected='thread_expired' },
    @{ Name='precedence-quota-auth'; Text='rate limit; login required'; Exit=1; Expected='quota_or_rate_limit' },
    @{ Name='precedence-auth-permission'; Text='login failed; sandbox denied'; Exit=1; Expected='auth' },
    @{ Name='precedence-permission-network'; Text='permission denied; network connection lost'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='fragile-429-substring-now-null'; Text='unrelated number 1429007'; Exit=1; Expected=$null },
    @{ Name='fragile-connection-denied'; Text='connection denied'; Exit=1; Expected='permission_or_sandbox' },
    @{ Name='exit-zero-guard'; Text='rate limit exceeded'; Exit=0; Expected=$null },
    @{ Name='null-exit-classifies'; Text='rate limit exceeded'; Exit=$null; Expected='quota_or_rate_limit' },
    @{ Name='no-signal'; Text='an unrelated failure'; Exit=1; Expected=$null }
)
foreach ($case in $legacyCorpus) {
    $casePath = New-TestFile "corpus-$($case.Name).log" $case.Text
    $reason = Get-CcodexFailureReason -CodexExitCode $case.Exit -StderrPath $casePath -EventsPath $null
    $signal = Get-CcodexFailureSignal -CodexExitCode $case.Exit -StderrPath $casePath -EventsPath $null
    Assert-Equal $reason $case.Expected "legacy corpus '$($case.Name)' keeps its failure_reason"
    $signalReason = if ($null -ne $signal) { $signal.reason } else { $null }
    Assert-Equal $signalReason $reason "structured signal agrees with failure_reason for '$($case.Name)'"
}
$missingCorpusPath = Join-Path $tempRoot 'corpus-missing.log'
$missingReason = Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $missingCorpusPath -EventsPath $null
$missingSignal = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $missingCorpusPath -EventsPath $null
Assert-Equal $missingReason $null 'missing corpus file keeps failure_reason null'
Assert-Equal $missingSignal $null 'missing corpus file keeps structured signal null'

Write-Host "Get-CcodexFailureSignal: ordered metadata, source, and http_code extraction"
$signalRatePath = New-TestFile 'signal-rate-stderr.log' 'rate limit exceeded'
$signalRate = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalRatePath -EventsPath $null
Assert-Equal $signalRate.matched_signal 'rate limit' 'stderr-only signal records the winning literal alternative'
Assert-Equal $signalRate.source 'stderr' 'stderr-only signal records source=stderr'
Assert-Equal $signalRate.confidence 'high' 'rate limit confidence is high'
Assert-Equal $signalRate.http_code $null 'rate limit without an HTTP code leaves http_code null'

$signalEventsPath = New-TestFile 'signal-events-only.jsonl' '{"type":"x","msg":"error: rate limit reached, http 429"}'
$signalEvents = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $null -EventsPath $signalEventsPath
Assert-Equal $signalEvents.reason 'quota_or_rate_limit' 'events-only rate-limit line classifies as quota'
Assert-Equal $signalEvents.matched_signal 'rate limit' 'events-only signal records the surviving phrase alternative'
Assert-Equal $signalEvents.source 'events' 'events-only signal records source=events'
Assert-Equal $signalEvents.http_code 429 'generic HTTP-code regex still extracts a contextual code for a surviving row'

$signalBothStderrPath = New-TestFile 'signal-both.log' 'rate limit in stderr'
$signalBothEventsPath = New-TestFile 'signal-both.jsonl' '{"type":"error","msg":"rate limit in events"}'
$signalBoth = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalBothStderrPath -EventsPath $signalBothEventsPath
Assert-Equal $signalBoth.source 'both' 'winning signal present in both streams records source=both'

$signalAlternativePath = New-TestFile 'signal-alternative-order.log' 'usage limit and rate limit'
$signalAlternative = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalAlternativePath -EventsPath $null
Assert-Equal $signalAlternative.matched_signal 'usage limit' 'first alternative in table order wins within a class'

$signalContextPath = New-TestFile 'signal-context-code.log' 'quota exceeded, status: 503'
$signalContext = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalContextPath -EventsPath $null
Assert-Equal $signalContext.reason 'quota_or_rate_limit' 'quota wins even when a network code is present'
Assert-Equal $signalContext.http_code 503 'contextual HTTP code beats the winning row static fallback'

# `unauthorized` (surviving high row) keeps its static 401 http_code fallback when no
# contextual code is present; a bare `401` with no surviving phrase now yields no signal.
$signalStaticPath = New-TestFile 'signal-static-code.log' 'stream error: unauthorized'
$signalStatic = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalStaticPath -EventsPath $null
Assert-Equal $signalStatic.reason 'auth' 'unauthorized classifies as auth'
Assert-Equal $signalStatic.matched_signal 'unauthorized' 'unauthorized selects the surviving auth row'
Assert-Equal $signalStatic.http_code 401 'unauthorized uses the table static 401 fallback when no contextual code is present'

$signalBare401Path = New-TestFile 'signal-bare-401.log' 'got 401'
Assert-Equal (Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalBare401Path -EventsPath $null) $null 'a bare 401 with no surviving phrase yields no signal'

$signalNoCodePath = New-TestFile 'signal-no-code.log' 'login failed'
$signalNoCode = Get-CcodexFailureSignal -CodexExitCode 1 -StderrPath $signalNoCodePath -EventsPath $null
Assert-Equal $signalNoCode.http_code $null 'login without an HTTP code leaves http_code null'

# --- Get-CcodexFailureHintLine ---

Write-Host "Get-CcodexFailureHintLine: thread_expired hint"
Assert-Equal (Get-CcodexFailureHintLine -FailureReason 'thread_expired') 'Codex session expired or was pruned - start a fresh ccodex run.' 'thread_expired hint line is exact'

# --- Get-CcodexStderrTail ---

Write-Host "Get-CcodexStderrTail: missing/empty path -> null"
Assert-Equal (Get-CcodexStderrTail -StderrPath $null) $null 'null path -> null'
Assert-Equal (Get-CcodexStderrTail -StderrPath '') $null 'empty path -> null'
Assert-Equal (Get-CcodexStderrTail -StderrPath (Join-Path $tempRoot 'no-such-stderr.log')) $null 'missing file -> null'

Write-Host "Get-CcodexStderrTail: whitespace-only stderr -> null"
$stderrBlank = New-TestFile 'stderr-blank.log' "`n   `n`t`n"
Assert-Equal (Get-CcodexStderrTail -StderrPath $stderrBlank) $null 'a file of only blank lines -> null'

Write-Host "Get-CcodexStderrTail: surfaces a single non-empty line indented four spaces"
$stderrTrusted = New-TestFile 'stderr-trusted.log' 'Not inside a trusted directory and --skip-git-repo-check was not specified.'
Assert-Equal (Get-CcodexStderrTail -StderrPath $stderrTrusted) '    Not inside a trusted directory and --skip-git-repo-check was not specified.' 'single line is indented four spaces'

Write-Host "Get-CcodexStderrTail: keeps only the last MaxLines non-empty lines and drops blanks"
$stderrMulti = New-TestFile 'stderr-multi.log' "line1`n`nline2`nline3"
Assert-Equal (Get-CcodexStderrTail -StderrPath $stderrMulti -MaxLines 2) "    line2`n    line3" 'returns the last two non-empty lines, blank lines dropped'

Write-Host "Get-CcodexStderrTail: reads only a bounded trailing window (early content is not read)"
$stderrHuge = New-TestFile 'stderr-huge.log' ("EARLY_MARKER`n" + ('x' * 9000) + "`nLATE_MARKER")
$hugeTail = Get-CcodexStderrTail -StderrPath $stderrHuge
Assert-True ($hugeTail -like '*LATE_MARKER*') 'a line at the very end is included'
Assert-True (-not ($hugeTail -like '*EARLY_MARKER*')) 'a line before the bounded trailing window is not read'

Write-Host "Get-CcodexStderrTail: negative MaxLines/MaxChars are clamped and never throw"
$stderrClamp = New-TestFile 'stderr-clamp.log' "a`nb`nc"
Assert-Equal (Get-CcodexStderrTail -StderrPath $stderrClamp -MaxLines -5 -MaxChars -10) '' 'negative bounds clamp to 0 -> empty string (no throw)'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
