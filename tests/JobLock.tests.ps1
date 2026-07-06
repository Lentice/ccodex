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

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
