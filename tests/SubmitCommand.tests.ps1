# tests/SubmitCommand.tests.ps1
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
$stubWorkerPs = Join-Path $PSScriptRoot 'fixtures\stub-worker.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-submitcommand-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
New-Item -ItemType Directory -Path $localAppData, $appData -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $targetRepo -Force | Out-Null

function Invoke-CcodexSubmitForTest {
    param([hashtable]$Overrides = @{})
    $base = @{
        Mode             = 'review'
        Access           = $null
        RepoOverride     = $targetRepo
        PromptFile       = $null
        PositionalTask   = 'do the review'
        PipelineExpected = $false
        PipelineObjects  = $null
        DetachMechanism  = 'startprocess'
        CodexPath        = $fixtureCmd
        LocalAppDataRoot = $localAppData
        AppDataRoot      = $appData
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return Invoke-CcodexSubmit @base
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

# --- (a) success: submit returns immediately, worker finishes the job in the background ---

Write-Host "Invoke-CcodexSubmit: success returns 0 with job id + job dir, worker completes in background"
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SUBMIT RESULT OK'
$resultA = Invoke-CcodexSubmitForTest
Assert-Equal $resultA.WrapperExitCode 0 'wrapper exit code is 0 on successful launch'

$stdoutLinesA = $resultA.Stdout -split "`n"
Assert-Equal $stdoutLinesA.Count 2 'stdout is exactly two lines: job id then job dir'
Assert-True ($stdoutLinesA[0] -match '^\d{8}T\d{6}Z-[a-z0-9]{8}-review$') 'first stdout line matches the Phase 1 job-id shape'
Assert-Equal $stdoutLinesA[0] $resultA.JobId 'first stdout line equals the returned JobId'
Assert-Equal $stdoutLinesA[1] $resultA.JobDir 'second stdout line equals the returned JobDir'
Assert-True (Test-Path -LiteralPath $resultA.JobDir -PathType Container) 'job dir exists'

foreach ($file in @('prompt.md', 'command.txt', 'debug.json', 'status.json')) {
    Assert-True (Test-Path -LiteralPath (Join-Path $resultA.JobDir $file) -PathType Leaf) "writes $file before/at submit return"
}

$terminalA = Wait-CcodexTestTerminalStatus -JobDir $resultA.JobDir -TimeoutSec 20
Assert-True ($terminalA -ne $null) 'job reaches a terminal status object'
Assert-Equal $terminalA.status 'done' 'submitted job reaches terminal done via the detached worker'
Assert-Equal $terminalA.backend 'native' 'terminal status is stamped backend native'

$resultMdA = Get-Content -LiteralPath (Join-Path $resultA.JobDir 'result.md') -Raw
Assert-True ($resultMdA -like '*SUBMIT RESULT OK*') 'result.md carries the fixture result content written by the detached worker'

Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

# --- (b) mode 'test' without --access workspace fails before any worker is launched ---

Write-Host "Invoke-CcodexSubmit: mode 'test' without --access fails with 2, no worker launched"
$resultB = Invoke-CcodexSubmitForTest -Overrides @{ Mode = 'test'; Access = $null }
Assert-Equal $resultB.WrapperExitCode 2 'exit code 2 for test mode without --access workspace'
Assert-True (-not [string]::IsNullOrEmpty($resultB.JobDir)) 'job dir was still reserved (access failure happens post-reservation)'
Start-Sleep -Milliseconds 500
$statusB = Get-Content -LiteralPath (Join-Path $resultB.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusB.status 'failed' 'usage-error job stays terminal failed, never running (no worker was launched)'

# --- (c) unresolvable repo fails with 2 before any job dir is reserved ---

Write-Host "Invoke-CcodexSubmit: unresolvable repo fails with 2, no job dir"
$missingRepo = Join-Path $tempRoot 'no-such-repo-dir'
$resultC = Invoke-CcodexSubmitForTest -Overrides @{ RepoOverride = $missingRepo }
Assert-Equal $resultC.WrapperExitCode 2 'exit code 2 for an unresolvable repo'
Assert-True ([string]::IsNullOrEmpty($resultC.JobDir)) 'no job dir is reserved when repo resolution fails'

# --- (d) sentinel timeout: a worker that never stamps startup -> wrapper 23, status stays created ---

Write-Host "Invoke-CcodexSubmit: startup sentinel timeout (worker never stamps startup) -> 23, status stays created"
$resultD = Invoke-CcodexSubmitForTest -Overrides @{ StartupTimeoutSec = 0; WorkerScriptPath = $stubWorkerPs }
Assert-Equal $resultD.WrapperExitCode 23 'wrapper exit code is 23 when the startup sentinel times out'
Assert-True (-not [string]::IsNullOrEmpty($resultD.Message)) 'a diagnostic message is returned on sentinel timeout'
Assert-True (-not [string]::IsNullOrEmpty($resultD.JobDir)) 'job dir remains available for diagnosis'
$statusD = Get-Content -LiteralPath (Join-Path $resultD.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusD.status 'created' 'status.json is left untouched (still created) after a sentinel timeout'

# --- (e) shell-level: pwsh -File ccodex.ps1 submit ... --state-root ... --detach-mechanism startprocess ---

Write-Host "shell-level: piped prompt through ccodex.ps1 submit prints exactly two stdout lines, no JSONL/result content"
$savedAppData = $env:APPDATA
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SHELL SUBMIT OK'
try {
    $env:APPDATA = $appData
    $out = "review this please" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess
    $shellExit = $LASTEXITCODE
    Assert-Equal $shellExit 0 'shell-level submit invocation exits 0'
    $outLines = @($out | Where-Object { $_ -ne $null -and $_ -ne '' })
    Assert-Equal $outLines.Count 2 'shell-level submit prints exactly two non-empty stdout lines'
    Assert-True ($outLines[0] -match '^\d{8}T\d{6}Z-[a-z0-9]{8}-review$') 'first shell-level stdout line is a job id'
    Assert-True (Test-Path -LiteralPath $outLines[1] -PathType Container) 'second shell-level stdout line is an existing job dir'
    Assert-True (-not (($out -join "`n") -like '*fake-codex ran*')) 'raw JSONL events never reach stdout'
    Assert-True (-not (($out -join "`n") -like '*SHELL SUBMIT OK*')) 'result content never reaches stdout from submit (only job id + job dir)'

    $shellTerminal = Wait-CcodexTestTerminalStatus -JobDir $outLines[1] -TimeoutSec 20
    Assert-True ($shellTerminal -ne $null) 'shell-level submitted job reaches a terminal status object'
    Assert-Equal $shellTerminal.status 'done' 'shell-level submitted job reaches terminal done via the detached worker'
} finally {
    $env:APPDATA = $savedAppData
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
}

# --- (f) nonexistent --codex-path fails pre-launch: never leaves the job stuck at created ---

Write-Host "Invoke-CcodexSubmit: nonexistent --codex-path fails pre-launch with 12, writes terminal failed status.json + worker-complete.json, no worker launched"
$missingCodexPath = Join-Path $tempRoot 'no-such-codex.exe'
$resultF = Invoke-CcodexSubmitForTest -Overrides @{ CodexPath = $missingCodexPath }
Assert-Equal $resultF.WrapperExitCode 12 'wrapper exit code is 12 when the codex path cannot be resolved/launched'
Assert-True (-not [string]::IsNullOrEmpty($resultF.JobDir)) 'job dir was still reserved before the codex-path failure'
$statusF = Get-Content -LiteralPath (Join-Path $resultF.JobDir 'status.json') -Raw | ConvertFrom-Json
Assert-Equal $statusF.status 'failed' 'submit pre-launch codex-path failure leaves a terminal failed status.json (never stuck at created)'
Assert-Equal $statusF.wrapper_exit_code 12 'terminal failed status.json records wrapper_exit_code 12'
Assert-True (Test-Path -LiteralPath (Join-Path $resultF.JobDir 'worker-complete.json') -PathType Leaf) 'worker-complete.json evidence is written pre-launch on codex-path failure'
$completeF = Get-Content -LiteralPath (Join-Path $resultF.JobDir 'worker-complete.json') -Raw | ConvertFrom-Json
Assert-Equal $completeF.status_candidate 'failed' 'worker-complete.json status_candidate is failed'
Assert-Equal $completeF.wrapper_exit_code 12 'worker-complete.json records wrapper_exit_code 12'

$statusResultF = Invoke-CcodexStatusCommand -JobId $resultF.JobId -StateRoot $localAppData
Assert-True ($statusResultF.Stdout -like "*failed*") 'status command reports failed, not created, after the submit fix'

$readResultF = Invoke-CcodexReadCommand -JobId $resultF.JobId -StateRoot $localAppData
Assert-Equal $readResultF.WrapperExitCode 11 'read exits 11 for a terminal failed job with no result.md'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
