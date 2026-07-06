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

        try {
            $value = [int]$value
        } catch {
            throw "ccodex: invalid config.json: retention.$key must be an integer: $($_.Exception.Message)"
        }

        if ($value -lt 0) {
            throw "ccodex: invalid config.json: retention.$key must not be negative (got '$value')"
        }

        $retention[$key] = $value
    }

    return [pscustomobject]@{
        retention = [pscustomobject]$retention
    }
}
