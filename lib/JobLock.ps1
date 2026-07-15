# lib/JobLock.ps1
#
# Per-job advisory lock, used as the single-writer gate for status.json. The lock is a
# directory `<JobDir>\.lock\` whose creation is the atomic primitive (NTFS directory
# creation is atomic: two racers, one winner). The winner writes `.lock\owner.json`
# identifying itself; contenders retry, breaking the lock only when it is provably stale
# (dead/mismatched owner AND older than the stale window). Readers never lock — only the
# writers (worker running/terminal writes, orphan reconciliation, cancel, cleanup) do.
#
# Owner identity is `<pid>;<process start time>` in spirit (same pid-reuse defense as the
# backend id): a lock is a candidate for breaking only if the recorded pid is not running
# OR its start time no longer matches the recorded one. This module is self-contained (it
# reuses JobStore's UTF-8-no-BOM writer for owner.json but implements its own liveness
# check) so it can be dot-sourced and tested independently.

$script:CcodexLockStaleAfterMinutes = 10

function ConvertTo-CcodexLockUtcDateTime {
    # owner.json timestamps are written as ISO 'o' strings, but ConvertFrom-Json
    # auto-deserializes ISO-8601 strings into [DateTime] objects (Kind=Utc). A naive
    # [string] cast of such an object re-renders it in the current culture WITHOUT the
    # zone designator, so a re-parse would silently shift it by the local UTC offset.
    # This helper returns a correct UTC [DateTime] whether the field came back as a
    # DateTime (used directly) or a plain string (parsed with the zone preserved), or
    # $null when neither works.
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

function Test-CcodexLockOwnerAlive {
    # True only when the recorded pid is running AND its actual process start time
    # matches the recorded start time (within a 2s tolerance, matching Test-CcodexWorkerAlive).
    param([string]$OwnerPidText, $StartTimeValue)

    $ownerPid = 0
    if (-not [int]::TryParse([string]$OwnerPidText, [ref]$ownerPid)) { return $false }

    $recorded = ConvertTo-CcodexLockUtcDateTime -Value $StartTimeValue
    if ($null -eq $recorded) { return $false }

    try {
        $proc = Get-Process -Id $ownerPid -ErrorAction Stop
        $actual = $proc.StartTime.ToUniversalTime()
        return (($actual - $recorded).Duration().TotalSeconds -le 2)
    } catch {
        return $false
    }
}

function Test-CcodexLockStale {
    # A held lock is stale (safe to break) only when BOTH conditions hold:
    #   1. its owner is dead or its start time mismatches owner.json, and
    #   2. the lock is older than the stale window (10 min).
    # Age is the time since the MORE RECENT of owner.json's acquired_at and the lock
    # directory's last-write time, so a freshly-taken lock is never broken even if its
    # owner already looks dead.
    #
    # An absent owner.json is normally a lock being written this instant (mkdir won,
    # owner.json not yet stamped) and must NOT be stolen — but a crash between the mkdir
    # and the owner.json write (or a failed owner.json write) would otherwise leave an
    # ownerless lock that is un-breakable forever. So an ownerless lock is treated as
    # "held" only while it is fresh; once its directory is older than the stale window it
    # is breakable, using the directory timestamp as the sole age signal.
    param([Parameter(Mandatory)][string]$LockPath)

    $nowUtc = (Get-Date).ToUniversalTime()

    $ownerPath = Join-Path $LockPath 'owner.json'
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
        $dirTimeUtc = [DateTime]::MinValue
        try { $dirTimeUtc = (Get-Item -LiteralPath $LockPath -Force).LastWriteTimeUtc } catch { return $false }
        return ($dirTimeUtc -lt $nowUtc.AddMinutes(-$script:CcodexLockStaleAfterMinutes))
    }

    $owner = $null
    $ownerReadable = $false
    try {
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
        $ownerReadable = ($null -ne $owner)
    } catch {
        $ownerReadable = $false
    }
    if (-not $ownerReadable) {
        # owner.json is present but unreadable/corrupt — e.g. a crash mid-write left invalid or
        # empty JSON. Returning $false ("not stale") here would make the lock permanently
        # un-breakable and every future contender time out forever. Fall back to the same age
        # signal the ownerless branch above uses: breakable once the lock directory is older than
        # the stale window.
        $dirTimeUtc = [DateTime]::MinValue
        try { $dirTimeUtc = (Get-Item -LiteralPath $LockPath -Force).LastWriteTimeUtc } catch { return $false }
        return ($dirTimeUtc -lt $nowUtc.AddMinutes(-$script:CcodexLockStaleAfterMinutes))
    }

    if (Test-CcodexLockOwnerAlive -OwnerPidText $owner.pid -StartTimeValue $owner.process_start_time) {
        return $false
    }

    $acquiredAtUtc = ConvertTo-CcodexLockUtcDateTime -Value $owner.acquired_at

    $dirTimeUtc = [DateTime]::MinValue
    try { $dirTimeUtc = (Get-Item -LiteralPath $LockPath -Force).LastWriteTimeUtc } catch { }

    # Most-recent signal: the lock is only "old" when every signal is old.
    $mostRecent = if ($null -ne $acquiredAtUtc -and $acquiredAtUtc -gt $dirTimeUtc) { $acquiredAtUtc } else { $dirTimeUtc }

    return ($mostRecent -lt $nowUtc.AddMinutes(-$script:CcodexLockStaleAfterMinutes))
}

