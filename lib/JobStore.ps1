# lib/JobStore.ps1
function Write-CcodexTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-CcodexJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $json = $Object | ConvertTo-Json -Depth 10
    Write-CcodexTextFile -Path $Path -Content $json
}

function Write-CcodexJsonFileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $tempPath = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    Write-CcodexJsonFile -Path $tempPath -Object $Object
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function ConvertTo-CcodexCommandLineText {
    param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string[]]$Arguments)
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    return (@($Executable) + $quoted) -join ' '
}

function New-CcodexStatusObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$CreatedAt,
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [string]$ErrorMessage = $null,
        [string]$Backend = 'sync',
        [string]$BackendId = $null,
        [string]$StartedAt = $null,
        [string]$FinishedAt = $null,
        [string]$FailureReason = $null,
        [string]$CodexThreadId = $null,
        [Nullable[int]]$HardTimeoutSec = $null,
        [string]$TimeoutReason = $null,
        [string]$TerminatedAt = $null,
        [string]$LastHeartbeatAt = $null
    )
    return [ordered]@{
        schema_version    = 1
        ccodex_version    = '0.1.0'
        job_id            = $JobId
        status            = $Status
        mode              = $Mode
        access            = $Access
        repo              = $Repo
        created_at        = $CreatedAt
        backend           = $Backend
        backend_id        = $BackendId
        started_at        = $StartedAt
        finished_at       = $FinishedAt
        codex_exit_code   = $CodexExitCode
        wrapper_exit_code = $WrapperExitCode
        error             = $ErrorMessage
        failure_reason    = $FailureReason
        codex_thread_id   = $CodexThreadId
        hard_timeout_sec  = $HardTimeoutSec
        timeout_reason    = $TimeoutReason
        terminated_at     = $TerminatedAt
        last_heartbeat_at = $LastHeartbeatAt
    }
}

function New-CcodexDebugObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string[]]$CodexArgs,
        [string]$Backend = 'sync'
    )
    return [ordered]@{
        job_id              = $JobId
        powershell_version  = $PSVersionTable.PSVersion.ToString()
        os_description      = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        repo                = $Repo
        job_dir             = $JobDir
        mode                = $Mode
        access              = $Access
        backend             = $Backend
        codex_path          = $CodexPath
        codex_args          = $CodexArgs
    }
}

function New-CcodexWorkerCompleteObject {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$StatusCandidate,
        [Nullable[int]]$CodexExitCode,
        [Nullable[int]]$WrapperExitCode,
        [Parameter(Mandatory)][bool]$ResultPresent,
        [Parameter(Mandatory)][string]$CompletedAt
    )
    return [ordered]@{
        job_id            = $JobId
        status_candidate  = $StatusCandidate
        codex_exit_code   = $CodexExitCode
        wrapper_exit_code = $WrapperExitCode
        result_present    = $ResultPresent
        completed_at      = $CompletedAt
    }
}
