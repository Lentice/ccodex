# tests/JobLock.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobLock.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-joblock-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-TestJobDir {
    param([string]$Name)
    $dir = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# --- acquire/release round-trip ---

Write-Host "Lock-CcodexJob acquires the lock and Unlock-CcodexJob releases it"
$dir1 = New-TestJobDir 'roundtrip'
$lock1 = Lock-CcodexJob -JobDir $dir1 -CommandName 'test-cmd'
Assert-Equal $lock1.LockPath (Join-Path $dir1 '.lock') 'LockPath is <JobDir>\.lock'
Assert-True (Test-Path -LiteralPath (Join-Path $dir1 '.lock') -PathType Container) '.lock directory exists while held'
Assert-True (Test-Path -LiteralPath (Join-Path $dir1 '.lock\owner.json') -PathType Leaf) 'owner.json exists while held'
Unlock-CcodexJob -JobDir $dir1
Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir1 '.lock'))) '.lock directory removed after release'

Write-Host "Lock-CcodexJob can be re-acquired after release"
$lock1b = Lock-CcodexJob -JobDir $dir1
Assert-True (Test-Path -LiteralPath (Join-Path $dir1 '.lock') -PathType Container) 're-acquired after release'
Unlock-CcodexJob -JobDir $dir1

# --- owner.json fields present ---

Write-Host "owner.json carries pid, process_start_time, command, hostname, acquired_at"
$dir2 = New-TestJobDir 'owner-fields'
Lock-CcodexJob -JobDir $dir2 -CommandName 'cancel' | Out-Null
$owner = Get-Content -LiteralPath (Join-Path $dir2 '.lock\owner.json') -Raw | ConvertFrom-Json
Assert-Equal ([int]$owner.pid) $PID 'owner.json pid is this process'
Assert-True ($null -ne $owner.process_start_time -and $owner.process_start_time -ne '') 'owner.json has process_start_time'
Assert-Equal $owner.command 'cancel' 'owner.json command is the passed CommandName'
Assert-Equal $owner.hostname ([System.Environment]::MachineName) 'owner.json hostname is this machine'
Assert-True ($null -ne $owner.acquired_at -and $owner.acquired_at -ne '') 'owner.json has acquired_at'
Unlock-CcodexJob -JobDir $dir2

# --- contention: second acquire while held times out and throws ---

Write-Host "Lock-CcodexJob throws when the lock is held by a live owner (contention)"
$dir3 = New-TestJobDir 'contention'
Lock-CcodexJob -JobDir $dir3 | Out-Null
Assert-Throws { Lock-CcodexJob -JobDir $dir3 -TimeoutSec 1 } 'second acquire with 1s timeout while held throws'
Unlock-CcodexJob -JobDir $dir3

# --- stale-break: dead owner + old timestamps -> acquire succeeds ---

Write-Host "Lock-CcodexJob breaks a stale lock (dead pid + old acquired_at + old dir timestamp)"
$dir4 = New-TestJobDir 'stale-break'
$staleLockPath = Join-Path $dir4 '.lock'
New-Item -ItemType Directory -Path $staleLockPath -Force | Out-Null
$staleOwner = [ordered]@{
    pid                = 999999
    process_start_time = '2020-01-01T00:00:00.0000000Z'
    command            = 'ghost'
    hostname           = 'ghost-host'
    acquired_at        = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
}
Write-CcodexJsonFile -Path (Join-Path $staleLockPath 'owner.json') -Object $staleOwner
(Get-Item -LiteralPath $staleLockPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)
$lock4 = Lock-CcodexJob -JobDir $dir4 -TimeoutSec 2 -CommandName 'breaker'
Assert-True ($null -ne $lock4) 'stale lock was broken and re-acquired'
$owner4 = Get-Content -LiteralPath (Join-Path $staleLockPath 'owner.json') -Raw | ConvertFrom-Json
Assert-Equal $owner4.command 'breaker' 'owner.json was replaced by the breaker'
Assert-Equal ([int]$owner4.pid) $PID 'broken lock is now owned by this process'
Unlock-CcodexJob -JobDir $dir4

# --- fresh foreign lock is NOT broken (recent timestamp, even with a dead pid) ---

