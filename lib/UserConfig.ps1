# lib/UserConfig.ps1
$script:CcodexRetentionDefaults = @{
    jobs_days       = 14
    thread_ttl_days = 30
}

# Per-field lower bounds. jobs_days must be >= 1: with jobs_days = 0 the cleanup guard
# (ageDays -gt jobsDays) matches every terminal job, so a plain `ccodex cleanup` would wipe
# them all (including seconds-old, un-applied implement jobs). thread_ttl_days = 0 is a
# legitimate explicit "scrub thread ids immediately" choice, so its minimum stays 0.
$script:CcodexRetentionMinimums = @{
    jobs_days       = 1
    thread_ttl_days = 0
}

function Get-CcodexUserConfig {
    param(
        [string]$AppDataRoot = $env:APPDATA
    )

    $configPath = Join-Path $AppDataRoot 'ccodex/config.json'
    $retentionRaw = $null

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $rawText = Get-Content -LiteralPath $configPath -Raw
        try {
            $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "ccodex: invalid config.json: $($_.Exception.Message)"
        }
        if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'retention')) {
            $retentionRaw = $parsed.retention
        }
    }

    $retention = [ordered]@{}
    foreach ($key in $script:CcodexRetentionDefaults.Keys) {
        $default = $script:CcodexRetentionDefaults[$key]
        $value = $default
        if ($retentionRaw -and ($retentionRaw.PSObject.Properties.Name -contains $key)) {
            $value = $retentionRaw.$key
        }

        $asDouble = 0.0
        if (-not [double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$asDouble)) {
            throw "ccodex: invalid config.json: retention.$key must be an integer (got '$value')"
        }
        # Reject fractional values: [int]0.5 silently rounds to 0, and jobs_days=0 would make
        # cleanup treat every terminal job as aged-out and delete them all. Require a whole number.
        if ($asDouble -ne [Math]::Truncate($asDouble)) {
            throw "ccodex: invalid config.json: retention.$key must be a whole number of days, not fractional (got '$value')"
        }
        $min = $script:CcodexRetentionMinimums[$key]
        if ($asDouble -lt $min -or $asDouble -gt [int]::MaxValue) {
            throw "ccodex: invalid config.json: retention.$key must be between $min and $([int]::MaxValue) (got '$value')"
        }
        $value = [int]$asDouble

        $retention[$key] = $value
    }

    return [pscustomobject]@{
        retention = [pscustomobject]$retention
    }
}
