# lib/Config.ps1
$script:CcodexDelegationEnumValues = @('auto', 'ask', 'off')
$script:CcodexDelegationDefaults = @{
    review_after_changes      = 'ask'
    review_min_changed_lines  = 50
    review_default_paths      = @()
    plan_second_opinion       = 'ask'
    max_codex_calls_per_task  = 2
}

function Get-CcodexProjectConfig {
    param(
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot '.ccodex/ccodex.json'
    $delegationRaw = $null

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $rawText = Get-Content -LiteralPath $configPath -Raw
        try {
            $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "ccodex: invalid .ccodex/ccodex.json: $($_.Exception.Message)"
        }
        if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'delegation')) {
            $delegationRaw = $parsed.delegation
        }
    }

    $delegation = [ordered]@{}
    foreach ($key in $script:CcodexDelegationDefaults.Keys) {
        $default = $script:CcodexDelegationDefaults[$key]
        $value = $default
        if ($delegationRaw -and ($delegationRaw.PSObject.Properties.Name -contains $key)) {
            $value = $delegationRaw.$key
        }

        switch ($key) {
            'review_after_changes' {
                if ($value -notin $script:CcodexDelegationEnumValues) {
                    throw "ccodex: invalid .ccodex/ccodex.json: delegation.review_after_changes must be one of 'auto', 'ask', 'off' (got '$value')"
                }
            }
            'plan_second_opinion' {
                if ($value -notin $script:CcodexDelegationEnumValues) {
                    throw "ccodex: invalid .ccodex/ccodex.json: delegation.plan_second_opinion must be one of 'auto', 'ask', 'off' (got '$value')"
                }
            }
            'review_min_changed_lines' {
                try {
                    $value = [int]$value
                } catch {
                    throw "ccodex: invalid .ccodex/ccodex.json: delegation.review_min_changed_lines must be an integer: $($_.Exception.Message)"
                }
            }
            'max_codex_calls_per_task' {
                try {
                    $value = [int]$value
                } catch {
                    throw "ccodex: invalid .ccodex/ccodex.json: delegation.max_codex_calls_per_task must be an integer: $($_.Exception.Message)"
                }
            }
            'review_default_paths' {
                # `@()` alone never throws (it happily wraps a bad scalar/object into a
                # bogus 1-element array instead of rejecting it), so the array-of-strings
                # contract needs an explicit element check. This also tolerates the known
                # ConvertFrom-Json quirk where a single-element JSON array of strings
                # unwraps to a bare string: @('lib/') round-trips through here unchanged.
                $value = @($value)
                foreach ($item in $value) {
                    if ($item -isnot [string]) {
                        throw "ccodex: invalid .ccodex/ccodex.json: delegation.review_default_paths must be an array of strings."
                    }
                }
            }
        }

        $delegation[$key] = $value
    }

    return [pscustomobject]@{
        delegation = [pscustomobject]$delegation
    }
}
