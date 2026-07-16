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

function New-CcodexSubmitResumeParent {
    param(
        [string]$Status = 'done',
        [string]$Access = 'read-only',
        [AllowNull()][string]$ThreadId = 'thread-submit-parent',
        [string]$Group = 'parent-group',
        [string]$Label = 'parent-label'
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode 'brainstorm' -Root $localAppData
    $indexPath = Get-CcodexIndexPath -JobId $reservation.JobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $reservation.JobId; repo_key = $repoKey; job_dir = $reservation.JobDir })
    $statusObject = New-CcodexStatusObject -JobId $reservation.JobId -Status $Status -Mode 'brainstorm' -Access $Access -Repo $targetRepo -CreatedAt ((Get-Date).ToString('o')) -Backend 'sync' -CodexThreadId $ThreadId -Group $Group -Label $Label
    Write-CcodexJsonFileAtomic -Path (Join-Path $reservation.JobDir 'status.json') -Object $statusObject
    return [pscustomobject]@{ JobId = $reservation.JobId; JobDir = $reservation.JobDir }
}

function Get-CcodexSubmitJobDirCount {
    $jobsRoot = Join-Path (Get-CcodexLocalAppDataRoot -Root $localAppData) 'jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $jobsRoot -Directory -Recurse | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'status.json') -PathType Leaf }).Count
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

$terminalA = Wait-CcodexTestTerminalStatus -JobDir $resultA.JobDir -TimeoutSec 40
Assert-True ($terminalA -ne $null) 'job reaches a terminal status object'
Assert-Equal $terminalA.status 'done' 'submitted job reaches terminal done via the detached worker'
Assert-Equal $terminalA.backend 'native' 'terminal status is stamped backend native'
Assert-True ([string]::IsNullOrEmpty($terminalA.group)) 'submit without --group records null group'
Assert-True ([string]::IsNullOrEmpty($terminalA.label)) 'submit without --label records null label'

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
Assert-True ($resultD.Message -like "*did not start within 0s*") 'explicit zero timeout reports the timeout path, not a generic exit-23 failure'

Write-Host "Invoke-CcodexSubmit: CCODEX_STARTUP_TIMEOUT_SEC=0 is honored when no explicit timeout is bound"
$savedStartupTimeout = $env:CCODEX_STARTUP_TIMEOUT_SEC
try {
    $env:CCODEX_STARTUP_TIMEOUT_SEC = '0'
    $envTimeoutResult = Invoke-CcodexSubmitForTest -Overrides @{ WorkerScriptPath = $stubWorkerPs }
    Assert-Equal $envTimeoutResult.WrapperExitCode 23 'environment startup timeout of zero produces wrapper exit 23'
    Assert-True ($envTimeoutResult.Message -like "*did not start within 0s*") 'environment override reaches the timeout sentinel with the configured zero-second value'

    $env:CCODEX_STARTUP_TIMEOUT_SEC = 'abc'
    $explicitTimeoutResult = Invoke-CcodexSubmitForTest -Overrides @{ StartupTimeoutSec = 0; WorkerScriptPath = $stubWorkerPs }
    Assert-Equal $explicitTimeoutResult.WrapperExitCode 23 'explicit startup timeout wins over an invalid environment override'
    Assert-True ($explicitTimeoutResult.Message -like "*did not start within 0s*") 'explicit timeout winner takes the timeout path and reports its bound value'

    $beforeInvalidEnv = Get-CcodexSubmitJobDirCount
    $invalidEnvResult = Invoke-CcodexSubmitForTest -Overrides @{ WorkerScriptPath = $stubWorkerPs }
    Assert-Equal $invalidEnvResult.WrapperExitCode 2 'invalid CCODEX_STARTUP_TIMEOUT_SEC exits 2'
    Assert-True ($invalidEnvResult.Message -like '*CCODEX_STARTUP_TIMEOUT_SEC*abc*') 'invalid environment error names the variable and bad value'
    Assert-True ([string]::IsNullOrEmpty($invalidEnvResult.JobDir)) 'invalid environment override is rejected before a job directory is reserved'
    Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeInvalidEnv 'invalid environment override does not change the job directory count'
} finally {
    if ($null -eq $savedStartupTimeout) {
        Remove-Item Env:\CCODEX_STARTUP_TIMEOUT_SEC -ErrorAction SilentlyContinue
    } else {
        $env:CCODEX_STARTUP_TIMEOUT_SEC = $savedStartupTimeout
    }
}

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

# --- (g) shell-level: submit --hard-timeout-sec -1 / non-numeric is a usage error (exit 2) ---

Write-Host "ConvertTo-CcodexHardTimeoutSec: 0 and positive integers parse; negative/non-numeric throw naming the flag"
Assert-Equal (ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '0') 0 '0 (never) parses as a valid value'
Assert-Equal (ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '120') 120 'a positive integer parses through unchanged'
Assert-Throws { ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText '-1' } 'a negative value throws instead of silently becoming 0/never'
Assert-True ($script:CcodexLastError -like '*--hard-timeout-sec*') 'the negative-value error names the flag'
Assert-Throws { ConvertTo-CcodexHardTimeoutSec -FlagName '--hard-timeout-sec' -ValueText 'abc' } 'non-numeric text throws instead of an unrelated internal error'
Assert-True ($script:CcodexLastError -like '*--hard-timeout-sec*') 'the non-numeric-value error names the flag'

Write-Host "shell-level: submit --hard-timeout-sec -1 / non-numeric is a usage error (exit 2), no worker ever launched"
# Dispatcher-level check (mirrors RunCommand.tests.ps1): the flag-parsing/validation lives
# in ccodex.ps1's own `switch ($Command)` block, before Invoke-CcodexSubmit is ever called,
# so it can only be exercised through a real process invocation. --state-root/--codex-path
# are passed defensively (never the real profile / never a real codex launch) in case
# validation regresses and control falls through to job creation.
$negativeSubmitOut = "unused task text" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess --hard-timeout-sec -1
Assert-Equal $LASTEXITCODE 2 'submit --hard-timeout-sec -1 exits 2'
Assert-True ((($negativeSubmitOut -join "`n")) -like '*--hard-timeout-sec*') 'usage error names the --hard-timeout-sec flag (negative value)'

$nonNumericSubmitOut = "unused task text" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess --hard-timeout-sec abc
Assert-Equal $LASTEXITCODE 2 'submit --hard-timeout-sec abc exits 2'
Assert-True ((($nonNumericSubmitOut -join "`n")) -like '*--hard-timeout-sec*') 'usage error names the --hard-timeout-sec flag (non-numeric value)'

# --- (h) shell-level: submit --model/--effort threads through to the detached worker ---

Write-Host "shell-level: submit --model/--effort reaches the detached worker; the worker's command.txt records -m/-c"
# The worker re-derives command.txt from the job on startup, so model/effort must reach it via
# the worker launch command line (NOT status.json). Waiting for terminal proves the worker's
# own re-derived command.txt carries the flags -- true end-to-end passthrough, not just submit's
# pre-launch diagnostics.
$savedAppData2 = $env:APPDATA
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'SUBMIT MODEL EFFORT OK'
try {
    $env:APPDATA = $appData
    $meOut = "review this please" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess --model gpt-5-codex --effort high
    Assert-Equal $LASTEXITCODE 0 'shell-level submit with --model/--effort exits 0'
    $meLines = @($meOut | Where-Object { $_ -ne $null -and $_ -ne '' })
    $meJobDir = $meLines[1]
    $meTerminal = Wait-CcodexTestTerminalStatus -JobDir $meJobDir -TimeoutSec 20
    Assert-True ($meTerminal -ne $null) 'submitted model/effort job reaches a terminal status object'
    Assert-Equal $meTerminal.status 'done' 'submitted model/effort job reaches terminal done via the detached worker'
    $meCommand = Get-Content -LiteralPath (Join-Path $meJobDir 'command.txt') -Raw
    Assert-True ($meCommand -like '*-m gpt-5-codex -c model_reasoning_effort=high -*') 'the worker-derived command.txt carries -m/-c before the trailing - (model/effort threaded through the worker launch)'
} finally {
    $env:APPDATA = $savedAppData2
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
}

Write-Host "shell-level: submit --effort turbo is a usage error (exit 2), no worker ever launched"
$badEffortSubmitOut = "unused task text" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess --effort turbo
Assert-Equal $LASTEXITCODE 2 'submit --effort turbo exits 2'
Assert-True ((($badEffortSubmitOut -join "`n")) -like '*--effort*') 'usage error names the --effort flag (invalid value)'

$env:CCODEX_FAKE_EXIT_CODE = '0'; $env:CCODEX_FAKE_RESULT = 'submit metadata ok'
$metaOut = "metadata" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess --group sg --label sl
Assert-Equal $LASTEXITCODE 0 'submit --group/--label exits 0'
$metaDir = @($metaOut | Where-Object { $_ })[1]
$metaTerminal = Wait-CcodexTestTerminalStatus -JobDir $metaDir -TimeoutSec 20
Assert-Equal $metaTerminal.group 'sg' 'submit group survives worker rewrites'
Assert-Equal $metaTerminal.label 'sl' 'submit label survives worker rewrites'
$bareLabelOut = "unused" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --label
Assert-Equal $LASTEXITCODE 2 'submit bare --label exits 2'
$bareGroupOut = "unused" | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --mode review --repo $targetRepo --state-root $localAppData --group
Assert-Equal $LASTEXITCODE 2 'submit bare --group exits 2'

# --- (i) submit --resume validates synchronously and creates an inherited async child ---

Write-Host "Invoke-CcodexSubmit: --resume parent preconditions fail synchronously before reserving a child"
$beforeUnknown = Get-CcodexSubmitJobDirCount
$unknownAsyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = 'missing-submit-parent' }
Assert-Equal $unknownAsyncResume.WrapperExitCode 3 'submit --resume unknown parent exits 3'
Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeUnknown 'unknown parent creates no child job dir'

