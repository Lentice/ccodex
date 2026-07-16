# lib/JobList.ps1
function Get-CcodexJobList {
    # Read-only enumeration of jobs from the jobs/ tree — the SAME authoritative source
    # cleanup uses (NOT the flat index/, which can carry dangling entries and miss a
    # crash-orphaned dir). Performs NO reconciliation and NO writes: health for a running
    # job is derived from its heartbeat via Get-CcodexJobHealth (ok|stale), which needs no
    # lock. Returns an array (newest-first by job_id descending) of job entries. A normal
    # entry is that job's status.json plus a derived `health` and its `job_dir`; a job whose
    # status.json is missing/unreadable yields a minimal { job_id (from dir name),
    # status='unknown', error, job_dir } entry so one bad job never aborts the whole listing.
    param(
        [string]$Root = $env:LOCALAPPDATA,
        # When set, scan only jobs/<RepoKey>/ instead of every repo subtree.
        [string]$RepoKey = $null,
        # When non-empty, keep only jobs whose status is in this set.
        [string[]]$State = @(),
        [string]$Group = $null,
        [string]$Label = $null,
        [int]$StaleAfterSec = 90
    )

    $jobsRoot = Join-Path (Get-CcodexLocalAppDataRoot -Root $Root) 'jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot -PathType Container)) {
        return , @()
    }

    $repoDirs = if ($RepoKey) {
        $one = Join-Path $jobsRoot $RepoKey
        if (Test-Path -LiteralPath $one -PathType Container) { @(Get-Item -LiteralPath $one) } else { @() }
    } else {
        @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue)
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($repoDir in $repoDirs) {
        foreach ($jobDir in @(Get-ChildItem -LiteralPath $repoDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            $statusObj = Read-CcodexStatusFile -JobDir $jobDir.FullName
            # Missing/unreadable AND structurally-invalid-but-valid-JSON (a JSON array/scalar, or
            # an object with no `status`) both map to the minimal unknown entry — otherwise a
            # malformed file would render as a normal job with empty fields, breaking the
            # unreadable/corrupt-file contract. status.json is always a status OBJECT when the
            # wrapper wrote it; anything else is corruption.
            if ($null -eq $statusObj -or $statusObj -isnot [pscustomobject] -or $null -eq $statusObj.PSObject.Properties['status']) {
                $entries.Add([pscustomobject]([ordered]@{
                    job_id  = $jobDir.Name
                    status  = 'unknown'
                    error   = 'status.json missing, unreadable, or malformed'
                    job_dir = $jobDir.FullName
                }))
                continue
            }
            $entry = [ordered]@{}
            foreach ($property in $statusObj.PSObject.Properties) {
                $entry[$property.Name] = $property.Value
            }
            $entry['health'] = Get-CcodexJobHealth -Status $statusObj -StaleAfterSec $StaleAfterSec
            $entry['job_dir'] = $jobDir.FullName
            $entries.Add([pscustomobject]$entry)
        }
    }

    $allEntries = $entries.ToArray()
    $filtered = if ($State -and $State.Count -gt 0) {
        @($allEntries | Where-Object { $_.status -in $State })
    } else {
        @($allEntries)
    }
    if (-not [string]::IsNullOrEmpty($Group)) {
        $filtered = @($filtered | Where-Object { $null -ne $_.PSObject.Properties['group'] -and $_.group -ceq $Group })
    }
    if (-not [string]::IsNullOrEmpty($Label)) {
        $filtered = @($filtered | Where-Object { $null -ne $_.PSObject.Properties['label'] -and $_.label -ceq $Label })
    }

    # `, @(...)` forces an array return even for 0/1 element so callers get a stable
    # .Count and can index it. job_id is a real property on every entry (normal AND
    # unknown), so a descending property sort is well-defined and chronological.
    return , @($filtered | Sort-Object -Property job_id -Descending)
}
