# tests/Characterization.tests.ps1
#
# Byte-identity guard for the backlog #14 dispatcher -> command-registry migration (issue #1,
# amendment 10). The EXISTING per-command shell-level suites are the primary behavior guard; this
# file adds the shell-level quirk assertions those suites do not pin, which the registry migration
# must preserve verbatim:
#   * unknown flags are IGNORED, never centrally rejected (amendment 5) — `<cmd> <id> --bogus`
#     behaves exactly like `<cmd> <id>`;
#   * extra positional arguments keep their current (silently-absorbed) behavior;
#   * success text lands on stdout and error text does not, per command.
# It is grown one section at a time, immediately BEFORE each command is migrated, and must pass
# against the pre-migration code first (that is what makes it a characterization test).
#
# Style/harness mirror StatusWaitRead.tests.ps1 / TailDebug.tests.ps1: dot-source the lib chain +
# ccodex.ps1 -ImportOnly, seed jobs through the real reservation path, and drive the real
# dispatcher via `pwsh -NoProfile -File ccodex.ps1`.
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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-characterization-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $targetRepo -Force | Out-Null

function New-CcodexCharJob {
    # Seed a job dir + index + status.json (+ optional result.md) through the real reservation
    # path so every dispatcher command finds it. Mirrors StatusWaitRead's helper.
    param(
        [string]$Status = 'done',
        [Nullable[int]]$CodexExitCode = $null,
        [Nullable[int]]$WrapperExitCode = $null,
        [switch]$WithResultFile,
        [string]$ResultContent = 'the result'
    )
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode 'review' -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    Write-CcodexTextFile -Path (Join-Path $jobDir 'prompt.md') -Content 'char test prompt'
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status $Status -Mode 'review' -Access 'read-only' -Repo $targetRepo -CreatedAt $createdAt -CodexExitCode $CodexExitCode -WrapperExitCode $WrapperExitCode
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    if ($WithResultFile) { Write-CcodexTextFile -Path (Join-Path $jobDir 'result.md') -Content $ResultContent }
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

function Invoke-CcodexShell {
    # Run the real CLI; capture combined output (Write-Output + child Write-Host) as joined lines
    # and the exit code, so quirk assertions can compare exact bytes and stream membership.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & pwsh -NoLogo -NoProfile -File $ccodexPs @Arguments 2>&1
    $exit = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $exit; Lines = $lines; Text = ($lines -join "`n") }
}

# ============================================================
# Read-only batch: status, read, list, cancel, debug, tail
# ============================================================

$doneJob = New-CcodexCharJob -Status 'done' -CodexExitCode 0 -WrapperExitCode 0 -WithResultFile