$missingDirParent = New-CcodexSubmitResumeParent
Remove-Item -LiteralPath $missingDirParent.JobDir -Recurse -Force
$beforeMissingDir = Get-CcodexSubmitJobDirCount
$missingDirAsyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = $missingDirParent.JobId }
Assert-Equal $missingDirAsyncResume.WrapperExitCode 3 'submit --resume indexed parent with a missing job dir exits 3'
Assert-True ($missingDirAsyncResume.Message -like '*index entry exists but its job directory is missing*') 'missing-parent-dir message matches synchronous resume'
Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeMissingDir 'missing parent job dir creates no child job dir'

$runningParent = New-CcodexSubmitResumeParent -Status 'running'
$beforeRunning = Get-CcodexSubmitJobDirCount
$runningAsyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = $runningParent.JobId }
Assert-Equal $runningAsyncResume.WrapperExitCode 4 'submit --resume non-terminal parent exits 4'
Assert-True ($runningAsyncResume.Message -like "*$($runningParent.JobId)*running*") 'non-terminal message names the parent id and status'
Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeRunning 'non-terminal parent creates no child job dir'

$worktreeParent = New-CcodexSubmitResumeParent -Access 'worktree'
$beforeWorktree = Get-CcodexSubmitJobDirCount
$worktreeAsyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = $worktreeParent.JobId }
Assert-Equal $worktreeAsyncResume.WrapperExitCode 2 'submit --resume worktree parent exits 2'
Assert-True ($worktreeAsyncResume.Message -like '*resume is not supported for worktree jobs*') 'worktree rejection uses the resume precondition message'
Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeWorktree 'worktree parent creates no child job dir'