function Lock-CcodexJob {
    # Acquires the per-job lock, returning { LockPath }. Creates `<JobDir>\.lock\`
    # atomically (New-Item -ErrorAction Stop is the primitive) and stamps owner.json.
    # On contention it retries every 250ms until $TimeoutSec elapses, breaking a stale
    # lock (see Test-CcodexLockStale) on the way. On timeout it throws.
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [int]$TimeoutSec = 10,
        [string]$CommandName = 'unknown'
    )

    $lockPath = Join-Path $JobDir '.lock'
    $ownerPath = Join-Path $lockPath 'owner.json'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    $currentProc = Get-Process -Id $PID
    $currentStartText = $currentProc.StartTime.ToUniversalTime().ToString('o')

    while ($true) {
        $created = $false
        try {
            New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null
            $created = $true
        } catch {
            $created = $false
        }

        if ($created) {
            $owner = [ordered]@{
                pid                = $PID
                process_start_time = $currentStartText
                command            = $CommandName
                hostname           = [System.Environment]::MachineName
                acquired_at        = (Get-Date).ToUniversalTime().ToString('o')
            }
            try {
                Write-CcodexJsonFile -Path $ownerPath -Object $owner
            } catch {
                # We won the mkdir but could not stamp ownership. Leaving the directory
                # behind would be an ownerless lock that only Test-CcodexLockStale's age
                # fallback can reclaim (after the stale window). Best-effort remove it now
                # so a caller can re-create it cleanly, then rethrow the original error.
                try { Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction Stop } catch { }
                throw
            }
            return [pscustomobject]@{ LockPath = $lockPath }
        }

        # Contended. Break it if stale — but ATOMICALLY. Two contenders can both observe the same
        # stale lock; a plain Remove-Item then lets the slower one delete the FRESH lock the faster
        # one already re-created, so both would believe they hold it (concurrent status writers).
        # Instead rename the stale directory to a unique quarantine name first: only the racer
        # whose rename succeeds owns the teardown; a rename that throws (someone else already moved
        # or re-took it) just falls through to a normal retry. NTFS directory rename is atomic, so
        # exactly one breaker wins.
        if (Test-CcodexLockStale -LockPath $lockPath) {
            $quarantine = "$lockPath.stale-$PID-$([Guid]::NewGuid().ToString('N'))"
            try {
                Move-Item -LiteralPath $lockPath -Destination $quarantine -ErrorAction Stop
                Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                # Lost the race to break it (already moved/broken/re-taken); just retry.
            }
            continue
        }

        if ((Get-Date) -ge $deadline) {
            throw "ccodex: could not acquire the job lock for '$JobDir' within ${TimeoutSec}s."
        }
        Start-Sleep -Milliseconds 250
    }
}

function Unlock-CcodexJob {
    # Releases the per-job lock, but only if this process is the recorded owner
    # (pid + start time match). A foreign or already-released lock is left untouched.
    param([Parameter(Mandatory)][string]$JobDir)

    $lockPath = Join-Path $JobDir '.lock'
    $ownerPath = Join-Path $lockPath 'owner.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Container)) { return }

    $ownedByMe = $false
    if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
        try {
            $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
            $ownerPid = 0
            if ($null -ne $owner -and [int]::TryParse([string]$owner.pid, [ref]$ownerPid) -and $ownerPid -eq $PID) {
                $currentProc = Get-Process -Id $PID
                $recorded = ConvertTo-CcodexLockUtcDateTime -Value $owner.process_start_time
                if ($null -ne $recorded) {
                    $delta = ($currentProc.StartTime.ToUniversalTime() - $recorded).Duration()
                    $ownedByMe = $delta.TotalSeconds -le 2
                }
            }
        } catch {
            $ownedByMe = $false
        }
    }

    if ($ownedByMe) {
        try { Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction Stop } catch { }
    }
}
