# lib/JobStatus.ps1
function Read-CcodexStatusFile {
    param([Parameter(Mandatory)][string]$JobDir)

    $statusPath = Join-Path $JobDir 'status.json'
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                $content = Get-Content -LiteralPath $statusPath -Raw
                return $content | ConvertFrom-Json
            }
        } catch {
            # tolerate a mid-rename / mid-write window; retry below
        }
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Milliseconds 100
        }
    }
    return $null
}

function ConvertTo-CcodexBackendId {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][DateTime]$StartTime
    )
    return "$ProcessId;$($StartTime.ToUniversalTime().ToString('o'))"
}

function Test-CcodexWorkerAlive {
    param([string]$BackendId)

    if ([string]::IsNullOrEmpty($BackendId)) {
        return $false
    }

    $parts = $BackendId.Split(';', 2)
    if ($parts.Count -ne 2) {
        return $false
    }

    $pidText = $parts[0]
    $startTimeText = $parts[1]

    $processId = 0
    if (-not [int]::TryParse($pidText, [ref]$processId)) {
        return $false
    }

    $recordedStartTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
            $startTimeText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$recordedStartTime)) {
        return $false
    }

    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
        $actualStartTimeUtc = $proc.StartTime.ToUniversalTime()
        $recordedStartTimeUtc = $recordedStartTime.ToUniversalTime()
        $delta = ($actualStartTimeUtc - $recordedStartTimeUtc).Duration()
        return $delta.TotalSeconds -le 2
    } catch {
        return $false
    }
}

function Update-CcodexOrphanStatus {
    param([Parameter(Mandatory)][string]$JobDir)

    $status = Read-CcodexStatusFile -JobDir $JobDir
    if ($null -eq $status) {
        return [pscustomobject]@{ Status = $null; Reconciled = $false; PossiblyStale = $true }
    }

    if ($status.status -ne 'running') {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $false }
    }

    if (Test-CcodexWorkerAlive -BackendId $status.backend_id) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $false }
    }

    $exitCodePath = Join-Path $JobDir 'exit_code.txt'
    if (-not (Test-Path -LiteralPath $exitCodePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
    }

    # Dogfood #2: exit_code.txt can be caught mid-write (empty/partial/corrupt) if the
    # worker died at just the wrong instant. Treat anything that doesn't parse cleanly as
    # a whole integer as no-usable-evidence rather than throwing — the job stays `running`
    # with health=possibly-stale, to be reconciled on a later poll once the file settles.
    $exitCodeRawContent = Get-Content -LiteralPath $exitCodePath -Raw
    $exitCodeText = if ($null -ne $exitCodeRawContent) { $exitCodeRawContent.Trim() } else { '' }
    $codexExitCode = 0
    if (-not [int]::TryParse($exitCodeText, [ref]$codexExitCode)) {
        return [pscustomobject]@{ Status = $status.status; Reconciled = $false; PossiblyStale = $true }
    }
    $resultPath = Join-Path $JobDir 'result.md'
    $verdict = Test-CcodexResult -CodexExitCode $codexExitCode -ResultPath $resultPath

    $updated = [ordered]@{}
    foreach ($property in $status.PSObject.Properties) {
        $updated[$property.Name] = $property.Value
    }
    $updated['status'] = $verdict.Status
    $updated['codex_exit_code'] = $codexExitCode
    $updated['wrapper_exit_code'] = $verdict.WrapperExitCode
    $updated['finished_at'] = (Get-Date).ToUniversalTime().ToString('o')
    $updated['error'] = if ($verdict.Status -eq 'failed') {
        'worker process exited; state reconciled from completion evidence'
    } else {
        $null
    }

    Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir 'status.json') -Object $updated

    return [pscustomobject]@{ Status = $verdict.Status; Reconciled = $true; PossiblyStale = $false }
}
