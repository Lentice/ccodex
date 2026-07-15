# tests/Cleanup.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Paths.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\FailureClassify.ps1')
. (Join-Path $PSScriptRoot '..\lib\ResultValidation.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobIndex.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStatus.ps1')
. (Join-Path $PSScriptRoot '..\lib\UserConfig.ps1')
. (Join-Path $PSScriptRoot '..\lib\Cleanup.ps1')
. (Join-Path $PSScriptRoot '..\lib\Worktree.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-cleanup-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$script:StateRootSeq = 0
function New-CleanupStateRoot {
    $script:StateRootSeq++
    $root = Join-Path $tempRoot "state-$($script:StateRootSeq)"
    New-Item -ItemType Directory -Path (Join-Path $root 'ccodex\jobs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'ccodex\index') -Force | Out-Null
    return $root
}

function New-CleanupAppData {
    param([Nullable[int]]$JobsDays, [Nullable[int]]$ThreadTtlDays)
    $script:StateRootSeq++
    $root = Join-Path $tempRoot "appdata-$($script:StateRootSeq)"
    New-Item -ItemType Directory -Path (Join-Path $root 'ccodex') -Force | Out-Null
    if ($null -ne $JobsDays -or $null -ne $ThreadTtlDays) {
        $retention = [ordered]@{}
        if ($null -ne $JobsDays) { $retention['jobs_days'] = $JobsDays }
        if ($null -ne $ThreadTtlDays) { $retention['thread_ttl_days'] = $ThreadTtlDays }
        Write-CcodexJsonFile -Path (Join-Path $root 'ccodex\config.json') -Object ([ordered]@{ retention = $retention })
    }
    return $root
}

function New-CleanupJob {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Status,
        [string]$CreatedAt,
        [string]$FinishedAt,
        [string]$BackendId,
        [string]$CodexThreadId,
        [Nullable[int]]$CodexExitCode,
        [Nullable[int]]$WrapperExitCode,
        [switch]$NoIndex,
        [hashtable]$Files,
        [string]$MainRepo,
        [string]$WorktreeRepo,
        [string]$BaseCommit
    )
    $jobDir = Get-CcodexJobDir -RepoKey $RepoKey -JobId $JobId -Root $StateRoot
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
    if (-not $CreatedAt) { $CreatedAt = (Get-Date).ToUniversalTime().ToString('o') }
    $statusObj = New-CcodexStatusObject -JobId $JobId -Status $Status -Mode 'review' -Access 'read-only' `
        -Repo 'C:\repo' -CreatedAt $CreatedAt -CodexExitCode $CodexExitCode -WrapperExitCode $WrapperExitCode `
        -BackendId $BackendId -FinishedAt $FinishedAt -CodexThreadId $CodexThreadId `
        -MainRepo $MainRepo -WorktreeRepo $WorktreeRepo -BaseCommit $BaseCommit
    Write-CcodexJsonFileAtomic -Path (Join-Path $jobDir 'status.json') -Object $statusObj
    if (-not $NoIndex) {
        $idxPath = Get-CcodexIndexPath -JobId $JobId -Root $StateRoot
        New-Item -ItemType Directory -Path (Split-Path -Parent $idxPath) -Force | Out-Null
        Write-CcodexJsonFileAtomic -Path $idxPath -Object ([ordered]@{ job_id = $JobId; repo_key = $RepoKey; job_dir = $jobDir })
    }
    if ($Files) {
        foreach ($name in $Files.Keys) {
            Write-CcodexTextFile -Path (Join-Path $jobDir $name) -Content $Files[$name]
        }
    }
    return $jobDir
}

function Get-Ago { param([double]$Days) return (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('o') }

function New-CleanupGitRepo {
    $script:StateRootSeq++
    $repo = Join-Path $tempRoot "gitrepo-$($script:StateRootSeq)"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'seed.txt') -Value 'seed' -NoNewline
    & git -C $repo -c user.name=seed -c user.email=seed@local add -A 2>&1 | Out-Null
    & git -C $repo -c user.name=seed -c user.email=seed@local commit -q -m seed 2>&1 | Out-Null
    return $repo
}

$repoKeyA = 'aaaaaaaaaaaa'
$repoKeyB = 'bbbbbbbbbbbb'

# --- (1) old done job deleted; index gone; dir gone ---

Write-Host "Invoke-CcodexCleanup: an old terminal (done) job is deleted with its index"
$s1 = New-CleanupStateRoot
$app1 = New-CleanupAppData
$oldDir = New-CleanupJob -StateRoot $s1 -RepoKey $repoKeyA -JobId 'olddone' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0
$oldIdx = Get-CcodexIndexPath -JobId 'olddone' -Root $s1
$r1 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s1 -AppDataRoot $app1
Assert-Equal $r1.WrapperExitCode 0 'exit 0 on a clean sweep'
Assert-True ($r1.Deleted -contains 'olddone') 'old done job reported in Deleted'
Assert-True (-not (Test-Path -LiteralPath $oldDir)) 'old done job dir removed'
Assert-True (-not (Test-Path -LiteralPath $oldIdx)) 'old done job index entry removed'

# --- (2) young done job kept ---

Write-Host "Invoke-CcodexCleanup: a young terminal job is kept"
$s2 = New-CleanupStateRoot
$app2 = New-CleanupAppData
$youngDir = New-CleanupJob -StateRoot $s2 -RepoKey $repoKeyA -JobId 'youngdone' -Status 'done' -CreatedAt (Get-Ago 2) -FinishedAt (Get-Ago 1) -CodexExitCode 0 -WrapperExitCode 0
$youngIdx = Get-CcodexIndexPath -JobId 'youngdone' -Root $s2
$r2 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s2 -AppDataRoot $app2
Assert-True (-not ($r2.Deleted -contains 'youngdone')) 'young done job not deleted'
Assert-True (Test-Path -LiteralPath $youngDir) 'young done job dir kept'
Assert-True (Test-Path -LiteralPath $youngIdx) 'young done job index kept'

# --- (3) old running-alive job kept + reported (default, no --include-stalled) ---

Write-Host "Invoke-CcodexCleanup: an old running job with a live worker is kept and reported skipped"
$s3 = New-CleanupStateRoot
$app3 = New-CleanupAppData
$aliveBackendId = ConvertTo-CcodexBackendId -ProcessId $PID -StartTime (Get-Process -Id $PID).StartTime
$aliveDir = New-CleanupJob -StateRoot $s3 -RepoKey $repoKeyA -JobId 'runalive' -Status 'running' -CreatedAt (Get-Ago 40) -BackendId $aliveBackendId
$r3 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s3 -AppDataRoot $app3
Assert-True (-not ($r3.Deleted -contains 'runalive')) 'running job never deleted'
Assert-True (Test-Path -LiteralPath $aliveDir) 'running job dir kept'
Assert-Equal $r3.SkippedCount 1 'running job counted as skipped'

# --- (4) old running-dead-with-evidence + --include-stalled: reconciled then deleted ---

Write-Host "Invoke-CcodexCleanup --include-stalled: a dead-but-evidenced stalled job is reconciled then deleted"
$s4 = New-CleanupStateRoot
$app4 = New-CleanupAppData
$deadBackendId = '999999;2000-01-01T00:00:00.0000000Z'
$deadDir = New-CleanupJob -StateRoot $s4 -RepoKey $repoKeyA -JobId 'stalled' -Status 'running' -CreatedAt (Get-Ago 40) -BackendId $deadBackendId `
    -Files @{ 'exit_code.txt' = '0'; 'result.md' = 'RECONCILED RESULT' }
$deadIdx = Get-CcodexIndexPath -JobId 'stalled' -Root $s4
$r4 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $true -ScrubThreadIds $false -StateRoot $s4 -AppDataRoot $app4
Assert-True ($r4.Deleted -contains 'stalled') 'reconciled stalled job deleted'
Assert-True (-not (Test-Path -LiteralPath $deadDir)) 'reconciled stalled job dir removed'
Assert-True (-not (Test-Path -LiteralPath $deadIdx)) 'reconciled stalled job index removed'

Write-Host "Invoke-CcodexCleanup without --include-stalled: a dead-but-evidenced stalled job is skipped (not reconciled)"
$s4b = New-CleanupStateRoot
$app4b = New-CleanupAppData
$deadDir2 = New-CleanupJob -StateRoot $s4b -RepoKey $repoKeyA -JobId 'stalled2' -Status 'running' -CreatedAt (Get-Ago 40) -BackendId $deadBackendId `
    -Files @{ 'exit_code.txt' = '0'; 'result.md' = 'RECONCILED RESULT' }
$r4b = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s4b -AppDataRoot $app4b
Assert-True (-not ($r4b.Deleted -contains 'stalled2')) 'stalled job not deleted without --include-stalled'
Assert-True (Test-Path -LiteralPath $deadDir2) 'stalled job dir kept without --include-stalled'
Assert-Equal $r4b.SkippedCount 1 'stalled job counted as skipped without --include-stalled'

# --- (5) dangling index entry removed ---

Write-Host "Invoke-CcodexCleanup: a dangling index entry (missing job dir) is removed"
$s5 = New-CleanupStateRoot
$app5 = New-CleanupAppData
$danglingIdx = Get-CcodexIndexPath -JobId 'ghost' -Root $s5
Write-CcodexJsonFileAtomic -Path $danglingIdx -Object ([ordered]@{ job_id = 'ghost'; repo_key = $repoKeyA; job_dir = (Join-Path (Get-CcodexJobsDir -RepoKey $repoKeyA -Root $s5) 'ghost') })
$r5 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s5 -AppDataRoot $app5
Assert-True (-not (Test-Path -LiteralPath $danglingIdx)) 'dangling index entry removed'
Assert-True ($r5.Stdout -match 'dangling=1') 'summary reports dangling=1'

# --- (6) old terminal job with thread id + --scrub-thread-ids: retained, thread id nulled, other fields byte-stable ---

Write-Host "Invoke-CcodexCleanup --scrub-thread-ids: a retained terminal job older than thread-ttl has its thread id scrubbed, other fields byte-stable"
$s6 = New-CleanupStateRoot
$app6 = New-CleanupAppData
$scrubDir = New-CleanupJob -StateRoot $s6 -RepoKey $repoKeyA -JobId 'scrubme' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0 -CodexThreadId 'thread-abc-123'
$scrubStatusPath = Join-Path $scrubDir 'status.json'
$rawBefore = Get-Content -LiteralPath $scrubStatusPath -Raw
$expectedAfter = [regex]::Replace($rawBefore, '("codex_thread_id"\s*:\s*)"[^"]*"', '${1}null')
$r6 = Invoke-CcodexCleanup -OlderThanDays 60 -ThreadTtlDays 30 -DryRun $false -IncludeStalled $false -ScrubThreadIds $true -StateRoot $s6 -AppDataRoot $app6
Assert-True (Test-Path -LiteralPath $scrubDir) 'scrubbed job is retained (not deleted)'
Assert-Equal $r6.ScrubbedCount 1 'ScrubbedCount is 1'
$scrubbedStatus = Read-CcodexStatusFile -JobDir $scrubDir
Assert-True ($null -eq $scrubbedStatus.codex_thread_id) 'codex_thread_id is null after scrub'
Assert-Equal $scrubbedStatus.job_id 'scrubme' 'job_id preserved after scrub'
Assert-Equal ([int]$scrubbedStatus.codex_exit_code) 0 'codex_exit_code preserved after scrub'
$rawAfter = Get-Content -LiteralPath $scrubStatusPath -Raw
Assert-Equal $rawAfter $expectedAfter 'only the thread id changed; all other bytes stable'

Write-Host "Invoke-CcodexCleanup --scrub-thread-ids: a retained terminal job younger than thread-ttl keeps its thread id"
$s6b = New-CleanupStateRoot
$app6b = New-CleanupAppData
$keepDir = New-CleanupJob -StateRoot $s6b -RepoKey $repoKeyA -JobId 'keepthread' -Status 'done' -CreatedAt (Get-Ago 11) -FinishedAt (Get-Ago 10) -CodexExitCode 0 -WrapperExitCode 0 -CodexThreadId 'thread-keep'
$r6b = Invoke-CcodexCleanup -OlderThanDays 60 -ThreadTtlDays 30 -DryRun $false -IncludeStalled $false -ScrubThreadIds $true -StateRoot $s6b -AppDataRoot $app6b
Assert-Equal $r6b.ScrubbedCount 0 'young job not scrubbed'
$keepStatus = Read-CcodexStatusFile -JobDir $keepDir
Assert-Equal $keepStatus.codex_thread_id 'thread-keep' 'young job keeps its thread id'

# --- (7) dry-run: nothing changes, candidates listed ---

Write-Host "Invoke-CcodexCleanup -DryRun: nothing changes and candidates are listed"
$s7 = New-CleanupStateRoot
$app7 = New-CleanupAppData
$dryDir = New-CleanupJob -StateRoot $s7 -RepoKey $repoKeyA -JobId 'drydone' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0
$dryIdx = Get-CcodexIndexPath -JobId 'drydone' -Root $s7
$r7 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $true -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s7 -AppDataRoot $app7
Assert-Equal $r7.WrapperExitCode 0 'dry-run exits 0'
Assert-True (Test-Path -LiteralPath $dryDir) 'dry-run does not delete the job dir'
Assert-True (Test-Path -LiteralPath $dryIdx) 'dry-run does not delete the index entry'
Assert-True ($r7.Stdout -match 'drydone done age=\d+d size=\d+KB -> delete') 'dry-run lists the delete candidate line'

# --- (8) bad --older-than syntax via dispatcher -> exit 2 ---

Write-Host "Dispatcher: bad --older-than syntax exits 2"
$s8 = New-CleanupStateRoot
& pwsh -NoLogo -NoProfile -File $ccodexPs cleanup --older-than 5x --state-root $s8 | Out-Null
Assert-Equal $LASTEXITCODE 2 'bad --older-than syntax exits 2'

Write-Host "Dispatcher: valid cleanup runs and exits 0"
$s8b = New-CleanupStateRoot
$app8b = New-CleanupAppData
# Point the child at the isolated app-data root so a malformed real %APPDATA%\ccodex\config.json
# on the developer's machine cannot make this dispatcher test fail spuriously.
$savedAppData8b = $env:APPDATA
$env:APPDATA = $app8b
try {
    & pwsh -NoLogo -NoProfile -File $ccodexPs cleanup --older-than 14d --state-root $s8b | Out-Null
    Assert-Equal $LASTEXITCODE 0 'valid cleanup exits 0'
} finally {
    $env:APPDATA = $savedAppData8b
}

# --- (9) summary line fields ---

Write-Host "Invoke-CcodexCleanup: summary line carries deleted/reclaimed/dangling/scrubbed/skipped/failed fields"
$s9 = New-CleanupStateRoot
$app9 = New-CleanupAppData
New-CleanupJob -StateRoot $s9 -RepoKey $repoKeyA -JobId 'sumold' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0 | Out-Null
New-CleanupJob -StateRoot $s9 -RepoKey $repoKeyA -JobId 'sumrun' -Status 'running' -CreatedAt (Get-Ago 40) -BackendId '999999;2000-01-01T00:00:00.0000000Z' | Out-Null
$r9 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s9 -AppDataRoot $app9
Assert-True ($r9.Stdout -match 'deleted=1') 'summary has deleted=1'
Assert-True ($r9.Stdout -match 'reclaimed_kb=\d+') 'summary has reclaimed_kb'
Assert-True ($r9.Stdout -match 'dangling=\d+') 'summary has dangling'
Assert-True ($r9.Stdout -match 'scrubbed=\d+') 'summary has scrubbed'
Assert-True ($r9.Stdout -match 'skipped=1') 'summary has skipped=1'
Assert-True ($r9.Stdout -match 'failed=0') 'summary has failed=0'

# --- (10) unreadable status is retained until terminality can be confirmed under the lock ---

Write-Host "Invoke-CcodexCleanup: an unreadable old status is retained when terminality cannot be confirmed"
$s10 = New-CleanupStateRoot
$app10 = New-CleanupAppData
$badDir = Join-Path (Get-CcodexJobsDir -RepoKey $repoKeyA -Root $s10) 'corrupt'
New-Item -ItemType Directory -Path $badDir -Force | Out-Null
Write-CcodexTextFile -Path (Join-Path $badDir 'status.json') -Content '{ this is not json'
(Get-Item -LiteralPath $badDir).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-40)
$r10 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s10 -AppDataRoot $app10
Assert-True (Test-Path -LiteralPath $badDir) 'old unreadable-status job dir is retained without terminal confirmation'
Assert-True (-not ($r10.Deleted -contains 'corrupt')) 'old unreadable-status job is not reported deleted'

Write-Host "Invoke-CcodexCleanup: an unreadable status with a young dir is kept"
$s10b = New-CleanupStateRoot
$app10b = New-CleanupAppData
$badYoung = Join-Path (Get-CcodexJobsDir -RepoKey $repoKeyA -Root $s10b) 'corruptyoung'
New-Item -ItemType Directory -Path $badYoung -Force | Out-Null
Write-CcodexTextFile -Path (Join-Path $badYoung 'status.json') -Content '{ nope'
$r10b = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s10b -AppDataRoot $app10b
Assert-True (Test-Path -LiteralPath $badYoung) 'young unreadable-status job dir kept'

# --- (11) resolution: config threshold used when --older-than omitted ---

Write-Host "Invoke-CcodexCleanup: falls back to user-config jobs_days when OlderThanDays is not passed"
$s11 = New-CleanupStateRoot
$app11 = New-CleanupAppData -JobsDays 1
$cfgDir = New-CleanupJob -StateRoot $s11 -RepoKey $repoKeyA -JobId 'cfgold' -Status 'done' -CreatedAt (Get-Ago 3) -FinishedAt (Get-Ago 2) -CodexExitCode 0 -WrapperExitCode 0
$r11 = Invoke-CcodexCleanup -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s11 -AppDataRoot $app11
Assert-True ($r11.Deleted -contains 'cfgold') 'job older than config jobs_days=1 is deleted'
Assert-True (-not (Test-Path -LiteralPath $cfgDir)) 'config-threshold job dir removed'

# --- (12) --repo narrows the sweep to a single repo key ---

Write-Host "Invoke-CcodexCleanup: RepoFilter narrows the sweep to the matching repo key only"
$s12 = New-CleanupStateRoot
$app12 = New-CleanupAppData
$filterRepo = Join-Path $tempRoot "filterrepo-$($script:StateRootSeq)"
New-Item -ItemType Directory -Path $filterRepo -Force | Out-Null
$filterKey = Get-CcodexRepoKey -RepoRoot $filterRepo
$inScopeDir = New-CleanupJob -StateRoot $s12 -RepoKey $filterKey -JobId 'inscope' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0
$outScopeDir = New-CleanupJob -StateRoot $s12 -RepoKey $repoKeyB -JobId 'outscope' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0
$r12 = Invoke-CcodexCleanup -RepoFilter $filterRepo -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s12 -AppDataRoot $app12
Assert-True (-not (Test-Path -LiteralPath $inScopeDir)) 'in-scope repo job deleted'
Assert-True (Test-Path -LiteralPath $outScopeDir) 'out-of-scope repo job untouched'

# --- (13) sub-day OlderThanDays is honored exactly, not rounded via [int] coercion ---

Write-Host "Invoke-CcodexCleanup: sub-day OlderThanDays (e.g. 12h -> 0.5d) is honored exactly"
$s13 = New-CleanupStateRoot
$app13 = New-CleanupAppData
$halfDayKeepDir = New-CleanupJob -StateRoot $s13 -RepoKey $repoKeyA -JobId 'halfday-keep' -Status 'done' -CreatedAt (Get-Ago (35 / 1440.0)) -FinishedAt (Get-Ago (30 / 1440.0)) -CodexExitCode 0 -WrapperExitCode 0
$halfDayDeleteDir = New-CleanupJob -StateRoot $s13 -RepoKey $repoKeyA -JobId 'halfday-delete' -Status 'done' -CreatedAt (Get-Ago (13.1 / 24.0)) -FinishedAt (Get-Ago (13.0 / 24.0)) -CodexExitCode 0 -WrapperExitCode 0
$r13 = Invoke-CcodexCleanup -OlderThanDays 0.5 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s13 -AppDataRoot $app13
Assert-True (Test-Path -LiteralPath $halfDayKeepDir) 'a job finished 30 minutes ago is kept when OlderThanDays=0.5 (12h)'
Assert-True (-not (Test-Path -LiteralPath $halfDayDeleteDir)) 'a job finished 13 hours ago is deleted when OlderThanDays=0.5 (12h)'

# --- (14) dispatcher: --older-than 1h honors an exact one-hour threshold ---

Write-Host "Dispatcher: --older-than 1h keeps a job finished 30 minutes ago but deletes one finished 2 hours ago"
$s14 = New-CleanupStateRoot
$app14 = New-CleanupAppData
$job30m = New-CleanupJob -StateRoot $s14 -RepoKey $repoKeyA -JobId 'min30' -Status 'done' -CreatedAt (Get-Ago (35 / 1440.0)) -FinishedAt (Get-Ago (30 / 1440.0)) -CodexExitCode 0 -WrapperExitCode 0
$job2h = New-CleanupJob -StateRoot $s14 -RepoKey $repoKeyA -JobId 'hour2' -Status 'done' -CreatedAt (Get-Ago (125 / 1440.0)) -FinishedAt (Get-Ago (120 / 1440.0)) -CodexExitCode 0 -WrapperExitCode 0
& pwsh -NoLogo -NoProfile -File $ccodexPs cleanup --older-than 1h --state-root $s14 | Out-Null
Assert-Equal $LASTEXITCODE 0 'dispatcher --older-than 1h exits 0'
Assert-True (Test-Path -LiteralPath $job30m) 'dispatcher --older-than 1h keeps a job finished 30 minutes ago'
Assert-True (-not (Test-Path -LiteralPath $job2h)) 'dispatcher --older-than 1h deletes a job finished 2 hours ago'

# --- (15) dispatcher: --older-than 23h boundary ---

Write-Host "Dispatcher: --older-than 23h keeps a job finished ~22h50m ago but deletes one finished ~23h10m ago"
$s15 = New-CleanupStateRoot
$app15 = New-CleanupAppData
$jobUnder23 = New-CleanupJob -StateRoot $s15 -RepoKey $repoKeyA -JobId 'under23' -Status 'done' -CreatedAt (Get-Ago ((22 * 60 + 55) / 1440.0)) -FinishedAt (Get-Ago ((22 * 60 + 50) / 1440.0)) -CodexExitCode 0 -WrapperExitCode 0
$jobOver23 = New-CleanupJob -StateRoot $s15 -RepoKey $repoKeyA -JobId 'over23' -Status 'done' -CreatedAt (Get-Ago ((23 * 60 + 15) / 1440.0)) -FinishedAt (Get-Ago ((23 * 60 + 10) / 1440.0)) -CodexExitCode 0 -WrapperExitCode 0
& pwsh -NoLogo -NoProfile -File $ccodexPs cleanup --older-than 23h --state-root $s15 | Out-Null
Assert-True (Test-Path -LiteralPath $jobUnder23) 'dispatcher --older-than 23h keeps a job finished ~22h50m ago'
Assert-True (-not (Test-Path -LiteralPath $jobOver23)) 'dispatcher --older-than 23h deletes a job finished ~23h10m ago'

# --- (16) dispatcher: whole-day --older-than Nd behavior is unchanged by the sub-day fix ---

Write-Host "Dispatcher: --older-than 14d (whole days) still deletes old jobs and keeps young ones"
$s16 = New-CleanupStateRoot
$app16 = New-CleanupAppData
$oldNd = New-CleanupJob -StateRoot $s16 -RepoKey $repoKeyA -JobId 'nd-old' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) -CodexExitCode 0 -WrapperExitCode 0
$youngNd = New-CleanupJob -StateRoot $s16 -RepoKey $repoKeyA -JobId 'nd-young' -Status 'done' -CreatedAt (Get-Ago 2) -FinishedAt (Get-Ago 1) -CodexExitCode 0 -WrapperExitCode 0
& pwsh -NoLogo -NoProfile -File $ccodexPs cleanup --older-than 14d --state-root $s16 | Out-Null
Assert-True (-not (Test-Path -LiteralPath $oldNd)) 'dispatcher --older-than 14d deletes a 40-day-old job'
Assert-True (Test-Path -LiteralPath $youngNd) 'dispatcher --older-than 14d keeps a 1-day-old job'

# --- (17) old done worktree job: worktree removed alongside job dir/index ---

Write-Host "Invoke-CcodexCleanup: an old done worktree job has its worktree removed alongside its job dir and index"
$s17 = New-CleanupStateRoot
$app17 = New-CleanupAppData
$mainRepo17 = New-CleanupGitRepo
$wt17 = New-CcodexJobWorktree -MainRepo $mainRepo17 -JobId 'wtjob' -StateRoot $s17
$wtJobDir = New-CleanupJob -StateRoot $s17 -RepoKey $repoKeyA -JobId 'wtjob' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) `
    -CodexExitCode 0 -WrapperExitCode 0 -MainRepo $mainRepo17 -WorktreeRepo $wt17.WorktreePath -BaseCommit $wt17.BaseCommit
$wtJobIdx = Get-CcodexIndexPath -JobId 'wtjob' -Root $s17
Assert-True (Test-Path -LiteralPath $wt17.WorktreePath -PathType Container) 'worktree exists before cleanup'
$r17 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s17 -AppDataRoot $app17
Assert-True ($r17.Deleted -contains 'wtjob') 'old done worktree job reported in Deleted'
Assert-True (-not (Test-Path -LiteralPath $wtJobDir)) 'old done worktree job dir removed'
Assert-True (-not (Test-Path -LiteralPath $wtJobIdx)) 'old done worktree job index entry removed'
Assert-True (-not (Test-Path -LiteralPath $wt17.WorktreePath)) 'worktree directory removed from disk'
$wtListAfter17 = @(& git -C $mainRepo17 worktree list)
$wtStillListed17 = @($wtListAfter17 | Where-Object { $_ -like "*$($wt17.WorktreePath)*" })
Assert-Equal $wtStillListed17.Count 0 'git worktree list in the main repo no longer shows the removed worktree'

# --- (18) dangling worktree (job dir gone) is swept ---

Write-Host "Invoke-CcodexCleanup: a dangling worktree with no corresponding job dir is swept"
$s18 = New-CleanupStateRoot
$app18 = New-CleanupAppData
$mainRepo18 = New-CleanupGitRepo
$wt18 = New-CcodexJobWorktree -MainRepo $mainRepo18 -JobId 'ghostwt' -StateRoot $s18
Assert-True (Test-Path -LiteralPath $wt18.WorktreePath -PathType Container) 'dangling worktree exists before cleanup'
$r18 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s18 -AppDataRoot $app18
Assert-True (-not (Test-Path -LiteralPath $wt18.WorktreePath)) 'dangling worktree directory removed'
Assert-Equal $r18.WorktreesSweptCount 1 'dangling worktree counted as swept'

# --- (19) dry-run lists a worktree job's worktree as a delete candidate without deleting it ---

Write-Host "Invoke-CcodexCleanup -DryRun: a worktree job's worktree is listed alongside its job, and nothing is deleted"
$s19 = New-CleanupStateRoot
$app19 = New-CleanupAppData
$mainRepo19 = New-CleanupGitRepo
$wt19 = New-CcodexJobWorktree -MainRepo $mainRepo19 -JobId 'wtjobdry' -StateRoot $s19
$wtJobDir19 = New-CleanupJob -StateRoot $s19 -RepoKey $repoKeyA -JobId 'wtjobdry' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) `
    -CodexExitCode 0 -WrapperExitCode 0 -MainRepo $mainRepo19 -WorktreeRepo $wt19.WorktreePath -BaseCommit $wt19.BaseCommit
$r19 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $true -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s19 -AppDataRoot $app19
Assert-True (Test-Path -LiteralPath $wtJobDir19) 'dry-run does not delete the worktree job dir'
Assert-True (Test-Path -LiteralPath $wt19.WorktreePath -PathType Container) 'dry-run does not delete the worktree directory'
Assert-True ($r19.Stdout -match [regex]::Escape("wtjobdry worktree $($wt19.WorktreePath) -> delete")) 'dry-run lists the worktree delete candidate line'

# --- (20) worktree removal failure is NOT counted as swept (over-count guard) ---

Write-Host "Invoke-CcodexCleanup: a worktree whose removal fails is excluded from worktrees_swept and counted as a failure"
$s20 = New-CleanupStateRoot
$app20 = New-CleanupAppData
# A worktree dir OUTSIDE the state root's worktrees/ tree, so the dangling-worktree sweep (which
# scans <root>\worktrees) never finds it — the ONLY chance to count it is Remove-CleanupJob, the
# path this fix guards.
$wt20Path = Join-Path $tempRoot "standalone-wt-$($script:StateRootSeq)"
New-Item -ItemType Directory -Path $wt20Path -Force | Out-Null
$wtFailJobDir = New-CleanupJob -StateRoot $s20 -RepoKey $repoKeyA -JobId 'wtfail' -Status 'done' -CreatedAt (Get-Ago 41) -FinishedAt (Get-Ago 40) `
    -CodexExitCode 0 -WrapperExitCode 0 -MainRepo 'C:\ccodex-nonexistent-main' -WorktreeRepo $wt20Path -BaseCommit 'deadbeef'
# Stub the teardown to report failure WITHOUT deleting, so the path remains and the swept count
# must exclude it. Save/restore so later use of the real function elsewhere is unaffected.
$origRemoveWorktree = ${function:Remove-CcodexJobWorktree}
${function:Remove-CcodexJobWorktree} = { param($MainRepo, $WorktreePath) return $false }
try {
    $r20 = Invoke-CcodexCleanup -OlderThanDays 14 -DryRun $false -IncludeStalled $false -ScrubThreadIds $false -StateRoot $s20 -AppDataRoot $app20
} finally {
    ${function:Remove-CcodexJobWorktree} = $origRemoveWorktree
}
Assert-Equal $r20.WorktreesSweptCount 0 'a failed worktree removal is excluded from worktrees_swept'
Assert-True ($r20.FailedCount -ge 1) 'a failed worktree removal is counted as a failure'
Assert-Equal $r20.WrapperExitCode 12 'a failed worktree removal makes cleanup exit 12'
Assert-True ($r20.Stdout -match 'worktrees_swept=0') 'summary reports worktrees_swept=0 (not over-counted)'
Assert-True (Test-Path -LiteralPath $wt20Path) 'the stubbed-failure worktree dir is still present (removal really did fail)'

# --- cleanup temp ---
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Complete-CcodexTests
