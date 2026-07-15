# lib/UserConfig.ps1
$script:CcodexRetentionDefaults = @{
    jobs_days       = 14
    thread_ttl_days = 30
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
        if ($asDouble -lt 0 -or $asDouble -gt [int]::MaxValue) {
            throw "ccodex: invalid config.json: retention.$key must be between 0 and $([int]::MaxValue) (got '$value')"
        }
        $value = [int]$asDouble

        $retention[$key] = $value
    }

    return [pscustomobject]@{
        retention = [pscustomobject]$retention
    }
}
