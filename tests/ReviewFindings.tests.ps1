# tests/ReviewFindings.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\ReviewFindings.ps1')

$M = '<!-- ccodex:findings -->'

function New-FindingsResult {
    # Wraps a raw JSON body in prose + the marker + a ```json fence, mimicking a real review result.
    param([string]$Json, [string]$Marker = '<!-- ccodex:findings -->', [string]$Lang = 'json')
    return @"
Here is the prose review a human reads first.

- Critical: something is wrong.

One-line verdict: looks risky.

$Marker
``````$Lang
$Json
``````
"@
}

# --- happy path ---

Write-Host "Get-CcodexReviewFindings: valid block -> normalized object with verdict + items"
$twoItems = @'
{
  "verdict": "one bug, one nit",
  "items": [
    { "severity": "Critical", "file": "a.ps1", "line": 42, "claim": "off-by-one", "evidence": "loop bound", "suggested_fix": "use -lt" },
    { "severity": "minor", "file": "b.ps1", "line": 7, "claim": "typo", "evidence": "comment", "suggested_fix": "fix it" }
  ]
}
'@
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $twoItems)
Assert-True ($null -ne $f) 'valid block -> non-null'
Assert-Equal $f.verdict 'one bug, one nit' 'verdict parsed'
Assert-Equal $f.items.Count 2 'two items parsed'
Assert-Equal $f.items[0].severity 'critical' 'severity normalized to lowercase'
Assert-Equal $f.items[0].line 42 'line preserved as int'
Assert-Equal $f.items[0].claim 'off-by-one' 'claim preserved'
Assert-Equal $f.items[0].Keys.Count 6 'item has exactly 6 keys'
foreach ($k in @('severity','file','line','claim','evidence','suggested_fix')) {
    Assert-True ($f.items[0].Keys -contains $k) "item has key '$k'"
}

# --- absence / malformed ---

Write-Host "Get-CcodexReviewFindings: no marker -> null"
Assert-Equal (Get-CcodexReviewFindings -ResultContent "Just prose, no findings block at all.") $null 'no marker -> null'

Write-Host "Get-CcodexReviewFindings: null/empty input -> null"
Assert-Equal (Get-CcodexReviewFindings -ResultContent $null) $null 'null input -> null'
Assert-Equal (Get-CcodexReviewFindings -ResultContent '') $null 'empty input -> null'

Write-Host "Get-CcodexReviewFindings: marker present but malformed JSON -> null"
Assert-Equal (Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json '{ not: valid json,, }')) $null 'malformed JSON -> null'

Write-Host "Get-CcodexReviewFindings: unrelated json fence WITHOUT the marker -> null"
$noMarker = @"
Some prose.
``````json
{ "verdict": "x", "items": [] }
``````
"@
Assert-Equal (Get-CcodexReviewFindings -ResultContent $noMarker) $null 'json fence without marker -> null'

# --- multiple blocks / last wins ---

Write-Host "Get-CcodexReviewFindings: multiple marked blocks -> last wins"
$first = New-FindingsResult -Json '{ "verdict": "FIRST", "items": [] }'
$second = New-FindingsResult -Json '{ "verdict": "SECOND", "items": [] }'
$f = Get-CcodexReviewFindings -ResultContent ($first + "`n`n" + $second)
Assert-Equal $f.verdict 'SECOND' 'last block wins'

Write-Host "Get-CcodexReviewFindings: last block malformed -> null (no fallback to earlier valid block)"
$good = New-FindingsResult -Json '{ "verdict": "GOOD", "items": [] }'
$bad = New-FindingsResult -Json '{ broken'
Assert-Equal (Get-CcodexReviewFindings -ResultContent ($good + "`n`n" + $bad)) $null 'last-malformed -> null, no earlier fallback'

# --- per-item validation ---

Write-Host "Get-CcodexReviewFindings: invalid item dropped, valid item kept"
$mixed = @'
{ "verdict": "v", "items": [
  { "severity": "bogus", "claim": "dropped for bad severity" },
  { "severity": "important", "claim": "kept" }
] }
'@
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $mixed)
Assert-Equal $f.items.Count 1 'one invalid item dropped'
Assert-Equal $f.items[0].claim 'kept' 'the valid item survived'

Write-Host "Get-CcodexReviewFindings: missing nullable fields -> nulls, item still kept"
$minimal = @'
{ "items": [ { "severity": "minor", "claim": "only required fields" } ] }
'@
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $minimal)
Assert-Equal $f.items.Count 1 'minimal item kept'
Assert-Equal $f.items[0].file $null 'missing file -> null'
Assert-Equal $f.items[0].line $null 'missing line -> null'
Assert-Equal $f.items[0].evidence $null 'missing evidence -> null'
Assert-Equal $f.items[0].suggested_fix $null 'missing suggested_fix -> null'
Assert-Equal $f.items[0].Keys.Count 6 'minimal item still has all 6 keys'

