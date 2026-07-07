# tests/TailDebug.tests.ps1
#
# Invoke-CcodexTailCommand (design: "tail <job_id>", Phase 2b Task 6). Follows the same
# dot-source-ccodex.ps1-with-ImportOnly pattern StatusWaitRead.tests.ps1/CancelCommand.tests.ps1
# use so the real dispatcher functions are exercised directly.
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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-taildebug-test-$([Guid]::NewGuid().ToString('N'))"
$localAppData = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$targetRepo = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $localAppData, $appData, $targetRepo -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

function New-CcodexTestJobDir {
    # Seeds a job dir via the real reservation/index path (like other Phase 2b command
    # test files) so Get-CcodexJobRecord (which Invoke-CcodexTailCommand calls first)
    # finds it. Callers write stderr.log / codex-events.jsonl into the returned JobDir
    # themselves, or leave them absent.
    param([string]$Mode = 'review')
    $repoKey = Get-CcodexRepoKey -RepoRoot $targetRepo
    $reservation = Reserve-CcodexJobDir -RepoKey $repoKey -Mode $Mode -Root $localAppData
    $jobId = $reservation.JobId
    $jobDir = $reservation.JobDir
    $indexPath = Get-CcodexIndexPath -JobId $jobId -Root $localAppData
    New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force | Out-Null
    Write-CcodexJsonFileAtomic -Path $indexPath -Object ([ordered]@{ job_id = $jobId; repo_key = $repoKey; job_dir = $jobDir })
    $createdAt = (Get-Date).ToString('o')
    $statusObj = New-CcodexStatusObject -JobId $jobId -Status 'running' -Mode $Mode -Access 'read-only' -Repo $targetRepo -CreatedAt $createdAt
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    return [pscustomobject]@{ JobId = $jobId; JobDir = $jobDir }
}

function New-CcodexLineFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$LineCount, [string]$Prefix = 'line')
    $lines = 1..$LineCount | ForEach-Object { "$Prefix $_" }
    Write-CcodexTextFile -Path $Path -Content (($lines -join "`n") + "`n")
}

# ============================================================
# (a) unknown job id -> exit 3
# ============================================================

Write-Host "Invoke-CcodexTailCommand: unknown job id -> exit 3"
$resultUnknown = Invoke-CcodexTailCommand -JobId 'does-not-exist-99999' -StateRoot $localAppData
Assert-Equal $resultUnknown.WrapperExitCode 3 'unknown job id -> exit 3'
Assert-True (-not [string]::IsNullOrEmpty($resultUnknown.Message)) 'unknown job id returns a diagnostic message'

# ============================================================
# (b) both files present, more than N lines -> exactly the last N lines of each
# ============================================================

Write-Host "Invoke-CcodexTailCommand: stderr.log and codex-events.jsonl both have >N lines -> exactly the last N of each"
$jobBoth = New-CcodexTestJobDir
New-CcodexLineFile -Path (Join-Path $jobBoth.JobDir 'stderr.log') -LineCount 100 -Prefix 'stderr'
New-CcodexLineFile -Path (Join-Path $jobBoth.JobDir 'codex-events.jsonl') -LineCount 100 -Prefix 'event'
$resultBoth = Invoke-CcodexTailCommand -JobId $jobBoth.JobId -Lines 40 -StateRoot $localAppData
Assert-Equal $resultBoth.WrapperExitCode 0 'tail with both files present exits 0'
$expectedStderrLines = (61..100 | ForEach-Object { "stderr $_" })
$expectedEventLines = (61..100 | ForEach-Object { "event $_" })
$outLines = $resultBoth.Stdout -split "`r?`n"
Assert-Equal $outLines[0] '== stderr.log (last 40) ==' 'stderr.log header is first'
for ($i = 0; $i -lt 40; $i++) {
    Assert-Equal $outLines[1 + $i] $expectedStderrLines[$i] "stderr.log tail line $i matches exactly the last 40"
}
$eventsHeaderIndex = 41
Assert-Equal $outLines[$eventsHeaderIndex] '== codex-events.jsonl (last 40) ==' 'codex-events.jsonl header follows the stderr.log block'
for ($i = 0; $i -lt 40; $i++) {
    Assert-Equal $outLines[$eventsHeaderIndex + 1 + $i] $expectedEventLines[$i] "codex-events.jsonl tail line $i matches exactly the last 40"
}

# ============================================================
# (c) both files missing -> "(absent)" placeholder for each, still exit 0
# ============================================================

Write-Host "Invoke-CcodexTailCommand: both files absent -> '(absent)' placeholder for each, exit 0"
$jobAbsent = New-CcodexTestJobDir
$resultAbsent = Invoke-CcodexTailCommand -JobId $jobAbsent.JobId -Lines 40 -StateRoot $localAppData
Assert-Equal $resultAbsent.WrapperExitCode 0 'tail with both files absent still exits 0'
$absentLines = $resultAbsent.Stdout -split "`r?`n"
Assert-Equal $absentLines[0] '== stderr.log (last 40) ==' 'stderr.log header present even when absent'
Assert-Equal $absentLines[1] '(absent)' 'stderr.log shows the (absent) placeholder'
Assert-Equal $absentLines[2] '== codex-events.jsonl (last 40) ==' 'codex-events.jsonl header present even when absent'
Assert-Equal $absentLines[3] '(absent)' 'codex-events.jsonl shows the (absent) placeholder'

# ============================================================
# (d) a file larger than 64 KB -> only the tail is read (seek path), still exactly the last N lines
# ============================================================