$scrubbedParent = New-CcodexSubmitResumeParent -ThreadId $null
$beforeScrubbed = Get-CcodexSubmitJobDirCount
$scrubbedAsyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = $scrubbedParent.JobId }
Assert-Equal $scrubbedAsyncResume.WrapperExitCode 2 'submit --resume scrubbed parent exits 2'
Assert-True ($scrubbedAsyncResume.Message -like '*no codex thread id (absent or scrubbed by cleanup)*') 'scrubbed-thread rejection uses the resume precondition message'
Assert-Equal (Get-CcodexSubmitJobDirCount) $beforeScrubbed 'scrubbed parent creates no child job dir'

Write-Host "Invoke-CcodexSubmit: --resume success returns the plain-submit shape and seeds inherited lineage metadata"
$asyncParent = New-CcodexSubmitResumeParent
$env:CCODEX_FAKE_EXIT_CODE = '0'
$env:CCODEX_FAKE_RESULT = 'ASYNC RESUME SUBMIT OK'
$asyncResume = Invoke-CcodexSubmitForTest -Overrides @{ ResumeParentJobId = $asyncParent.JobId; PositionalTask = 'follow-up text only'; Mode = $null; Access = $null; RepoOverride = $null }
Assert-Equal $asyncResume.WrapperExitCode 0 'submit --resume successful launch exits 0'
Assert-Equal @($asyncResume.Stdout -split "`n").Count 2 'submit --resume stdout is exactly two lines'
$asyncResumeStatus = Read-CcodexStatusFile -JobDir $asyncResume.JobDir
Assert-Equal $asyncResumeStatus.parent_job_id $asyncParent.JobId 'async child carries parent_job_id from creation onward'
Assert-Equal $asyncResumeStatus.codex_thread_id 'thread-submit-parent' 'async child carries the parent thread id from creation onward'
Assert-Equal $asyncResumeStatus.mode 'brainstorm' 'async child inherits parent mode'
Assert-Equal $asyncResumeStatus.access 'read-only' 'async child inherits parent access'
Assert-Equal $asyncResumeStatus.repo $targetRepo 'async child inherits parent repo'
Assert-Equal $asyncResumeStatus.group 'parent-group' 'async child inherits parent group'
Assert-Equal $asyncResumeStatus.label 'parent-label' 'async child inherits parent label'
Assert-Equal $asyncResumeStatus.backend 'native' 'async child uses the native detached backend'
Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $asyncResume.JobDir 'prompt.md'))) 'follow-up text only' 'async child prompt.md contains only the follow-up text'
$asyncResumeCommand = Get-Content -LiteralPath (Join-Path $asyncResume.JobDir 'command.txt') -Raw
Assert-True ($asyncResumeCommand -like '*resume thread-submit-parent -*') 'async child command.txt contains resume <thread-id> before trailing stdin dash'
$asyncResumeTerminal = Wait-CcodexTestTerminalStatus -JobDir $asyncResume.JobDir -TimeoutSec 20
Assert-Equal $asyncResumeTerminal.status 'done' 'async resumed child completes through the detached worker'
Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

