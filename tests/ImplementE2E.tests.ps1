# tests/ImplementE2E.tests.ps1
#
# Phase 4 Task 7 Step 1 (deferred): composed end-to-end coverage for the ccodex worktree
# implementation flow, at the SAME shim level RealInvocation.tests.ps1 / AsyncE2E.tests.ps1
# use for `run`/`submit`/`wait`/etc: a temp bin directory stages a fake `codex.cmd` (the
# fake-codex fixture) alongside a decoy `codex.ps1` (npm-shaped PATH, the codex-resolution
# defect guard those files document), plus a `ccodex.cmd` shim that mirrors the installed
# PATH shim exactly and invokes THIS repo's ccodex.ps1. Every assertion below goes through
# that shim (`& $ccodexCmd submit|wait|diff|apply|cleanup ...`) with `--state-root` (a temp
# dir, never the real LOCALAPPDATA) and `--detach-mechanism startprocess` (env inherits
# under startprocess, matching the fixture's env-var contract; production defaults to
# `cim`, exercised elsewhere).
#
# Chain 1 (happy path): piped implement task -> `submit --mode implement` -> `wait` (the
# fixture writes a file INTO the worktree via its `-C <dir>` parsing) -> `diff` shows the
# change -> `apply` lands it in the main repo -> the main repo file content is verified ->
# `cleanup --older-than 0d` removes the job dir AND its worktree.
#
# Chain 2 (conflict, once end-to-end): the same chain, but the main repo is diverged on the
# SAME file the worker touched before `apply` runs -> `apply` fails with exit 25 and the
# main repo is left byte-for-byte untouched (clean tree, HEAD unchanged).
#
# Both chains additionally assert `diff`/`apply` output never leaks raw Codex JSONL.
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ccodexPs = Join-Path $repoRoot 'ccodex.ps1'
$fakePs = Join-Path $PSScriptRoot 'fixtures\fake-codex.ps1'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-implemente2e-test-$([Guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $tempRoot 'Local'
$appData = Join-Path $tempRoot 'Roaming'
$binDir = Join-Path $tempRoot 'bin'
New-Item -ItemType Directory -Path $stateRoot, $appData, $binDir, (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'templates\worker-prompt.md') -Destination (Join-Path $appData 'ccodex\templates\worker-prompt.md')

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$exitLine = 'exit /' + 'b %ERRORLEVEL%'  # split literal to keep it plain text
# codex.cmd on PATH resolves to the fake-codex fixture.
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.cmd'), "@echo off`r`npwsh -NoProfile -File `"$fakePs`" %*`r`n$exitLine", $utf8NoBom)
# npm-shaped PATH collision guard (mirrors RealInvocation/AsyncE2E): a decoy codex.ps1 ranks
# ABOVE codex.cmd in PowerShell command precedence. It exits nonzero WITHOUT writing
# result.md, so a regression to resolving it instead of codex.cmd breaks the assertions
# below loudly instead of silently.
[System.IO.File]::WriteAllText((Join-Path $binDir 'codex.ps1'), "param() Write-Error 'ccodex resolved codex.ps1 instead of codex.cmd'; exit 3`r`n", $utf8NoBom)
# ccodex.cmd shim mirrors the installed PATH shim exactly.
[System.IO.File]::WriteAllText((Join-Path $binDir 'ccodex.cmd'), "@echo off`r`nsetlocal`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ccodexPs`" %*`r`n$exitLine", $utf8NoBom)
$ccodexCmd = Join-Path $binDir 'ccodex.cmd'

function Invoke-CcodexShim {
    # Invokes the staged ccodex.cmd shim exactly like a real PATH lookup would, capturing
    # stdout/host-output lines and exit code together. Piping $StdinText (when given)
    # exercises the same OS-level redirected-stdin path RealInvocation/AsyncE2E exercise.
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$StdinText = $null)
    if ($null -ne $StdinText) {
        $out = $StdinText | & $ccodexCmd @Arguments
    } else {
        $out = & $ccodexCmd @Arguments
    }
    $exit = $LASTEXITCODE
    $allText = ($out -join "`n")
    $nonEmptyLines = @($out | Where-Object { $_ -ne $null -and $_ -ne '' })
    return [pscustomobject]@{ ExitCode = $exit; Stdout = $allText; Lines = $nonEmptyLines }
}

function New-CcodexE2EGitRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q 2>$null | Out-Null
    & git -C $Path config user.email 'test@example.com' | Out-Null
    & git -C $Path config user.name 'ccodex test' | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), "seed`n", $utf8NoBom)
    & git -C $Path add seed.txt | Out-Null
    & git -C $Path commit -q -m 'init' | Out-Null
}

