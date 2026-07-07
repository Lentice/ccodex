# lib/Cleanup.ps1
#
# Retention sweep engine for `ccodex cleanup`. Enumerates the jobs/ tree (NOT the index —
# a crash mid-delete can leave an unindexed directory that the tree scan still finds),
# deletes aged terminal jobs (index entry first, then the directory), removes dangling
# index entries, and — under the per-job lock — scrubs the `codex_thread_id` of retained
# terminal jobs older than the thread TTL. Best-effort: per-item failures are counted and
# reported; the sweep keeps going and the command exits 12 only if something failed.
#
# Threshold resolution is explicit params -> user config (%APPDATA%\ccodex\config.json) ->
# built-in defaults (14d jobs / 30d thread ttl). Terminal statuses are
# done/failed/timed_out/cancelled; a terminal job's age is measured from the first present
# of finished_at -> terminated_at -> cancelled_at -> created_at. A stalled job that
# --include-stalled reconciles to terminal is judged by created_at (its true age), because
# reconciliation freshly stamps finished_at = now.

function ConvertTo-CcodexCleanupUtcDateTime {
    # ConvertFrom-Json auto-deserializes ISO-8601 strings into [DateTime]; a naive [string]
    # cast would re-render such a value in the current culture without the zone designator
    # and shift it by the local offset. This returns a correct UTC [DateTime] whether the
    # field came back as a DateTime or a plain string, or $null when neither parses.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Get-CcodexDirSizeBytes {
    param([Parameter(Mandatory)][string]$Path)
    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
    return $sum
}

function Get-CcodexJobEndUtc {
    # Age basis for a terminal job. Normally the first present of
    # finished_at -> terminated_at -> cancelled_at -> created_at; when -PreferCreatedAt is
    # set (a stalled job just reconciled this pass) created_at is used directly so a
    # long-dead job is judged by its true age, not the reconciliation instant.
    param([Parameter(Mandatory)]$Status, [switch]$PreferCreatedAt)
    $candidates = if ($PreferCreatedAt) {
        @($Status.created_at)
    } else {
        @($Status.finished_at, $Status.terminated_at, $Status.cancelled_at, $Status.created_at)
    }
    foreach ($c in $candidates) {
        $dt = ConvertTo-CcodexCleanupUtcDateTime -Value $c
        if ($null -ne $dt) { return $dt }
    }
    return $null
}

