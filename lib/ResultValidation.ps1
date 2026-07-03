# lib/ResultValidation.ps1
function Test-CcodexResult {
    param(
        [Parameter(Mandatory)][int]$CodexExitCode,
        [Parameter(Mandatory)][string]$ResultPath
    )
    $resultExists = Test-Path -LiteralPath $ResultPath -PathType Leaf
    $resultContent = if ($resultExists) { Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 } else { '' }
    $resultNonEmpty = $resultExists -and $resultContent.Trim().Length -gt 0

    if ($CodexExitCode -ne 0) {
        return [pscustomobject]@{
            Status          = 'failed'
            WrapperExitCode = 10
            ResultPresent   = $resultNonEmpty
            ResultContent   = $resultContent
        }
    }

    if (-not $resultNonEmpty) {
        return [pscustomobject]@{
            Status          = 'failed'
            WrapperExitCode = 11
            ResultPresent   = $false
            ResultContent   = ''
        }
    }

    return [pscustomobject]@{
        Status          = 'done'
        WrapperExitCode = 0
        ResultPresent   = $true
        ResultContent   = $resultContent
    }
}