Write-Host "shell-level: submit --resume requires a value and rejects inherited-context flags"
$missingResumeValueOut = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexPs submit --resume --state-root $localAppData --codex-path $fixtureCmd --detach-mechanism startprocess 2>&1
Assert-Equal $LASTEXITCODE 2 'submit --resume without a value exits 2'
Assert-True ((($missingResumeValueOut -join "`n")) -like '*--resume*requires a value*') 'missing --resume value error names the flag'

foreach ($flagCase in @(
    @{ Flag = '--mode'; Value = 'review' },
    @{ Flag = '--access'; Value = 'read-only' },
    @{ Flag = '--repo'; Value = $targetRepo },
    @{ Flag = '--group'; Value = 'override-group' },
    @{ Flag = '--label'; Value = 'override-label' }
)) {
    $rejectArgs = @('submit', '--resume', $asyncParent.JobId, $flagCase.Flag, $flagCase.Value, '--state-root', $localAppData, '--codex-path', $fixtureCmd, '--detach-mechanism', 'startprocess')
    $rejectOut = 'follow up' | & pwsh -NoLogo -NoProfile -File $ccodexPs @rejectArgs 2>&1
    Assert-Equal $LASTEXITCODE 2 "submit --resume with $($flagCase.Flag) exits 2"
    Assert-True ((($rejectOut -join "`n")) -like '*inherits mode, access, repo, group, and label from the parent job*') "submit --resume $($flagCase.Flag) rejection explains inheritance"
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