Write-Host "Get-CcodexReviewFindings: bad line values -> null"
foreach ($badLine in @('0', '-3', '42.5', '"42"')) {
    $body = "{ ""items"": [ { ""severity"": ""minor"", ""claim"": ""c"", ""line"": $badLine } ] }"
    $f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $body)
    Assert-Equal $f.items[0].line $null "line '$badLine' -> null"
}

Write-Host "Get-CcodexReviewFindings: line above Int32.MaxValue -> line null, item kept, appendix survives"
# Regression (Codex review of #5): [int] cast of a >Int32 line threw, and the outer catch turned
# that into a null for the WHOLE appendix, discarding unrelated valid findings.
$bigLine = @'
{ "verdict": "v", "items": [ { "severity": "critical", "claim": "kept despite huge line", "line": 2147483648 } ] }
'@
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $bigLine)
Assert-True ($null -ne $f) 'huge line does not null the whole appendix'
Assert-Equal $f.items.Count 1 'item with out-of-range line is kept'
Assert-Equal $f.items[0].line $null 'out-of-range line degraded to null'

Write-Host "Get-CcodexReviewFindings: literal triple-backtick inside a JSON string does not truncate the block"
# Regression (Codex review of #5): the closing-fence match treated an inline ``` as the fence
# terminator, truncating the JSON body so a valid finding parsed as malformed and was discarded.
$innerFence = 'see the fenced snippet ```code``` in context'
$withFence = "{ ""items"": [ { ""severity"": ""minor"", ""claim"": ""c"", ""evidence"": ""$innerFence"" } ] }"
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $withFence)
Assert-True ($null -ne $f) 'inline triple-backtick does not break parsing'
Assert-Equal $f.items.Count 1 'finding with inline fence in evidence is kept'
Assert-Equal $f.items[0].evidence $innerFence 'evidence with inline fence preserved intact'

Write-Host "Get-CcodexReviewFindings: required-field violations drop the item"
$viol = @'
{ "items": [
  { "claim": "no severity" },
  { "severity": "critical" },
  { "severity": "critical", "claim": "   " }
] }
'@
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json $viol)
Assert-Equal $f.items.Count 0 'all required-field violators dropped'

Write-Host "Get-CcodexReviewFindings: all-invalid items -> present with empty items[] (not null)"
$allBad = New-FindingsResult -Json '{ "verdict": "v", "items": [ { "severity": "nope", "claim": "x" } ] }'
$f = Get-CcodexReviewFindings -ResultContent $allBad
Assert-True ($null -ne $f) 'block present -> not null even when every item dropped'
Assert-Equal $f.items.Count 0 'empty items array'

Write-Host "Get-CcodexReviewFindings: unknown item properties discarded"
$extra = New-FindingsResult -Json '{ "items": [ { "severity": "minor", "claim": "c", "bogus_extra": "x" } ] }'
$f = Get-CcodexReviewFindings -ResultContent $extra
Assert-Equal $f.items[0].Keys.Count 6 'unknown property discarded, still 6 keys'
Assert-True ($f.items[0].Keys -notcontains 'bogus_extra') 'unknown key not present'

# --- verdict validation ---

Write-Host "Get-CcodexReviewFindings: verdict absent/empty/non-string -> null"
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json '{ "items": [] }')
Assert-Equal $f.verdict $null 'absent verdict -> null'
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json '{ "verdict": "   ", "items": [] }')
Assert-Equal $f.verdict $null 'whitespace verdict -> null'
$f = Get-CcodexReviewFindings -ResultContent (New-FindingsResult -Json '{ "verdict": 42, "items": [] }')
Assert-Equal $f.verdict $null 'numeric verdict -> null'

# --- whitespace / CRLF tolerance ---

Write-Host "Get-CcodexReviewFindings: CRLF line endings tolerated"
$crlf = (New-FindingsResult -Json '{ "verdict": "crlf ok", "items": [] }') -replace "`n", "`r`n"
$f = Get-CcodexReviewFindings -ResultContent $crlf
Assert-True ($null -ne $f) 'CRLF content parsed'
Assert-Equal $f.verdict 'crlf ok' 'verdict parsed under CRLF'

Write-Host "Get-CcodexReviewFindings: extra whitespace around marker and fences tolerated"
$spaced = @"
prose

   $M
   ``````json

   { "verdict": "spaced", "items": [] }

   ``````
"@
$f = Get-CcodexReviewFindings -ResultContent $spaced
Assert-True ($null -ne $f) 'whitespace-padded block parsed'
Assert-Equal $f.verdict 'spaced' 'verdict parsed with padding'

Complete-CcodexTests
