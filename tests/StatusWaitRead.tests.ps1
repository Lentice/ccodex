# tests/StatusWaitRead.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobId.ps1')
. (Join-Path $PSScriptRoot '..\lib\StdinTimeout.ps1')
. (Join-Path $PSScriptRoot '..\lib\PromptSource.ps1')
. (Join-Path $PSScriptRoot '..\lib\WorkerPrompt.ps1')
. (Join-Path $PSScriptRoot '..\lib\ModeAccess.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\CodexInvoke.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')
. (Join-Path $PSScriptRoot '..\lib\Detach.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-statuswaitread-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

$fabricatedDeadBackendId = '999999;2020-01-01T00:00:00.0000000Z'
$currentProc = Get-Process -Id $PID
$aliveBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime $currentProc.StartTime

function New-CcodexTestJobWithStatus {
    # Seeds a job dir via the real reservation/index path (like Worker.tests.ps1's
    # New-CcodexTestJob), then overwrites status.json with the given shape so every
    # status-command branch can be exercised deterministically.
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$Status = 'created',
        [string]$BackendId = $null,
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [switch]$WithExitCodeEvidence,
        [int]$EvidenceExitCode = 0,
        [switch]$WithResultFile
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content 'test worker prompt body'
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status $Status -Mode $Mode -Access $Access -Repo $targetRepo -CreatedAt $createdAt -BackendId $BackendId -CodexExitCode $CodexExitCode -WrapperExitCode $WrapperExitCode
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    if ($WithExitCodeEvidence) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'exit_code.txt') -Content "$EvidenceExitCode"
    }
    if ($WithResultFile) {
        Write-CcodexTextFile -Path (Join-Path $jobDir 'result.md') -Content 'the result'
    }
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

# --- status: created (non-terminal) ---

Write-Host "Invoke-CcodexStatusCommand: created job -> one line, no health flag, exit 0"
$jobCreated = New-CcodexTestJobWithStatus -Status 'created'
$resultCreated = Invoke-CcodexStatusCommand -JobId $jobCreated.JobId -StateRoot $localAppData
Assert-Equal $resultCreated.WrapperExitCode 0 'created job -> exit 0'
Assert-Equal $resultCreated.Stdout "$($jobCreated.JobId) created" 'created job status line has no codes/health'

# --- status: running + worker alive (non-terminal) ---

