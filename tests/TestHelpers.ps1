$script:CcodexTestCount = 0
$script:CcodexTestFailures = 0
$script:CcodexLastError = $null

function Assert-Equal {
    param($Actual, $Expected, [string]$Because = '')
    $script:CcodexTestCount++
    # A collection on the left of -ceq becomes a membership FILTER, not an equality test: a
    # non-empty filtered result is truthy, so @('expected','unexpected') -ceq 'expected' would
    # "pass" despite the extra element. Reject collection actuals so such false-greens fail loudly.
    $actualIsCollection = ($Actual -is [System.Collections.IEnumerable]) -and ($Actual -isnot [string])
    if ((-not $actualIsCollection) -and ($Actual -ceq $Expected)) {
        Write-Host "  PASS: expected '$Expected'$(if ($Because) { " ($Because)" })"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: expected '$Expected' but got '$Actual'$(if ($Because) { " ($Because)" })" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:CcodexTestCount++
    if ($Condition) {
        Write-Host "  PASS: $Message"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [string]$Message)
    $script:CcodexTestCount++
    $threw = $false
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw = $true
        $script:CcodexLastError = $_.Exception.Message
    }
    if ($threw) {
        Write-Host "  PASS: $Message (threw: $script:CcodexLastError)"
    } else {
        $script:CcodexTestFailures++
        Write-Host "  FAIL: $Message (expected to throw, did not)" -ForegroundColor Red
    }
}

function Complete-CcodexTests {
    Write-Host ""
    Write-Host "$script:CcodexTestCount assertions, $script:CcodexTestFailures failed"
    if ($script:CcodexTestFailures -gt 0) { exit 1 } else { exit 0 }
}
