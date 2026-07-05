# tests/Detach.tests.ps1
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
$fixtureCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-detach-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

function New-CcodexTestJob {
    param(
        [string]$Mode = 'review',
        [string]$Access = 'read-only',
        [string]$PromptContent = 'test worker prompt body'
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content $PromptContent
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object (New-CcodexStatusObject -JobId $jobId -Status 'created' -Mode $Mode -Access $Access -Repo $targetRepo -CreatedAt $createdAt)
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

function Wait-CcodexTestTerminalStatus {
    param([Parameter(Mandatory)][string]$JobDir, [int]$TimeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $status = Read-CcodexStatusFile -JobDir $JobDir
        if ($status -and $status.status -in @('done', 'failed')) { return $status }
        if ((Get-Date) -ge $deadline) { return $status }
        Start-Sleep -Milliseconds 250
    }
}

# --- (a) survival through parent exit (startprocess mechanism) ---

Write-Host "Start-CcodexDetachedWorker (startprocess): worker outlives the submitting process"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'DETACH SURVIVAL OK'
$jobA = New-CcodexTestJob

$parentScriptPath = Join-Path $tempRoot 'detach-parent.ps1'
$parentScriptContent = @'
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [Parameter(Mandatory)][string]$StateRoot,
    [Parameter(Mandatory)][string]$CodexPath
)
. (Join-Path $RepoRoot 'lib\Detach.ps1')
Start-CcodexDetachedWorker -ScriptPath (Join-Path $RepoRoot 'ccodex.ps1') -JobId $JobId -WorkingDirectory $WorkingDirectory -StateRoot $StateRoot -CodexPath $CodexPath -Mechanism startprocess | Out-Null
'@
Write-CcodexTextFile -Path $parentScriptPath -Content $parentScriptContent

& pwsh -NoLogo -NoProfile -File $parentScriptPath -RepoRoot $repoRoot -JobId $jobA.JobId -WorkingDirectory $targetRepo -StateRoot $localAppData -CodexPath $fixtureCmd
Assert-Equal $LASTEXITCODE 0 'submitting parent process exits 0 after launching the detached worker'

$launchStatusA = $null
try {
    $launchStatusA = Wait-CcodexWorkerLaunch -JobDir $jobA.JobDir -TimeoutSec 20
    Assert-True $true 'sentinel observed the worker move off created before timing out'
} catch {
    Assert-True $false "sentinel unexpectedly timed out: $($_.Exception.Message)"
}
Assert-True ($launchStatusA -and $launchStatusA.status -ne 'created') 'sentinel-returned status is no longer created'

$terminalA = Wait-CcodexTestTerminalStatus -JobDir $jobA.JobDir -TimeoutSec 20
Assert-True ($terminalA -ne $null) 'job reached a terminal status object'
Assert-Equal $terminalA.status 'done' 'worker launched via startprocess reaches terminal done after the parent exited'

$resultMdA = Get-Content -LiteralPath (Join-Path $jobA.JobDir 'result.md') -Raw
Assert-True ($resultMdA -like '*DETACH SURVIVAL OK*') 'result.md carries the fixture result content written by the detached worker'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# --- (b) sentinel timeout when no worker is ever launched ---

Write-Host "Wait-CcodexWorkerLaunch: throws when the job is left in 'created' with no worker"
$jobB = New-CcodexTestJob
Assert-Throws { Wait-CcodexWorkerLaunch -JobDir $jobB.JobDir -TimeoutSec 1 } "sentinel throws after timeout with no worker ever launched"

# --- (c) cim mechanism smoke, env-independent ---

Write-Host "Start-CcodexDetachedWorker (cim): production mechanism launches a worker using only flags"
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
$jobC = New-CcodexTestJob

try {
    $childPidC = Start-CcodexDetachedWorker -ScriptPath $ccodexPs -JobId $jobC.JobId -WorkingDirectory $targetRepo -StateRoot $localAppData -CodexPath $fixtureCmd -Mechanism cim
    Assert-True ($childPidC -gt 0) 'cim launch returns a positive child pid'

    $launchStatusC = Wait-CcodexWorkerLaunch -JobDir $jobC.JobDir -TimeoutSec 20
    Assert-True ($launchStatusC -and $launchStatusC.status -ne 'created') 'cim-launched worker moved the job off created within the startup window'

    $terminalC = Wait-CcodexTestTerminalStatus -JobDir $jobC.JobDir -TimeoutSec 20
    Assert-True ($terminalC -ne $null) 'cim-launched job reached a terminal status object'
    Assert-Equal $terminalC.status 'done' 'worker launched via cim reaches terminal done using only command-line flags (no env dependence)'

    $resultMdC = Get-Content -LiteralPath (Join-Path $jobC.JobDir 'result.md') -Raw
    Assert-True (-not [string]::IsNullOrWhiteSpace($resultMdC)) 'cim-launched worker produced non-empty result.md content'
} catch {
    # Per the task brief, unavailability of CIM in the test environment must fail loudly,
    # never be silently skipped.
    Assert-True $false "cim mechanism smoke failed loudly: $($_.Exception.Message)"
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
