# lib/ReviewFindings.ps1
#
# HINT-only parser for the structured "findings" appendix a `ccodex review` result may carry
# (backlog #19). Mirrors the failure-classification module's discipline: NEVER throws, and
# degrades to $null on any missing / malformed / unparseable input. Parsing findings is an
# accelerator for per-finding triage, never a lifecycle contract — a null result simply means
# the caller falls back to reading the prose review, exactly as before this module existed.
#
# Marker grammar (fixed contract, spec amendments 2026-07-20): the appendix is introduced by a
# line containing `<!-- ccodex:findings -->`, followed by a ```json fenced block. Whitespace and
# CRLF/LF are tolerated. If several marker+fence pairs exist, the LAST one wins (the appendix
# position is the contract); if that last block's JSON is malformed, the result is $null with no
# fallback to an earlier valid block.

$script:CcodexFindingsSeverities = @('critical', 'important', 'minor')

function ConvertTo-CcodexFindingItem {
    # Validate + normalize one parsed item. Returns an ordered dictionary with all six keys
    # always present (missing/invalid optionals -> $null), or $null when the item must be dropped
    # (not an object, bad/absent severity, or empty/non-string claim). Unknown properties are
    # discarded by construction (only the six known keys are ever emitted).
    param([object]$Item)

    if ($null -eq $Item -or $Item -isnot [System.Management.Automation.PSCustomObject]) { return $null }

    # severity: required; must case-insensitively match the allowed set; emitted lowercase.
    $sevRaw = $Item.severity
    if ($sevRaw -isnot [string]) { return $null }
    $sev = $sevRaw.Trim().ToLowerInvariant()
    if ($sev -notin $script:CcodexFindingsSeverities) { return $null }

    # claim: required; must be a non-empty (non-whitespace) string.
    $claim = $Item.claim
    if ($claim -isnot [string] -or [string]::IsNullOrWhiteSpace($claim)) { return $null }

    # line: positive integer else null. Only true numeric types are accepted (a string "42" is
    # "wrong-typed" and becomes null); a non-integral double is rejected too.
    $line = $null
    $lineRaw = $Item.line
    if ($lineRaw -is [int] -or $lineRaw -is [long]) {
        if ([long]$lineRaw -gt 0) { $line = [int]$lineRaw }
    } elseif ($lineRaw -is [double] -or $lineRaw -is [decimal]) {
        $d = [double]$lineRaw
        if ($d -gt 0 -and [math]::Floor($d) -eq $d) { $line = [int]$d }
    }

    # Nullable string fields: kept when a string, otherwise null.
    $file = if ($Item.file -is [string]) { $Item.file } else { $null }
    $evidence = if ($Item.evidence -is [string]) { $Item.evidence } else { $null }
    $suggestedFix = if ($Item.suggested_fix -is [string]) { $Item.suggested_fix } else { $null }

    return [ordered]@{
        severity      = $sev
        file          = $file
        line          = $line
        claim         = $claim
        evidence      = $evidence
        suggested_fix = $suggestedFix
    }
}

function Get-CcodexReviewFindings {
    # Parse the structured findings appendix out of a job's result content. Returns an ordered
    # dictionary { verdict; items } (verdict is a string or $null; items is an array, possibly
    # empty, of normalized item dictionaries), or $null when no usable marked block is present.
    param([AllowNull()][string]$ResultContent)

    if ([string]::IsNullOrEmpty($ResultContent)) { return $null }

    try {
        # (?s): dot matches newlines so the JSON body can span lines. Marker tolerates internal
        # and surrounding whitespace; \s* between marker, fence, body, and closing fence absorbs
        # CRLF/LF and padding. Lazy (.*?) stops at the first closing fence for each block.
        $pattern = '(?s)<!--\s*ccodex:findings\s*-->\s*```json\s*(.*?)```'
        $matches = [regex]::Matches($ResultContent, $pattern)
        if ($matches.Count -eq 0) { return $null }

        # Last marked block wins (appendix position is the contract).
        $jsonBody = $matches[$matches.Count - 1].Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($jsonBody)) { return $null }

        try {
            $parsed = $jsonBody | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return $null
        }

        # verdict: string only, non-empty/non-whitespace; else null.
        $verdict = $null
        if ($parsed.PSObject.Properties.Name -contains 'verdict') {
            $v = $parsed.verdict
            if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v)) { $verdict = $v }
        }

        $items = [System.Collections.Generic.List[object]]::new()
        if ($parsed.PSObject.Properties.Name -contains 'items' -and $parsed.items -is [System.Array]) {
            foreach ($rawItem in $parsed.items) {
                $normalized = ConvertTo-CcodexFindingItem -Item $rawItem
                if ($null -ne $normalized) { $items.Add($normalized) }
            }
        }

        return [ordered]@{
            verdict = $verdict
            items   = @($items.ToArray())
        }
    } catch {
        # Defensive: any unexpected failure degrades to null (never throws).
        return $null
    }
}
