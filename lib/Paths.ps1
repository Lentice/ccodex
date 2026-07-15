function Get-CcodexLocalAppDataRoot {
    param([string]$Root = $env:LOCALAPPDATA)
    return Join-Path $Root 'ccodex'
}

function Get-CcodexAppDataRoot {
    param([string]$Root = $env:APPDATA)
    return Join-Path $Root 'ccodex'
}

function Get-CcodexRepoKey {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $resolved = (Resolve-Path -LiteralPath $RepoRoot).Path
    $normalized = $resolved.TrimEnd('\', '/').ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0, 12)
}

function Get-CcodexJobsDir {
    param([Parameter(Mandatory)][string]$RepoKey, [string]$Root = $env:LOCALAPPDATA)
    return Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $Root) 'jobs') $RepoKey
}

function Get-CcodexJobDir {
    param([Parameter(Mandatory)][string]$RepoKey, [Parameter(Mandatory)][string]$JobId, [string]$Root = $env:LOCALAPPDATA)
    return Join-Path (Get-CcodexJobsDir -RepoKey $RepoKey -Root $Root) $JobId
}

function Get-CcodexIndexPath {
    param([Parameter(Mandatory)][string]$JobId, [string]$Root = $env:LOCALAPPDATA)
    # Guard against path traversal: a job id arrives from the CLI (status/wait/read/cancel/...)
    # and is joined straight into the index-file path, so an id like `..\..\evil` would resolve
    # the lookup outside the index directory. Real ids (New-CcodexJobId) are only [A-Za-z0-9-],
    # so reject empty ids and anything containing a path separator or a `..` segment. Callers
    # that resolve a job (Get-CcodexJobRecord) already map this throw to "not found" (exit 3).
    if ([string]::IsNullOrWhiteSpace($JobId) -or $JobId -match '[\\/]' -or $JobId -match '\.\.') {
        throw "ccodex: invalid job id '$JobId'."
    }
    return Join-Path (Join-Path (Get-CcodexLocalAppDataRoot -Root $Root) 'index') "$JobId.json"
}