Write-Host "Invoke-CcodexTailCommand: a file larger than 64 KB -> seek-tail path still returns exactly the last N lines"
$jobBig = New-CcodexTestJobDir
$bigLineCount = 8000
New-CcodexLineFile -Path (Join-Path $jobBig.JobDir 'stderr.log') -LineCount $bigLineCount -Prefix 'bigline'
$bigFileLength = (Get-Item (Join-Path $jobBig.JobDir 'stderr.log')).Length
Assert-True ($bigFileLength -gt 64KB) 'the fixture stderr.log fixture actually exceeds 64 KB (sanity check on the fixture itself)'
$resultBig = Invoke-CcodexTailCommand -JobId $jobBig.JobId -Lines 5 -StateRoot $localAppData
Assert-Equal $resultBig.WrapperExitCode 0 'tail against a >64KB file exits 0'
$bigOutLines = $resultBig.Stdout -split "`r?`n"
$expectedBigLines = (($bigLineCount - 4)..$bigLineCount | ForEach-Object { "bigline $_" })
Assert-Equal $bigOutLines[0] '== stderr.log (last 5) ==' 'big-file stderr.log header'
for ($i = 0; $i -lt 5; $i++) {
    Assert-Equal $bigOutLines[1 + $i] $expectedBigLines[$i] "big-file tail line $i matches exactly the last 5 (seek path, never read from the start)"
}

# ============================================================
# (e) function-level default Lines = 40
# ============================================================

Write-Host "Invoke-CcodexTailCommand: default -Lines is 40 when omitted"
$jobDefault = New-CcodexTestJobDir
New-CcodexLineFile -Path (Join-Path $jobDefault.JobDir 'stderr.log') -LineCount 50
$resultDefault = Invoke-CcodexTailCommand -JobId $jobDefault.JobId -StateRoot $localAppData
Assert-Equal $resultDefault.WrapperExitCode 0 'tail with default -Lines exits 0'
Assert-True ($resultDefault.Stdout -like '*(last 40)*') 'default -Lines produces "(last 40)" headers'

# ============================================================
# dispatcher wiring: shell-level `ccodex.ps1 tail <id> [--lines <n>] --state-root ...`
# ============================================================

Write-Host "shell-level: ccodex.ps1 tail <id> --lines 3 --state-root <root> prints both tail blocks, exit 0"
$jobShell = New-CcodexTestJobDir
New-CcodexLineFile -Path (Join-Path $jobShell.JobDir 'stderr.log') -LineCount 10 -Prefix 'shellerr'
$shellTailOut = & pwsh -NoLogo -NoProfile -File $ccodexPs tail $jobShell.JobId --lines 3 --state-root $localAppData
$shellTailExit = $LASTEXITCODE
Assert-Equal $shellTailExit 0 'shell-level tail invocation exits 0'
$shellTailText = ($shellTailOut -join "`n")
Assert-True ($shellTailText -like '*== stderr.log (last 3) ==*') 'shell-level tail output includes the stderr.log header with --lines honored'
Assert-True ($shellTailText -like '*shellerr 10*') 'shell-level tail output includes the actual last stderr.log line'
Assert-True ($shellTailText -like '*== codex-events.jsonl (last 3) ==*') 'shell-level tail output includes the codex-events.jsonl header'
Assert-True ($shellTailText -like '*(absent)*') 'shell-level tail output shows (absent) for the missing codex-events.jsonl'

Write-Host "shell-level: ccodex.ps1 tail with no job id -> exit 2"
$shellTailNoIdOut = & pwsh -NoLogo -NoProfile -File $ccodexPs tail --state-root $localAppData
$shellTailNoIdExit = $LASTEXITCODE
Assert-Equal $shellTailNoIdExit 2 'shell-level tail with no job id exits 2'

Write-Host "shell-level: ccodex.ps1 tail <id> --lines abc -> exit 2 (bad --lines is a usage error)"
$shellBadLinesOut = & pwsh -NoLogo -NoProfile -File $ccodexPs tail $jobShell.JobId --lines abc --state-root $localAppData
$shellBadLinesExit = $LASTEXITCODE
Assert-Equal $shellBadLinesExit 2 'non-numeric --lines exits 2'

Write-Host "shell-level: ccodex.ps1 tail <id> --lines 0 -> exit 2 (must be a positive int)"
$shellZeroLinesOut = & pwsh -NoLogo -NoProfile -File $ccodexPs tail $jobShell.JobId --lines 0 --state-root $localAppData
$shellZeroLinesExit = $LASTEXITCODE
Assert-Equal $shellZeroLinesExit 2 '--lines 0 exits 2'

Write-Host "shell-level: ccodex.ps1 tail <id> --lines -5 -> exit 2 (must be a positive int)"
$shellNegLinesOut = & pwsh -NoLogo -NoProfile -File $ccodexPs tail $jobShell.JobId --lines -5 --state-root $localAppData
$shellNegLinesExit = $LASTEXITCODE
Assert-Equal $shellNegLinesExit 2 '--lines -5 exits 2'

Write-Host "shell-level: unknown command message names tail among the supported commands"
$shellUnknownOut = & pwsh -NoLogo -NoProfile -File $ccodexPs bogus-command
$shellUnknownExit = $LASTEXITCODE
Assert-Equal $shellUnknownExit 2 'an unknown command exits 2'
Assert-True ((($shellUnknownOut -join "`n")) -like '*tail*') 'the supported-commands message now lists tail'

Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-CcodexTests