function Invoke-CcodexCleanup {
    param(
        [int]$OlderThanDays,
        [Nullable[int]]$ThreadTtlDays,
        [string]$RepoFilter,
        [bool]$DryRun,
        [bool]$IncludeStalled,
        [bool]$ScrubThreadIds,
        [string]$StateRoot = $env:LOCALAPPDATA,
        [string]$AppDataRoot = $env:APPDATA
    )

    $nowUtc = (Get-Date).ToUniversalTime()
    $terminalStatuses = @('done', 'failed', 'timed_out', 'cancelled')

    # --- threshold resolution: explicit params -> user config -> defaults ---
    $jobsDays = $null
    $ttlDays = $null
    if ($PSBoundParameters.ContainsKey('OlderThanDays')) { $jobsDays = [double]$OlderThanDays }
    if ($null -ne $ThreadTtlDays) { $ttlDays = [double]$ThreadTtlDays }
    if ($null -eq $jobsDays -or $null -eq $ttlDays) {
        $cfg = Get-CcodexUserConfig -AppDataRoot $AppDataRoot
        if ($null -eq $jobsDays) { $jobsDays = [double]$cfg.retention.jobs_days }
        if ($null -eq $ttlDays) { $ttlDays = [double]$cfg.retention.thread_ttl_days }
    }

    $deleted = @()
    $scrubbedCount = 0
    $skippedCount = 0
    $failedCount = 0
    $danglingCount = 0
    $reclaimedBytes = 0L
    $lines = @()

    $localRoot = Get-CcodexLocalAppDataRoot -Root $StateRoot
    $jobsRoot = Join-Path $localRoot 'jobs'

    $repoKeyFilter = $null
    if ($RepoFilter) { $repoKeyFilter = Get-CcodexRepoKey -RepoRoot $RepoFilter }

    # ----- helpers scoped to this invocation (close over the accumulators) -----

    function Remove-CleanupJob {
        param([string]$JobId, [string]$JobDir, [string]$StatusText, [double]$AgeDays)
        $size = Get-CcodexDirSizeBytes -Path $JobDir
        if ($DryRun) {
            $script:__ccxLines += ('{0} {1} age={2}d size={3}KB -> delete' -f $JobId, $StatusText, [int][math]::Floor($AgeDays), [int][math]::Round($size / 1024))
            $script:__ccxDeleted += $JobId
            $script:__ccxReclaimed += $size
            return
        }
        try {
            $idxPath = Get-CcodexIndexPath -JobId $JobId -Root $StateRoot
            if (Test-Path -LiteralPath $idxPath -PathType Leaf) { Remove-Item -LiteralPath $idxPath -Force -ErrorAction Stop }
            Remove-Item -LiteralPath $JobDir -Recurse -Force -ErrorAction Stop
            $script:__ccxDeleted += $JobId
            $script:__ccxReclaimed += $size
        } catch {
            $script:__ccxFailed++
            $script:__ccxLines += "$JobId $StatusText -> delete FAILED: $($_.Exception.Message)"
        }
    }

    function Invoke-CleanupScrub {
        param([string]$JobId, [string]$JobDir, [string]$StatusText, [double]$AgeDays)
        if ($DryRun) {
            $size = Get-CcodexDirSizeBytes -Path $JobDir
            $script:__ccxLines += ('{0} {1} age={2}d size={3}KB -> scrub' -f $JobId, $StatusText, [int][math]::Floor($AgeDays), [int][math]::Round($size / 1024))
            $script:__ccxScrubbed++
            return
        }
        try {
            Lock-CcodexJob -JobDir $JobDir -TimeoutSec 10 -CommandName 'cleanup' | Out-Null
            try {
                $statusPath = Join-Path $JobDir 'status.json'
                $raw = Get-Content -LiteralPath $statusPath -Raw
                # Byte-stable rewrite: replace only the codex_thread_id value with null,
                # leaving every other byte untouched (a full ConvertFrom-Json/ConvertTo-Json
                # round-trip would reformat ISO timestamps and break append-only stability).
                $new = [regex]::Replace($raw, '("codex_thread_id"\s*:\s*)"[^"]*"', '${1}null')
                $tmp = "$statusPath.tmp-$([Guid]::NewGuid().ToString('N'))"
                Write-CcodexTextFile -Path $tmp -Content $new
                Move-Item -LiteralPath $tmp -Destination $statusPath -Force
            } finally {
                Unlock-CcodexJob -JobDir $JobDir
            }
            $script:__ccxScrubbed++
        } catch {
            $script:__ccxFailed++
            $script:__ccxLines += "$JobId $StatusText -> scrub FAILED: $($_.Exception.Message)"
        }
    }

    function Resolve-CleanupTerminal {
        # A terminal job (either natively terminal or reconciled): delete if aged out,
        # otherwise scrub its thread id if eligible.
        param([string]$JobId, [string]$JobDir, $Status, [switch]$PreferCreatedAt)
        $statusText = $Status.status
        $endUtc = Get-CcodexJobEndUtc -Status $Status -PreferCreatedAt:$PreferCreatedAt
        if ($null -eq $endUtc) {
            try { $endUtc = (Get-Item -LiteralPath $JobDir -Force).LastWriteTimeUtc } catch { $endUtc = [DateTime]::MinValue }
        }
        $ageDays = ($nowUtc - $endUtc).TotalDays

        if ($ageDays -gt $jobsDays) {
            Remove-CleanupJob -JobId $JobId -JobDir $JobDir -StatusText $statusText -AgeDays $ageDays
            return
        }
        # retained terminal job
        if ($ScrubThreadIds -and $Status.codex_thread_id -and $ageDays -gt $ttlDays) {
            Invoke-CleanupScrub -JobId $JobId -JobDir $JobDir -StatusText $statusText -AgeDays $ageDays
        }
    }

    # PowerShell nested functions cannot assign to the enclosing scope's locals directly;
    # route the mutable accumulators through $script: aliases the helpers can write.
    $script:__ccxLines = $lines
    $script:__ccxDeleted = $deleted
    $script:__ccxReclaimed = $reclaimedBytes
    $script:__ccxScrubbed = $scrubbedCount
    $script:__ccxSkipped = $skippedCount
    $script:__ccxFailed = $failedCount

    # ----- walk the jobs tree -----
    if (Test-Path -LiteralPath $jobsRoot -PathType Container) {
        $repoDirs = if ($repoKeyFilter) {
            $rk = Join-Path $jobsRoot $repoKeyFilter
            if (Test-Path -LiteralPath $rk -PathType Container) { @(Get-Item -LiteralPath $rk) } else { @() }
        } else {
            @(Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue)
        }

        foreach ($repoDir in $repoDirs) {
            foreach ($jd in @(Get-ChildItem -LiteralPath $repoDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $jobDir = $jd.FullName
                $jobId = $jd.Name

                $status = Read-CcodexStatusFile -JobDir $jobDir

                if ($null -eq $status) {
                    # Unreadable status: evidence is gone. Delete only if the dir itself is
                    # older than the threshold; a young one is left for a later pass.
                    $dirTimeUtc = [DateTime]::MinValue
                    try { $dirTimeUtc = (Get-Item -LiteralPath $jobDir -Force).LastWriteTimeUtc } catch { }
                    $dirAgeDays = ($nowUtc - $dirTimeUtc).TotalDays
                    if ($dirAgeDays -gt $jobsDays) {
                        Remove-CleanupJob -JobId $jobId -JobDir $jobDir -StatusText 'unreadable' -AgeDays $dirAgeDays
                    } else {
                        $script:__ccxSkipped++
                        $script:__ccxLines += "$jobId unreadable -> skip (younger than threshold)"
                    }
                    continue
                }

                $statusText = $status.status

                if ($statusText -in $terminalStatuses) {
                    Resolve-CleanupTerminal -JobId $jobId -JobDir $jobDir -Status $status
                    continue
                }

                # Non-terminal.
                if (-not $IncludeStalled) {
                    $script:__ccxSkipped++
                    $script:__ccxLines += "$jobId $statusText -> skip (not terminal)"
                    continue
                }

                $recon = Update-CcodexOrphanStatus -JobDir $jobDir
                if ($recon.Reconciled) {
                    $reconStatus = Read-CcodexStatusFile -JobDir $jobDir
                    if ($reconStatus -and ($reconStatus.status -in $terminalStatuses)) {
                        Resolve-CleanupTerminal -JobId $jobId -JobDir $jobDir -Status $reconStatus -PreferCreatedAt
                    } else {
                        $script:__ccxSkipped++
                        $script:__ccxLines += "$jobId $statusText -> skip (reconciled but not terminal)"
                    }
                } else {
                    $script:__ccxSkipped++
                    $reason = if ($recon.PossiblyStale) { 'possibly-stale' } else { "not terminal ($statusText)" }
                    $script:__ccxLines += "$jobId $statusText -> skip ($reason)"
                }
            }
        }
    }

    # ----- dangling index entries (job_dir missing) -----
    $indexRoot = Join-Path $localRoot 'index'
    if (Test-Path -LiteralPath $indexRoot -PathType Container) {
        foreach ($idx in @(Get-ChildItem -LiteralPath $indexRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $entry = $null
            try { $entry = Get-Content -LiteralPath $idx.FullName -Raw | ConvertFrom-Json } catch { $entry = $null }
            if ($null -eq $entry) { continue }
            if ($repoKeyFilter -and $entry.repo_key -ne $repoKeyFilter) { continue }
            if (Test-Path -LiteralPath $entry.job_dir) { continue }

            if ($DryRun) {
                $script:__ccxLines += "$($entry.job_id) dangling-index -> remove"
                $danglingCount++
            } else {
                try {
                    Remove-Item -LiteralPath $idx.FullName -Force -ErrorAction Stop
                    $danglingCount++
                } catch {
                    $script:__ccxFailed++
                    $script:__ccxLines += "$($idx.Name) dangling-index -> remove FAILED: $($_.Exception.Message)"
                }
            }
        }
    }

    # ----- fold the script-scoped accumulators back -----
    $lines = $script:__ccxLines
    $deleted = @($script:__ccxDeleted)
    $reclaimedBytes = $script:__ccxReclaimed
    $scrubbedCount = $script:__ccxScrubbed
    $skippedCount = $script:__ccxSkipped
    $failedCount = $script:__ccxFailed

    $reclaimedKb = [int][math]::Round($reclaimedBytes / 1024)
    $summary = "cleanup: deleted=$($deleted.Count) reclaimed_kb=$reclaimedKb dangling=$danglingCount scrubbed=$scrubbedCount skipped=$skippedCount failed=$failedCount"
    if ($DryRun) { $summary += ' (dry-run)' }
    $lines += $summary

    $exit = if ($failedCount -gt 0) { 12 } else { 0 }

    return [pscustomobject]@{
        WrapperExitCode = $exit
        Stdout          = ($lines -join "`n")
        Deleted         = @($deleted)
        ScrubbedCount   = $scrubbedCount
        SkippedCount    = $skippedCount
        FailedCount     = $failedCount
    }
}