Write-Host "Lock-CcodexJob does NOT break a fresh foreign lock (recent acquired_at)"
$dir5 = New-TestJobDir 'fresh-foreign'
$freshLockPath = Join-Path $dir5 '.lock'
New-Item -ItemType Directory -Path $freshLockPath -Force | Out-Null
$freshOwner = [ordered]@{
    pid                = 999999
    process_start_time = '2020-01-01T00:00:00.0000000Z'
    command            = 'foreign'
    hostname           = 'other-host'
    acquired_at        = (Get-Date).ToUniversalTime().ToString('o')
}
Write-CcodexJsonFile -Path (Join-Path $freshLockPath 'owner.json') -Object $freshOwner
Assert-Throws { Lock-CcodexJob -JobDir $dir5 -TimeoutSec 1 } 'a fresh foreign lock is not broken and acquire times out'
$owner5 = Get-Content -LiteralPath (Join-Path $freshLockPath 'owner.json') -Raw | ConvertFrom-Json
Assert-Equal $owner5.command 'foreign' 'fresh foreign owner.json is left untouched'

# --- Unlock is a no-op on a foreign lock ---

Write-Host "Unlock-CcodexJob does not remove a lock owned by another process"
Unlock-CcodexJob -JobDir $dir5
Assert-True (Test-Path -LiteralPath $freshLockPath -PathType Container) 'foreign lock survives an Unlock by a non-owner'

# --- Unlock is a no-op when there is no lock ---

Write-Host "Unlock-CcodexJob is a no-op when no lock exists"
$dir6 = New-TestJobDir 'no-lock'
try {
    Unlock-CcodexJob -JobDir $dir6
    Assert-True $true 'Unlock with no lock does not throw'
} catch {
    Assert-True $false "Unlock with no lock threw: $($_.Exception.Message)"
}

# --- ownerless lock: stale only once older than the window (crash between mkdir and owner.json) ---

Write-Host "Test-CcodexLockStale: an ownerless lock older than the stale window is stale"
$dirOwnerless = New-TestJobDir 'ownerless-stale'
$ownerlessLockPath = Join-Path $dirOwnerless '.lock'
New-Item -ItemType Directory -Path $ownerlessLockPath -Force | Out-Null
# No owner.json (simulates a crash / failed owner write between mkdir and stamp).
(Get-Item -LiteralPath $ownerlessLockPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-11)
Assert-True (Test-CcodexLockStale -LockPath $ownerlessLockPath) 'an ownerless lock older than 10 min is stale (breakable)'

Write-Host "Test-CcodexLockStale: a fresh ownerless lock is NOT stale (mid-creation window protected)"
$dirOwnerlessFresh = New-TestJobDir 'ownerless-fresh'
$ownerlessFreshLockPath = Join-Path $dirOwnerlessFresh '.lock'
New-Item -ItemType Directory -Path $ownerlessFreshLockPath -Force | Out-Null
Assert-True (-not (Test-CcodexLockStale -LockPath $ownerlessFreshLockPath)) 'a fresh ownerless lock (being created this instant) is not stale'

Write-Host "Lock-CcodexJob breaks an ownerless stale lock and re-acquires it"
$lockOwnerless = Lock-CcodexJob -JobDir $dirOwnerless -TimeoutSec 2 -CommandName 'breaker-ownerless'
Assert-True ($null -ne $lockOwnerless) 'ownerless stale lock was broken and re-acquired'
Assert-True (Test-Path -LiteralPath (Join-Path $ownerlessLockPath 'owner.json') -PathType Leaf) 'the re-acquired lock now carries an owner.json'
$ownerOwnerless = Get-Content -LiteralPath (Join-Path $ownerlessLockPath 'owner.json') -Raw | ConvertFrom-Json
Assert-Equal $ownerOwnerless.command 'breaker-ownerless' 'the re-acquired ownerless lock is owned by this process'
Unlock-CcodexJob -JobDir $dirOwnerless

Write-Host "Lock-CcodexJob does NOT break a fresh ownerless lock (acquire times out)"
Assert-Throws { Lock-CcodexJob -JobDir $dirOwnerlessFresh -TimeoutSec 1 } 'a fresh ownerless lock is not broken and acquire times out'

# --- owner.json write failure removes the just-created lock dir before rethrowing ---
# NOTE: this shadows Write-CcodexJsonFile, so it MUST be the last Lock-CcodexJob test.

Write-Host "Lock-CcodexJob removes the just-created lock dir when stamping owner.json fails"
$dirWriteFail = New-TestJobDir 'owner-write-fail'
function Write-CcodexJsonFile { param($Path, $Object) throw 'simulated owner.json write failure' }
$threwWriteFail = $false
try {
    Lock-CcodexJob -JobDir $dirWriteFail -TimeoutSec 1 -CommandName 'writer' | Out-Null
} catch {
    $threwWriteFail = $true
}
Assert-True $threwWriteFail 'Lock-CcodexJob rethrows when owner.json cannot be written'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $dirWriteFail '.lock'))) 'the ownerless lock dir is removed after an owner.json write failure (not left un-breakable)'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
