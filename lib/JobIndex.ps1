# lib/JobIndex.ps1
function Get-CcodexJobRecord {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$Root = $env:LOCALAPPDATA
    )

    $indexPath = Get-CcodexIndexPath -JobId $JobId -Root $Root
    if (-not (Test-Path -LiteralPath $indexPath)) {
        throw "ccodex: job '$JobId' not found (no index entry)."
    }

    $entry = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json

    if (-not (Test-Path -LiteralPath $entry.job_dir)) {
        throw "ccodex: job '$JobId' index entry exists but its job directory is missing: $($entry.job_dir)"
    }

    return [pscustomobject]@{
        JobId   = $entry.job_id
        RepoKey = $entry.repo_key
        JobDir  = $entry.job_dir
    }
}