Write-Host "Invoke-CcodexStatusCommand: running + worker alive -> plain running line"
$jobAlive = New-CcodexTestJobWithStatus -Status 'running' -BackendId $aliveBackendId
$resultAlive = Invoke-CcodexStatusCommand -JobId $jobAlive.JobId -StateRoot $localAppData
Assert-Equal $resultAlive.WrapperExitCode 0 'running+alive job -> exit 0'
Assert-Equal $resultAlive.Stdout "$($jobAlive.JobId) running" 'running+alive status line has no health flag'
$statusAliveAfter = Get-Content -LiteralPath (Join-Path $jobAlive.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusAliveAfter.status 'running' 'running+alive status.json unchanged'

# --- status: running + worker dead + exit_code.txt evidence -> reconciled terminal line, file rewritten ---

Write-Host "Invoke-CcodexStatusCommand: running + dead worker + evidence -> reconciled done line, status.json rewritten"
$jobDeadEvidence = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId -WithExitCodeEvidence -EvidenceExitCode 0 -WithResultFile
$beforeRewrite = (Get-Item (Join-Path $jobDeadEvidence.JobDir 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadEvidence = Invoke-CcodexStatusCommand -JobId $jobDeadEvidence.JobId -StateRoot $localAppData
Assert-Equal $resultDeadEvidence.WrapperExitCode 0 'reconciled dead-with-evidence job -> exit 0'
Assert-Equal $resultDeadEvidence.Stdout "$($jobDeadEvidence.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'reconciled line shows terminal done with codes'
$afterRewrite = (Get-Item (Join-Path $jobDeadEvidence.JobDir 'status.json')).LastWriteTimeUtc
Assert-True ($afterRewrite -gt $beforeRewrite) 'status.json was rewritten during reconciliation'
$statusDeadEvidenceAfter = Get-Content -LiteralPath (Join-Path $jobDeadEvidence.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusDeadEvidenceAfter.status 'done' 'status.json reflects reconciled done status'

# --- status: running + worker dead + no evidence -> possibly-stale line, file NOT rewritten ---

Write-Host "Invoke-CcodexStatusCommand: running + dead worker + no evidence -> possibly-stale line, no rewrite"
$jobDeadNoEvidence = New-CcodexTestJobWithStatus -Status 'running' -BackendId $fabricatedDeadBackendId
$beforeNoRewrite = (Get-Item (Join-Path $jobDeadNoEvidence.JobDir 'status.json')).LastWriteTimeUtc
Start-Sleep -Milliseconds 50
$resultDeadNoEvidence = Invoke-CcodexStatusCommand -JobId $jobDeadNoEvidence.JobId -StateRoot $localAppData
Assert-Equal $resultDeadNoEvidence.WrapperExitCode 0 'dead-worker-no-evidence job -> exit 0'
Assert-Equal $resultDeadNoEvidence.Stdout "$($jobDeadNoEvidence.JobId) running health=possibly-stale" 'possibly-stale line appended for dead worker without evidence'
$afterNoRewrite = (Get-Item (Join-Path $jobDeadNoEvidence.JobDir 'status.json')).LastWriteTimeUtc
Assert-Equal $afterNoRewrite $beforeNoRewrite 'status.json was NOT rewritten when there is no completion evidence'

# --- status: done (terminal) ---

Write-Host "Invoke-CcodexStatusCommand: already-done job -> terminal line with codes"
$jobDone = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$resultDone = Invoke-CcodexStatusCommand -JobId $jobDone.JobId -StateRoot $localAppData
Assert-Equal $resultDone.WrapperExitCode 0 'done job -> exit 0'
Assert-Equal $resultDone.Stdout "$($jobDone.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'done job status line shows both codes'

# --- status: failed (terminal) ---

Write-Host "Invoke-CcodexStatusCommand: failed job -> terminal line with codes"
$jobFailed = New-CcodexTestJobWithStatus -Status 'failed' -CodexExitCode 1 -WrapperExitCode 10
$resultFailed = Invoke-CcodexStatusCommand -JobId $jobFailed.JobId -StateRoot $localAppData
Assert-Equal $resultFailed.WrapperExitCode 0 'failed job -> exit 0 (printing status is success)'
Assert-Equal $resultFailed.Stdout "$($jobFailed.JobId) failed codex_exit_code=1 wrapper_exit_code=10" 'failed job status line shows both codes'

# --- status: unknown job id -> 3 ---

Write-Host "Invoke-CcodexStatusCommand: unknown job id -> exit 3"
$resultUnknown = Invoke-CcodexStatusCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultUnknown.Message)) 'unknown job id returns a diagnostic message'

# --- shell-level: pwsh -File ccodex.ps1 status <id> --state-root ... ---

Write-Host "shell-level: ccodex.ps1 status <id> --state-root <root> prints exactly one line, exit 0"
$jobShell = New-CcodexTestJobWithStatus -Status 'done' -CodexExitCode 0 -WrapperExitCode 0
$shellOut = & pwsh -NoLogo -NoProfile -File $ccodexPs status $jobShell.JobId --state-root $localAppData
$shellExit = $LASTEXITCODE
Assert-Equal $shellExit 0 'shell-level status invocation exits 0'
$shellOutLines = @($shellOut | Where-Object { $_ -ne $null -and $_ -ne '' })
Assert-Equal $shellOutLines.Count 1 'shell-level status prints exactly one line'
Assert-Equal $shellOutLines[0] "$($jobShell.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'shell-level status line matches the terminal format'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