$savedPath = $env:PATH
$savedAppData = $env:APPDATA
try {
    $env:PATH = "$binDir;$env:PATH"
    $env:APPDATA = $appData

    # ============================================================================
    # Chain 1: happy path -- submit -> wait -> diff -> apply -> cleanup
    # ============================================================================

    Write-Host "chain: piped implement task -> submit -> wait -> diff -> apply -> cleanup (worktree lands in main repo, job+worktree swept)"
    $mainRepoA = Join-Path $tempRoot 'main-happy'
    New-CcodexE2EGitRepo -Path $mainRepoA

    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'implement e2e: wrote the output file'
    $env:CCODEX_FAKE_WRITE_FILE = 'e2e-output.txt'
    $env:CCODEX_FAKE_WRITE_TEXT = 'hello from the e2e worker'

    $implementTask = "Create e2e-output.txt with the requested content."
    $submitA = Invoke-CcodexShim -Arguments @('submit', '--mode', 'implement', '--repo', $mainRepoA, '--state-root', $stateRoot, '--detach-mechanism', 'startprocess') -StdinText $implementTask
    Assert-Equal $submitA.ExitCode 0 'submit --mode implement (piped task) exits 0'
    Assert-Equal $submitA.Lines.Count 2 'submit stdout is exactly two lines (job id, job dir)'
    $jobIdA = $submitA.Lines[0]
    $jobDirA = $submitA.Lines[1]
    Assert-True ($jobIdA -match '-implement$') 'job id is shaped for mode implement'
    Assert-True (Test-Path -LiteralPath $jobDirA -PathType Container) 'job dir exists on disk'
    Assert-True (-not ($submitA.Stdout -like '*fake-codex ran*')) 'submit stdout never carries raw Codex JSONL'
    Assert-True (-not ($submitA.Stdout -like '*codex.ps1 instead*')) 'submit never resolved the shadowing codex.ps1'

    $waitA = Invoke-CcodexShim -Arguments @('wait', $jobIdA, '--state-root', $stateRoot, '--wait-timeout-sec', '30')
    Assert-Equal $waitA.ExitCode 0 'wait on the implement job exits 0 (reaches done within the timeout)'
    Assert-True ($waitA.Stdout -like '*wrote the output file*') 'wait prints the fixture result content'
    Assert-True (-not ($waitA.Stdout -like '*fake-codex ran*')) 'wait stdout never carries raw Codex JSONL'

    Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue

    $statusA = Get-Content -LiteralPath (Join-Path $jobDirA 'status.json') -Raw | ConvertFrom-Json
    Assert-Equal $statusA.status 'done' 'setup: job reached terminal done'
    Assert-Equal $statusA.access 'worktree' 'setup: implement job ran with --access worktree'
    $worktreePathA = [string]$statusA.worktree_repo
    Assert-True (Test-Path -LiteralPath $worktreePathA -PathType Container) 'setup: the worktree still exists on disk before diff/apply'
    Assert-True (Test-Path -LiteralPath (Join-Path $worktreePathA 'e2e-output.txt') -PathType Leaf) 'setup: the fixture wrote the file INTO the worktree via its -C parsing'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $mainRepoA 'e2e-output.txt'))) 'setup: the main repo has NOT been touched by the worker (worktree isolation holds)'

    $diffA = Invoke-CcodexShim -Arguments @('diff', $jobIdA, '--state-root', $stateRoot)
    Assert-Equal $diffA.ExitCode 0 'diff on the done implement job exits 0'
    Assert-True ($diffA.Stdout -like '*e2e-output.txt*') 'diff stdout mentions the changed file'
    Assert-True ($diffA.Stdout -like '*+hello from the e2e worker*') 'diff stdout includes the full patch content'
    Assert-True (-not ($diffA.Stdout -like '*fake-codex ran*')) 'diff stdout never carries raw Codex JSONL'
    Assert-True (-not ($diffA.Stdout -like '*"type":"event"*')) 'diff stdout never carries a raw Codex JSONL event object'

    $preApplyHeadA = (& git -C $mainRepoA rev-parse HEAD).Trim()
    $applyA = Invoke-CcodexShim -Arguments @('apply', $jobIdA, '--state-root', $stateRoot)
    Assert-Equal $applyA.ExitCode 0 'apply on the done implement job exits 0'
    Assert-True (-not ($applyA.Stdout -like '*fake-codex ran*')) 'apply stdout never carries raw Codex JSONL'
    Assert-True (-not ($applyA.Stdout -like '*"type":"event"*')) 'apply stdout never carries a raw Codex JSONL event object'

    Assert-True (Test-Path -LiteralPath (Join-Path $mainRepoA 'e2e-output.txt') -PathType Leaf) 'apply landed the worker file in the MAIN repo'
    $appliedContentA = Get-Content -LiteralPath (Join-Path $mainRepoA 'e2e-output.txt') -Raw
    Assert-Equal $appliedContentA 'hello from the e2e worker' 'main repo file content is exactly what the worker wrote'
    $postApplyHeadA = (& git -C $mainRepoA rev-parse HEAD).Trim()
    Assert-True ($postApplyHeadA -ne $preApplyHeadA) 'apply advanced the main repo HEAD by the applied commit'
    $appliedAuthorA = (& git -C $mainRepoA log -1 '--format=%an <%ae>').Trim()
    Assert-Equal $appliedAuthorA 'ccodex-worker <ccodex@local>' 'applied commit preserves the fixed ccodex-worker author identity'

    $cleanupA = Invoke-CcodexShim -Arguments @('cleanup', '--older-than', '0d', '--state-root', $stateRoot, '--repo', $mainRepoA)
    Assert-Equal $cleanupA.ExitCode 0 'cleanup --older-than 0d exits 0'
    Assert-True ($cleanupA.Stdout -match 'deleted=1') 'cleanup summary reports the one done job deleted'
    Assert-True ($cleanupA.Stdout -match 'worktrees_swept=1') 'cleanup summary reports the one worktree swept'
    Assert-True (-not (Test-Path -LiteralPath $jobDirA)) 'cleanup removed the job dir'
    Assert-True (-not (Test-Path -LiteralPath $worktreePathA)) 'cleanup removed the worktree directory'
    $wtListAfterA = @(& git -C $mainRepoA worktree list)
    $wtStillListedA = @($wtListAfterA | Where-Object { $_ -like "*$worktreePathA*" })
    Assert-Equal $wtStillListedA.Count 0 'git worktree list in the main repo no longer references the removed worktree'
    Assert-True (Test-Path -LiteralPath (Join-Path $mainRepoA 'e2e-output.txt') -PathType Leaf) 'cleanup did not touch the already-applied file in the main repo'

    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

    # ============================================================================
    # Chain 2: conflict path, once end-to-end -- apply -> exit 25, main repo untouched
    # ============================================================================

    Write-Host "chain: implement job whose write conflicts with a main-repo divergence -> apply exits 25 end-to-end, main repo untouched"
    $mainRepoB = Join-Path $tempRoot 'main-conflict'
    New-CcodexE2EGitRepo -Path $mainRepoB

    $env:CCODEX_FAKE_EXIT_CODE = '0'
    $env:CCODEX_FAKE_RESULT = 'implement e2e: modified seed.txt'
    $env:CCODEX_FAKE_WRITE_FILE = 'seed.txt'
    $env:CCODEX_FAKE_WRITE_TEXT = 'worker version'

    $conflictTask = "Rewrite seed.txt for the e2e conflict scenario."
    $submitB = Invoke-CcodexShim -Arguments @('submit', '--mode', 'implement', '--repo', $mainRepoB, '--state-root', $stateRoot, '--detach-mechanism', 'startprocess') -StdinText $conflictTask
    Assert-Equal $submitB.ExitCode 0 'conflict-setup submit exits 0'
    $jobIdB = $submitB.Lines[0]
    $jobDirB = $submitB.Lines[1]

    $waitB = Invoke-CcodexShim -Arguments @('wait', $jobIdB, '--state-root', $stateRoot, '--wait-timeout-sec', '30')
    Assert-Equal $waitB.ExitCode 0 'conflict-setup wait exits 0'

    Remove-Item Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT, Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue

    # Diverge the SAME file on the main repo, on top of the same base, and commit it -- this
    # is what makes the worker's patch fail to apply textually.
    [System.IO.File]::WriteAllText((Join-Path $mainRepoB 'seed.txt'), "main version`n", $utf8NoBom)
    & git -C $mainRepoB add seed.txt | Out-Null
    & git -C $mainRepoB commit -q -m 'main diverges seed.txt' | Out-Null
    $preHeadB = (& git -C $mainRepoB rev-parse HEAD).Trim()
    $prePorcelainB = @(& git -C $mainRepoB status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
    Assert-Equal $prePorcelainB.Count 0 'setup: main repo is clean before the failing apply'

    $diffB = Invoke-CcodexShim -Arguments @('diff', $jobIdB, '--state-root', $stateRoot)
    Assert-Equal $diffB.ExitCode 0 'diff on the (not-yet-applied) conflicting job still exits 0'
    Assert-True (-not ($diffB.Stdout -like '*fake-codex ran*')) 'diff stdout never carries raw Codex JSONL (conflict setup)'
    Assert-True (-not ($diffB.Stdout -like '*"type":"event"*')) 'diff stdout never carries a raw Codex JSONL event object (conflict setup)'

    $applyB = Invoke-CcodexShim -Arguments @('apply', $jobIdB, '--state-root', $stateRoot)
    Assert-Equal $applyB.ExitCode 25 'apply with a textual conflict exits 25, end-to-end through the shim'
    Assert-True (-not ($applyB.Stdout -like '*fake-codex ran*')) 'apply (conflict) stdout never carries raw Codex JSONL'
    Assert-True (-not ($applyB.Stdout -like '*"type":"event"*')) 'apply (conflict) stdout never carries a raw Codex JSONL event object'
    Assert-True ($applyB.Stdout -like '*seed.txt*') 'exit-25 message names the conflicting file'
    Assert-True ($applyB.Stdout -like "*ccodex diff $jobIdB*") 'exit-25 message points at ccodex diff'

    $postPorcelainB = @(& git -C $mainRepoB status --porcelain | Where-Object { $_ -and $_.Trim() -ne '' })
    Assert-Equal $postPorcelainB.Count 0 'main repo working tree is clean after the failed apply'
    $postHeadB = (& git -C $mainRepoB rev-parse HEAD).Trim()
    Assert-Equal $postHeadB $preHeadB 'main repo HEAD is unchanged after the failed apply'
    $mainSeedContentB = Get-Content -LiteralPath (Join-Path $mainRepoB 'seed.txt') -Raw
    Assert-True ($mainSeedContentB -like '*main version*') 'main repo file content is untouched (still the main-diverged version)'

    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT -ErrorAction SilentlyContinue
} finally {
    $env:PATH = $savedPath
    $env:APPDATA = $savedAppData
    Remove-Item Env:\CCODEX_FAKE_EXIT_CODE, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_WRITE_FILE, Env:\CCODEX_FAKE_WRITE_TEXT -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}

Complete-CcodexTests
