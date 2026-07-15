# tests/Doctor.tests.ps1
#
# Invoke-CcodexDoctorCommand (design: "doctor", Phase 2b Task 8). Follows the same
# dot-source-ccodex.ps1-with-ImportOnly pattern StatusWaitRead/CancelCommand/TailDebug use
# so the real dispatcher functions are exercised directly, plus a shell-level E2E layer
# (mirrors ReviewCommand/RealInvocation) proving the `doctor` dispatcher case wires
# --no-smoke/--repo/--codex-path/--state-root through correctly.
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
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\ccodex.ps1' -Resolve) -ImportOnly
. (Join-Path $PSScriptRoot '..\lib\Worker.ps1')
. (Join-Path $PSScriptRoot '..\lib\Detach.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fakeCmd = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-doctor-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $targetRepo -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

# Save/restore every fake-codex env var this file touches, mirroring CodexInvoke/ReviewCommand.
$savedVersionExit = $env:CCODEX_FAKE_VERSION_EXIT
$savedVersionText = $env:CCODEX_FAKE_VERSION
$savedDoctorExit = $env:CCODEX_FAKE_DOCTOR_EXIT
$savedDoctorOutput = $env:CCODEX_FAKE_DOCTOR_OUTPUT
$savedExit = $env:CCODEX_FAKE_EXIT_CODE
$savedResult = $env:CCODEX_FAKE_RESULT
$savedVersionDelay = $env:CCODEX_FAKE_VERSION_DELAY_MS
$savedDoctorDelay = $env:CCODEX_FAKE_DOCTOR_DELAY_MS

function Reset-CcodexDoctorFakeEnv {
    # All-green defaults for the fake-codex fixture across --version/doctor/exec argv.
    Remove-Item Env:\CCODEX_FAKE_VERSION_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:\CCODEX_FAKE_VERSION -ErrorAction SilentlyContinue
    Remove-Item Env:\CCODEX_FAKE_DOCTOR_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:\CCODEX_FAKE_DOCTOR_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item Env:\CCODEX_FAKE_VERSION_DELAY_MS -ErrorAction SilentlyContinue
    Remove-Item Env:\CCODEX_FAKE_DOCTOR_DELAY_MS -ErrorAction SilentlyContinue
    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'OK'
}

try {
    # ============================================================
    # (a) all-green path with --no-smoke: every environment check passes -> exit 0
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: all-green with -NoSmoke exits 0 and prints every ok check"
    $resultGreen = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultGreen.WrapperExitCode 0 'all-green + --no-smoke exits 0'
    Assert-True (-not [string]::IsNullOrEmpty($resultGreen.Stdout)) 'all-green result carries stdout'
    Assert-True ($resultGreen.Stdout -like '*ok codex resolvable:*') 'codex-resolvable check reports ok'
    Assert-True ($resultGreen.Stdout -like "*$fakeCmd*") 'codex-resolvable check names the resolved path'
    Assert-True ($resultGreen.Stdout -like '*ok codex doctor:*') 'codex-doctor delegation check reports ok'
    Assert-True ($resultGreen.Stdout -like '*ok state root writable:*') 'state-root-writable check reports ok'
    Assert-True ($resultGreen.Stdout -like '*ok worker prompt template:*') 'template-present check reports ok'
    Assert-True ($resultGreen.Stdout -like '*ok index/jobs consistency: dangling_indexes=*unindexed_job_dirs=*') 'index/jobs consistency check reports counts'
    Assert-True ($resultGreen.Stdout -like '*ok smoke test: skipped (--no-smoke)*') 'smoke check reports skipped under --no-smoke'

    # ============================================================
    # (b) unwritable state root (points at a file, not a directory) -> FAIL + exit 12
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: state root pointed at a file (not a dir) -> FAIL line + exit 12"
    $badStateRootFile = Join-Path $tempRoot 'not-a-directory.txt'
    [System.IO.File]::WriteAllText($badStateRootFile, 'not a directory', $utf8NoBom)
    $resultBadRoot = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $badStateRootFile -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultBadRoot.WrapperExitCode 12 'unwritable state root exits 12'
    Assert-True ([string]::IsNullOrEmpty($resultBadRoot.Stdout)) 'a failing doctor run carries no Stdout (Message only, matching the dispatcher convention)'
    Assert-True ($resultBadRoot.Message -like '*FAIL state root writable:*') 'unwritable state root produces a FAIL line'
    Assert-True ($resultBadRoot.Message -like '*ok codex resolvable:*') 'other checks still ran and reported ok'
    Assert-True ($resultBadRoot.Message -like '*ok worker prompt template:*') 'template check (independent of the bad state root) still reports ok'

    # ============================================================
    # (c) live smoke through the normal run pipeline against the fixture -> exit 0 + OK
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: smoke test against the fixture -> exit 0 with result 'OK'"
    $resultSmokeOk = Invoke-CcodexDoctorCommand -NoSmoke $false -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultSmokeOk.WrapperExitCode 0 'passing smoke test exits 0'
    Assert-True ($resultSmokeOk.Stdout -like "*ok smoke test: result 'OK'*") 'smoke check reports the OK result'

    # ============================================================
    # (d) codex doctor delegation itself fails -> FAIL line + full output block + exit 12
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: 'codex doctor' nonzero exit -> FAIL line, raw output not swallowed, exit 12"
    $env:CCODEX_FAKE_DOCTOR_EXIT = '1'
    $env:CCODEX_FAKE_DOCTOR_OUTPUT = 'sandbox check: failed to spawn child process'
    $resultDoctorFail = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultDoctorFail.WrapperExitCode 12 "'codex doctor' failure exits 12"
    Assert-True ($resultDoctorFail.Message -like '*FAIL codex doctor: exited 1*') "'codex doctor' FAIL line names its exit code"
    Assert-True ($resultDoctorFail.Message -like '*sandbox check: failed to spawn child process*') "'codex doctor' full output is surfaced, not swallowed"

    # ============================================================
    # (e) environment green but the live smoke fails -> FAIL line + exit 10
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: environment green, smoke fails -> FAIL line + exit 10"
    $env:CCODEX_FAKE_EXIT_CODE = '1'
    $resultSmokeFail = Invoke-CcodexDoctorCommand -NoSmoke $false -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultSmokeFail.WrapperExitCode 10 'a failing smoke test (env otherwise green) exits 10'
    Assert-True ($resultSmokeFail.Message -like '*FAIL smoke test:*') 'smoke failure produces a FAIL line'
    Assert-True ($resultSmokeFail.Message -like '*ok codex resolvable:*') 'environment checks still reported ok alongside the smoke failure'

    # ============================================================
    # (f) index/jobs consistency counts are informational: nonzero counts never fail it
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: dangling index + unindexed job dir are counted but never fail the check"
    $consistencyRoot = Join-Path $tempRoot 'consistency-local'
    New-Item -ItemType Directory -Path $consistencyRoot -Force | Out-Null
    $repoKeyForConsistency = Get-CcodexRepoKey -RepoRoot $targetRepo
    # A dangling index: an index entry whose job_dir does not exist.
    $danglingIndexPath = Get-CcodexIndexPath -JobId 'dangling-job-id' -Root $consistencyRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $danglingIndexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $danglingIndexPath -Object ([ordered]@{ job_id = 'dangling-job-id'; repo_key = $repoKeyForConsistency; job_dir = (Join-Path $consistencyRoot 'ccodex\jobs\nonexistent') })
    # An unindexed job dir: a real job dir reserved without ever writing its index entry.
    $unindexedReservation = Reserve-CcodexJobDir -RepoKey $repoKeyForConsistency -Mode 'review' -Root $consistencyRoot
    $resultConsistency = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $consistencyRoot -AppDataRoot $appData -RepoOverride $targetRepo
    Assert-Equal $resultConsistency.WrapperExitCode 0 'nonzero dangling/unindexed counts do not fail the doctor run'
    Assert-True ($resultConsistency.Stdout -like '*ok index/jobs consistency: dangling_indexes=1 unindexed_job_dirs=1*') 'the consistency check reports the exact dangling/unindexed counts'

    # ============================================================
    # (g) a bad --repo is a usage error (exit 2), same as run/review
    # ============================================================
    Write-Host "Invoke-CcodexDoctorCommand: nonexistent --repo -> exit 2 usage error"
    $resultBadRepo = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride (Join-Path $tempRoot 'does-not-exist')
    Assert-Equal $resultBadRepo.WrapperExitCode 2 'a nonexistent --repo exits 2'
    Assert-True ($resultBadRepo.Message -like '*--repo*') 'the usage error names --repo'

    # ============================================================
    # (h) a hung 'codex --version' probe is bounded by ProbeTimeoutSec -> FAIL + exit 12
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: a hung 'codex --version' probe times out -> FAIL line + exit 12"
    $env:CCODEX_FAKE_VERSION_DELAY_MS = '10000'
    $resultVersionHang = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo -ProbeTimeoutSec 1
    Assert-Equal $resultVersionHang.WrapperExitCode 12 'a hung --version probe (bounded by ProbeTimeoutSec) exits 12 rather than hanging'
    Assert-True ($resultVersionHang.Message -like "*FAIL codex resolvable: 'codex --version' timed out after 1s*") 'the hung --version probe reports a timeout FAIL line'
    Remove-Item Env:\CCODEX_FAKE_VERSION_DELAY_MS -ErrorAction SilentlyContinue

    # ============================================================
    # (i) a hung 'codex doctor' probe is bounded by ProbeTimeoutSec -> FAIL + exit 12
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorCommand: a hung 'codex doctor' probe times out -> FAIL line + exit 12"
    # This is the one scenario whose assertions need a probe to SUCCEED within the bound (the
    # --version probe must finish before ProbeTimeoutSec while the doctor probe hangs). A 1s
    # bound flaked on a loaded desktop where pwsh cold-start alone took 3-7s (observed
    # 2026-07-13), so the bound is 15s here — the doctor delay just has to exceed it.
    $env:CCODEX_FAKE_DOCTOR_DELAY_MS = '30000'
    $resultDoctorHang = Invoke-CcodexDoctorCommand -NoSmoke $true -CodexPath $fakeCmd -StateRoot $localAppData -AppDataRoot $appData -RepoOverride $targetRepo -ProbeTimeoutSec 15
    Assert-Equal $resultDoctorHang.WrapperExitCode 12 'a hung doctor probe (bounded by ProbeTimeoutSec) exits 12 rather than hanging'
    Assert-True ($resultDoctorHang.Message -like '*FAIL codex doctor: timed out after 15s*') 'the hung doctor probe reports a timeout FAIL line'
    Assert-True ($resultDoctorHang.Message -like '*ok codex resolvable:*') 'the fast --version probe still reported ok alongside the doctor timeout'
    Remove-Item Env:\CCODEX_FAKE_DOCTOR_DELAY_MS -ErrorAction SilentlyContinue

    # ============================================================
    # (j) Stop-CcodexProcessTree fails to kill a hung probe -> the bounded fallback
    #     (second wait + Process.Kill($true)) still terminates it; doctor never hangs
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "Invoke-CcodexDoctorProbe: Stop-CcodexProcessTree fails to kill -> bounded Kill(`$true) fallback still terminates the probe (no hang)"
    $env:CCODEX_FAKE_VERSION_DELAY_MS = '10000'
    # Shadow Stop-CcodexProcessTree as a no-op: simulates a taskkill failure that is silently
    # swallowed (Stop-CcodexProcessTree is best-effort in production). Without the bounded
    # second wait + Kill($true) fallback, Invoke-CcodexDoctorProbe's old parameterless
    # WaitForExit() would then block for as long as the fixture happens to sleep (10s here --
    # and unboundedly long against a genuinely hung real codex process).
    function Stop-CcodexProcessTree { param([int]$ProcessId) }
    $probeStart = Get-Date
    try {
        $probeResult = Invoke-CcodexDoctorProbe -CodexPath $fakeCmd -Arguments @('--version') -TimeoutSec 1
    } finally {
        # Restore the real Stop-CcodexProcessTree immediately so the no-op shadow cannot
        # leak into any later in-process test in this file.
        . (Join-Path $repoRoot 'lib\CodexInvoke.ps1')
    }
    $probeElapsed = (Get-Date) - $probeStart
    Assert-True $probeResult.TimedOut 'the probe reports TimedOut when the wait exceeds TimeoutSec'
    Assert-Equal $probeResult.ExitCode $null 'a timed-out probe has no exit code'
    Assert-Equal $probeResult.TerminationFailed $false 'a timed-out probe reports that the fallback did terminate it'
    Assert-True ($probeElapsed.TotalSeconds -lt 8) "the probe returns within its own bounded fallback window (~6s), well before the fixture's full 10s delay -- proving Process.Kill(`$true) (not the fixture exiting on its own) ended it"
    Remove-Item Env:\CCODEX_FAKE_VERSION_DELAY_MS -ErrorAction SilentlyContinue

    # ============================================================
    # shell-level: `ccodex.ps1 doctor` dispatcher wiring
    # ============================================================
    Reset-CcodexDoctorFakeEnv
    Write-Host "shell-level: ccodex.ps1 doctor --no-smoke --codex-path <fixture> --state-root <root> --repo <repo> exits 0"
    $shellGreenOut = & pwsh -NoLogo -NoProfile -File $ccodexPs doctor --no-smoke --codex-path $fakeCmd --state-root $localAppData --repo $targetRepo
    $shellGreenExit = $LASTEXITCODE
    Assert-Equal $shellGreenExit 0 'shell-level doctor --no-smoke exits 0'
    $shellGreenText = ($shellGreenOut -join "`n")
    Assert-True ($shellGreenText -like '*ok codex resolvable:*') 'shell-level output includes the codex-resolvable check'
    Assert-True ($shellGreenText -like '*ok smoke test: skipped*') 'shell-level output reflects --no-smoke'

    Write-Host "shell-level: ccodex.ps1 doctor (smoke enabled by default) prints the fixture result OK, exits 0"
    $shellSmokeOut = & pwsh -NoLogo -NoProfile -File $ccodexPs doctor --codex-path $fakeCmd --state-root $localAppData --repo $targetRepo
    $shellSmokeExit = $LASTEXITCODE
    Assert-Equal $shellSmokeExit 0 'shell-level doctor with the smoke enabled exits 0 against the fixture'
    Assert-True ((($shellSmokeOut -join "`n")) -like "*result 'OK'*") 'shell-level smoke output shows the OK result'

    Write-Host "shell-level: unknown command message names doctor among the supported commands"
    $shellUnknownOut = & pwsh -NoLogo -NoProfile -File $ccodexPs bogus-command
    $shellUnknownExit = $LASTEXITCODE
    Assert-Equal $shellUnknownExit 2 'an unknown command exits 2'
    Assert-True ((($shellUnknownOut -join "`n")) -like '*doctor*') 'the supported-commands message now lists doctor'
} finally {
    $env:CCODEX_FAKE_VERSION_EXIT = $savedVersionExit
    $env:CCODEX_FAKE_VERSION = $savedVersionText
    $env:CCODEX_FAKE_DOCTOR_EXIT = $savedDoctorExit
    $env:CCODEX_FAKE_DOCTOR_OUTPUT = $savedDoctorOutput
    $env:CCODEX_FAKE_EXIT_CODE = $savedExit
    $env:CCODEX_FAKE_RESULT = $savedResult
    $env:CCODEX_FAKE_VERSION_DELAY_MS = $savedVersionDelay
    $env:CCODEX_FAKE_DOCTOR_DELAY_MS = $savedDoctorDelay
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-CcodexTests