Write-Host 'characterization/status: unknown flag is ignored, not rejected (exit + stdout identical)'
$statusPlain = Invoke-CcodexShell -Arguments @('status', $doneJob.JobId, '--state-root', $localAppData)
$statusBogus = Invoke-CcodexShell -Arguments @('status', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $statusPlain.ExitCode 0 'status happy path exits 0'
Assert-Equal $statusPlain.Text "$($doneJob.JobId) done codex_exit_code=0 wrapper_exit_code=0" 'status happy path exact line'
Assert-Equal $statusBogus.ExitCode $statusPlain.ExitCode 'status: unknown flag does not change exit code'
Assert-Equal $statusBogus.Text $statusPlain.Text 'status: unknown flag does not change output'

Write-Host 'characterization/status: an extra positional after the id is absorbed (binds to $Mode, ignored)'
$statusExtra = Invoke-CcodexShell -Arguments @('status', $doneJob.JobId, 'extra-positional', '--state-root', $localAppData)
Assert-Equal $statusExtra.ExitCode $statusPlain.ExitCode 'status: extra positional does not change exit code'
Assert-Equal $statusExtra.Text $statusPlain.Text 'status: extra positional does not change output'

Write-Host 'characterization/status: missing-id usage error -> exit 2 with the exact message (Write-Host lands on the child stdout pipe)'
$statusNoId = Invoke-CcodexShell -Arguments @('status', '--state-root', $localAppData)
Assert-Equal $statusNoId.ExitCode 2 'status with no id exits 2'
Assert-Equal $statusNoId.Text 'ccodex: status requires a job id.' 'status missing-id message is exact'

Write-Host 'characterization/read: unknown flag ignored on the result channel'
$readPlain = Invoke-CcodexShell -Arguments @('read', $doneJob.JobId, '--state-root', $localAppData)
$readBogus = Invoke-CcodexShell -Arguments @('read', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $readPlain.ExitCode 0 'read happy path exits 0'
Assert-Equal $readPlain.Text 'the result' 'read happy path prints result.md content'
Assert-Equal $readBogus.ExitCode $readPlain.ExitCode 'read: unknown flag does not change exit code'
Assert-Equal $readBogus.Text $readPlain.Text 'read: unknown flag does not change output'

Write-Host 'characterization/list: unknown flag ignored; empty repo -> stable output'
$listPlain = Invoke-CcodexShell -Arguments @('list', '--repo', $targetRepo, '--state-root', $localAppData)
$listBogus = Invoke-CcodexShell -Arguments @('list', '--repo', $targetRepo, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $listBogus.ExitCode $listPlain.ExitCode 'list: unknown flag does not change exit code'
Assert-Equal $listBogus.Text $listPlain.Text 'list: unknown flag does not change output'

Write-Host 'characterization/cancel: already-terminal no-op line, unknown flag ignored'
$cancelPlain = Invoke-CcodexShell -Arguments @('cancel', $doneJob.JobId, '--state-root', $localAppData)
$cancelBogus = Invoke-CcodexShell -Arguments @('cancel', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $cancelPlain.ExitCode 0 'cancel on a done job exits 0'
Assert-Equal $cancelPlain.Text "$($doneJob.JobId) already done" 'cancel no-op line is exact'
Assert-Equal $cancelBogus.ExitCode $cancelPlain.ExitCode 'cancel: unknown flag does not change exit code'
Assert-Equal $cancelBogus.Text $cancelPlain.Text 'cancel: unknown flag does not change output'

Write-Host 'characterization/debug: unknown flag ignored'
$debugPlain = Invoke-CcodexShell -Arguments @('debug', $doneJob.JobId, '--state-root', $localAppData)
$debugBogus = Invoke-CcodexShell -Arguments @('debug', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $debugPlain.ExitCode 0 'debug on a done job exits 0'
Assert-Equal $debugBogus.ExitCode $debugPlain.ExitCode 'debug: unknown flag does not change exit code'
Assert-Equal $debugBogus.Text $debugPlain.Text 'debug: unknown flag does not change output'

Write-Host 'characterization/tail: unknown flag ignored'
$tailPlain = Invoke-CcodexShell -Arguments @('tail', $doneJob.JobId, '--state-root', $localAppData)
$tailBogus = Invoke-CcodexShell -Arguments @('tail', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $tailPlain.ExitCode 0 'tail on a done job exits 0'
Assert-Equal $tailBogus.ExitCode $tailPlain.ExitCode 'tail: unknown flag does not change exit code'
Assert-Equal $tailBogus.Text $tailPlain.Text 'tail: unknown flag does not change output'

# ============================================================
# Second batch: wait (single), diff, apply, cleanup
# ============================================================

Write-Host 'characterization/wait: single-wait on a done job prints result; unknown flag ignored'
$waitPlain = Invoke-CcodexShell -Arguments @('wait', $doneJob.JobId, '--state-root', $localAppData)
$waitBogus = Invoke-CcodexShell -Arguments @('wait', $doneJob.JobId, '--bogus-unknown-flag', '--state-root', $localAppData)
Assert-Equal $waitPlain.ExitCode 0 'wait on a done job exits 0'
Assert-Equal $waitBogus.ExitCode $waitPlain.ExitCode 'wait: unknown flag does not change exit code'
Assert-Equal $waitBogus.Text $waitPlain.Text 'wait: unknown flag does not change output'

Write-Host 'characterization/wait: --group/--label without --all is a usage error (exact message)'
$waitGroupNoAll = Invoke-CcodexShell -Arguments @('wait', $doneJob.JobId, '--group', 'g', '--state-root', $localAppData)
Assert-Equal $waitGroupNoAll.ExitCode 2 'wait --group without --all exits 2'
Assert-Equal $waitGroupNoAll.Text 'ccodex: wait --group/--label require --all.' 'wait --group without --all message is exact'

Write-Host 'characterization/diff: flag-before-id recovers the same id as flag-after-id (identical result)'
$diffAfter = Invoke-CcodexShell -Arguments @('diff', $doneJob.JobId, '--stat', '--state-root', $localAppData)
$diffBefore = Invoke-CcodexShell -Arguments @('diff', '--stat', $doneJob.JobId, '--state-root', $localAppData)
Assert-Equal $diffBefore.ExitCode $diffAfter.ExitCode 'diff: --stat before the id gives the same exit code as after'
Assert-Equal $diffBefore.Text $diffAfter.Text 'diff: --stat before the id gives the same output as after'

Write-Host 'characterization/diff: missing id and mutually-exclusive views are exact usage errors'
$diffNoId = Invoke-CcodexShell -Arguments @('diff', '--state-root', $localAppData)
Assert-Equal $diffNoId.ExitCode 2 'diff with no id exits 2'
Assert-Equal $diffNoId.Text 'ccodex: diff requires a job id.' 'diff missing-id message is exact'
$diffBoth = Invoke-CcodexShell -Arguments @('diff', $doneJob.JobId, '--stat', '--name-only', '--state-root', $localAppData)
Assert-Equal $diffBoth.ExitCode 2 'diff --stat + --name-only exits 2'
Assert-Equal $diffBoth.Text 'ccodex: diff --stat and --name-only are mutually exclusive.' 'diff mutual-exclusion message is exact'

Write-Host 'characterization/apply: flag-before-id recovers the same id as flag-after-id (identical result)'
$applyAfter = Invoke-CcodexShell -Arguments @('apply', $doneJob.JobId, '--reset-author', '--state-root', $localAppData)
$applyBefore = Invoke-CcodexShell -Arguments @('apply', '--reset-author', $doneJob.JobId, '--state-root', $localAppData)
Assert-Equal $applyBefore.ExitCode $applyAfter.ExitCode 'apply: --reset-author before the id gives the same exit code as after'
Assert-Equal $applyBefore.Text $applyAfter.Text 'apply: --reset-author before the id gives the same output as after'

Write-Host 'characterization/apply: missing id is an exact usage error'
$applyNoId = Invoke-CcodexShell -Arguments @('apply', '--state-root', $localAppData)
Assert-Equal $applyNoId.ExitCode 2 'apply with no id exits 2'
Assert-Equal $applyNoId.Text 'ccodex: apply requires a job id.' 'apply missing-id message is exact'

Write-Host 'characterization/cleanup: --dry-run output is stable and an unknown flag is ignored'
$cleanupPlain = Invoke-CcodexShell -Arguments @('cleanup', '--dry-run', '--repo', $targetRepo, '--state-root', $localAppData)
$cleanupBogus = Invoke-CcodexShell -Arguments @('cleanup', '--dry-run', '--bogus-unknown-flag', '--repo', $targetRepo, '--state-root', $localAppData)
Assert-Equal $cleanupBogus.ExitCode $cleanupPlain.ExitCode 'cleanup: unknown flag does not change exit code'
Assert-Equal $cleanupBogus.Text $cleanupPlain.Text 'cleanup: unknown flag does not change output'

# ============================================================
# Third batch: run, submit, resume, review, worker
# These pin the fast usage-error paths (no live Codex): required-value semantics for the
# hyphenated --model/--effort flags, effort validation, the submit --resume inherit guard, and
# the internal worker's missing --job-id error. The RunCommand/SubmitCommand/Resume/
# ReviewCommand/Worker suites cover the codex-invoking happy paths with fixtures.
# ============================================================

Write-Host 'characterization/run: a trailing --model with no value is an exact usage error (required-value)'
$runModelNoValue = Invoke-CcodexShell -Arguments @('run', '--model', '--effort', 'high', 'a task')
Assert-Equal $runModelNoValue.ExitCode 2 'run --model with no value exits 2'
Assert-Equal $runModelNoValue.Text 'ccodex: --model requires a value.' 'run --model required-value message is exact'

Write-Host 'characterization/run: an invalid --effort is an exact usage error (validated before any Codex call)'
$runBadEffort = Invoke-CcodexShell -Arguments @('run', '--effort', 'NotAValidEffort', 'a task')
Assert-Equal $runBadEffort.ExitCode 2 'run --effort invalid exits 2'
Assert-Equal $runBadEffort.Text "ccodex: --effort must be one of: none, minimal, low, medium, high, xhigh, max, ultra (case-sensitive); got 'NotAValidEffort'." 'run invalid-effort message is exact'

Write-Host 'characterization/review: a trailing --model with no value is an exact usage error'
$reviewModelNoValue = Invoke-CcodexShell -Arguments @('review', '--model', '--effort', 'high')
Assert-Equal $reviewModelNoValue.ExitCode 2 'review --model with no value exits 2'
Assert-Equal $reviewModelNoValue.Text 'ccodex: --model requires a value.' 'review --model required-value message is exact'

Write-Host 'characterization/submit: --resume with an inherited override is an exact usage error'
$submitResumeOverride = Invoke-CcodexShell -Arguments @('submit', '--resume', 'some-parent-id', '--mode', 'review')
Assert-Equal $submitResumeOverride.ExitCode 2 'submit --resume with --mode exits 2'
Assert-Equal $submitResumeOverride.Text 'ccodex: submit --resume inherits mode, access, repo, group, and label from the parent job.' 'submit --resume inherit-guard message is exact'

Write-Host 'characterization/resume: missing job id is an exact usage error'
$resumeNoId = Invoke-CcodexShell -Arguments @('resume')
Assert-Equal $resumeNoId.ExitCode 2 'resume with no job id exits 2'
Assert-Equal $resumeNoId.Text 'ccodex: resume requires a job id.' 'resume missing-id message is exact'

Write-Host 'characterization/worker: the internal entrypoint requires --job-id (exact message), and stays hidden from help'
$workerNoId = Invoke-CcodexShell -Arguments @('worker')
Assert-Equal $workerNoId.ExitCode 2 'worker with no --job-id exits 2'
Assert-Equal $workerNoId.Text 'ccodex: worker requires --job-id <id>.' 'worker missing --job-id message is exact'
$workerHelp = Invoke-CcodexShell -Arguments @('worker', '--help')
Assert-Equal $workerHelp.ExitCode 2 'worker --help is an unknown-command usage error (worker is help-hidden)'
Assert-True ($workerHelp.Text -like "*command 'worker' is not implemented*") 'worker --help prints the unknown-command message'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
