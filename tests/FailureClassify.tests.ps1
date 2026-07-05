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
foreach ($signal in @('usage limit reached', 'rate limit exceeded', 'quota exhausted', 'HTTP 429 received')) {
    $p = New-TestFile "stderr-quota-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'quota_or_rate_limit' "quota signature '$signal' classifies as quota_or_rate_limit"
}

Write-Host "Get-CcodexFailureReason: auth signature classes"
foreach ($signal in @('please login again', 'auth token expired', 'HTTP 401 unauthorized', 'invalid credential')) {
    $p = New-TestFile "stderr-auth-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'auth' "auth signature '$signal' classifies as auth"
}

Write-Host "Get-CcodexFailureReason: permission signature classes"
foreach ($signal in @('sandbox violation', 'permission denied', 'approval required', 'access permission missing')) {
    $p = New-TestFile "stderr-perm-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'permission_or_sandbox' "permission signature '$signal' classifies as permission_or_sandbox"
}

Write-Host "Get-CcodexFailureReason: network signature classes"
foreach ($signal in @('network unreachable', 'connection reset', 'dns lookup failed', 'HTTP 502 bad gateway', 'HTTP 503 unavailable')) {
    $p = New-TestFile "stderr-net-$([Guid]::NewGuid().ToString('N')).log" $signal
    Assert-Equal (Get-CcodexFailureReason -CodexExitCode 1 -StderrPath $p -EventsPath $null) 'network' "network signature '$signal' classifies as network"
}

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

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
