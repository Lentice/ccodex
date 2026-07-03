# lib/JobId.ps1
function New-CcodexRandomSuffix {
    param([int]$Length = 8)
    $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    $result = New-Object System.Text.StringBuilder
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = [byte[]]::new(1)
        while ($result.Length -lt $Length) {
            $rng.GetBytes($buffer)
            $value = $buffer[0]
            if ($value -lt 252) {
                [void]$result.Append($chars[$value % 36])
            }
        }
    } finally {
        $rng.Dispose()
    }
    return $result.ToString()
}

function New-CcodexJobId {
    param([Parameter(Mandatory)][ValidateSet('review', 'brainstorm', 'test', 'implement')][string]$Mode)
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $suffix = New-CcodexRandomSuffix -Length 8
    return "$timestamp-$suffix-$Mode"
}

function Reserve-CcodexJobDir {
    param(
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$Mode,
        [string]$Root = $env:LOCALAPPDATA,
        [int]$MaxAttempts = 5
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $jobId = New-CcodexJobId -Mode $Mode
        $jobDir = Get-CcodexJobDir -RepoKey $RepoKey -JobId $jobId -Root $Root
        try {
            New-Item -ItemType Directory -Path $jobDir -ErrorAction Stop | Out-Null
            return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
        } catch [System.IO.IOException] {
            continue
        }
    }
    throw "ccodex: failed to reserve a unique job directory after $MaxAttempts attempts."
}
