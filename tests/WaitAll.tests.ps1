. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ccodex.ps1') -ImportOnly

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('ccodex-waitall-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $root 'repo'
New-Item -ItemType Directory -Path $repo -Force | Out-Null
$repoKey = Get-CcodexRepoKey -RepoRoot $repo
$appData = Join-Path $root 'Roaming'
New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex\templates') -Force | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\worker-prompt.md') (Join-Path $appData 'ccodex\templates\worker-prompt.md')
$fixture = Join-Path $PSScriptRoot 'fixtures\fake-codex.cmd'

function Submit-WaitJob {
    param([string]$Group, [string]$Label)
    Invoke-CcodexSubmit -Mode review -RepoOverride $repo -PositionalTask 'batch task' -PipelineExpected $false `
        -DetachMechanism startprocess -CodexPath $fixture -LocalAppDataRoot $root -AppDataRoot $appData -Group $Group -Label $Label
}

function Add-WaitJob {
    param([string]$Id, [string]$Status, [int]$Code = 0, [string]$Group = $null, [string]$Label = $null, [string]$Result = $null)
    $dir = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $root) $Id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $obj = New-CcodexStatusObject -JobId $Id -Status $Status -Mode test -Access read-only -Repo $repo -CreatedAt (Get-Date).ToString('o') `
        -CodexExitCode $(if ($Status -eq 'done') { 0 } else { $null }) -WrapperExitCode $(if ($Status -eq 'done') { 0 } elseif ($Status -eq 'failed') { $Code } elseif ($Status -eq 'cancelled') { 22 } else { $null }) -Group $Group -Label $Label
    Write-CcodexJsonFileAtomic -Path (Join-Path $dir 'status.json') -Object $obj
    if ($null -ne $Result) { Write-CcodexTextFile -Path (Join-Path $dir 'result.md') -Content $Result }
    return $dir
}

try {
    Write-Host 'fake-codex E2E transitions two detached jobs during one mixed-outcome batch wait'
    $env:CCODEX_FAKE_DELAY_MS = '2500'; $env:CCODEX_FAKE_RESULT = 'BATCH SUCCESS'; $env:CCODEX_FAKE_EXIT_CODE = '0'
    $e2eSuccess = Submit-WaitJob e2e ok
    $env:CCODEX_FAKE_RESULT = 'BATCH FAILURE'; $env:CCODEX_FAKE_EXIT_CODE = '7'
    $e2eFailure = Submit-WaitJob e2e failed
    Assert-Equal $e2eSuccess.WrapperExitCode 0
    Assert-Equal $e2eFailure.WrapperExitCode 0
    $e2e = Invoke-CcodexWaitAllCommand -StateRoot $root -Group e2e -Json -WaitTimeoutSec 30
    $e2eJson = $e2e.Stdout | ConvertFrom-Json
    Assert-Equal $e2e.WrapperExitCode 10 'mixed detached outcomes select failure exit 10'
    Assert-Equal $e2eJson.jobs.Count 2
    Assert-Equal $e2eJson.summary.succeeded 1
    Assert-Equal $e2eJson.summary.failed 1
    $listJsonText = & pwsh -NoProfile -File (Join-Path (Split-Path $PSScriptRoot -Parent) ccodex.ps1) list --group e2e --label ok --json --state-root $root
    Assert-Equal $LASTEXITCODE 0 'CLI list group/label JSON succeeds'
    $listJson = $listJsonText | ConvertFrom-Json
    Assert-Equal $listJson.count 1 'CLI list group/label filters count'
    Assert-Equal $listJson.jobs[0].label 'ok'
    Remove-Item Env:\CCODEX_FAKE_DELAY_MS, Env:\CCODEX_FAKE_RESULT, Env:\CCODEX_FAKE_EXIT_CODE -ErrorAction SilentlyContinue

    Write-Host 'wait --all per-job reconciliation never blocks on a held lock; it honors its wait budget and converges once released (backlog #16)'
    # Reconcilable orphan (running + dead backend + parsable exit-code evidence) with its per-job
    # lock held by THIS live process, so wait --all's per-job reconciliation attempt is genuinely
    # contended (issue #2 amendment 1 + 6). Under the zero-wait contract each poll's reconcile is
    # instant, so the batch returns at its own wait budget (exit 20) instead of stalling on the lock.
    $fabricatedDeadBackendId = '999999;2020-01-01T00:00:00.0000000Z'
    $contendedDir = Add-WaitJob '20260716T000009Z-99999999-test' running 0 contend x
    $contendedStatus = Get-Content -LiteralPath (Join-Path $contendedDir status.json) -Raw | ConvertFrom-Json
    $contendedStatus.backend_id = $fabricatedDeadBackendId
    Write-CcodexJsonFileAtomic -Path (Join-Path $contendedDir status.json) -Object $contendedStatus
    Write-CcodexTextFile -Path (Join-Path $contendedDir exit_code.txt) -Content '0'
    Write-CcodexTextFile -Path (Join-Path $contendedDir result.md) -Content 'CONTENDED RESULT'
    $contendedBefore = (Get-Item (Join-Path $contendedDir status.json)).LastWriteTimeUtc
    Lock-CcodexJob -JobDir $contendedDir -TimeoutSec 1 -CommandName 'test-holder' | Out-Null
    try {
        $contendStart = Get-Date
        $contended = Invoke-CcodexWaitAllCommand -StateRoot $root -Group contend -WaitTimeoutSec 3 -Json
        $contendElapsed = ((Get-Date) - $contendStart).TotalSeconds
    } finally {
        Unlock-CcodexJob -JobDir $contendedDir
    }
    $contendedJson = $contended.Stdout | ConvertFrom-Json
    Assert-Equal $contended.WrapperExitCode 20 'a held reconciliation lock leaves the batch job unresolved -> wait-timeout exit 20'
    Assert-Equal $contendedJson.jobs[0].status running 'the contended job is reported still running (possibly-stale), never reconciled under the held lock'
    Assert-Equal $contendedJson.jobs[0].health 'possibly-stale' 'the contended job carries health=possibly-stale in the timeout envelope'
    Assert-True ($contendElapsed -lt 6) 'wait --all does not stall on the per-job lock (no 10s-scale wait stacked on the 3s budget)'
    Assert-Equal (Get-Item (Join-Path $contendedDir status.json)).LastWriteTimeUtc $contendedBefore 'contended wait --all left status.json unwritten'

    $contendedAfter = Invoke-CcodexWaitAllCommand -StateRoot $root -Group contend -WaitTimeoutSec 3 -Json
    $contendedAfterJson = $contendedAfter.Stdout | ConvertFrom-Json
    Assert-Equal $contendedAfterJson.jobs[0].status done 'once the lock is free, a later wait --all reconciles the orphan to its terminal status'

    Write-Host 'zero matches and unusable root'
    $empty = Invoke-CcodexWaitAllCommand -StateRoot $root -Json
    Assert-Equal $empty.WrapperExitCode 0
    Assert-Equal (($empty.Stdout | ConvertFrom-Json).jobs.Count) 0
    Assert-Equal (Invoke-CcodexWaitAllCommand -StateRoot $root).Stdout 'ccodex: no non-terminal jobs match.'
    Assert-Equal (Invoke-CcodexWaitAllCommand -StateRoot (Join-Path $root missing)).WrapperExitCode 3

    Write-Host 'timeout preserves actual created status and does not mutate status.json'
    $createdDir = Add-WaitJob '20260716T000004Z-dddddddd-test' created 0 g2 l2
    $before = Get-Content -LiteralPath (Join-Path $createdDir status.json) -Raw
    $timeout = Invoke-CcodexWaitAllCommand -StateRoot $root -Group g2 -WaitTimeoutSec 1 -Json
    $timeoutJson = $timeout.Stdout | ConvertFrom-Json
    Assert-Equal $timeout.WrapperExitCode 20
    Assert-Equal $timeoutJson.jobs[0].status created
    Assert-Equal $timeoutJson.jobs[0].command_exit_code 20
    Assert-Equal $timeoutJson.summary.wait_timeout 1
    Assert-Equal (Get-Content -LiteralPath (Join-Path $createdDir status.json) -Raw) $before

    Write-Host 'terminal classification, precedence, ordering, filters, and human output'
    $doneDir = Add-WaitJob '20260716T000003Z-cccccccc-test' running 0 g1 success
    $failedDir = Add-WaitJob '20260716T000002Z-bbbbbbbb-test' running 0 g1 failure
    $cancelDir = Add-WaitJob '20260716T000001Z-aaaaaaaa-test' running 0 g1 cancelled
    $script:findingsBlockResult = @'
Prose review.

<!-- ccodex:findings -->
```json
{ "verdict": "batch verdict", "items": [ { "severity": "critical", "file": "x.ps1", "line": 9, "claim": "boom", "evidence": "e", "suggested_fix": "f" } ] }
```
'@
    $script:findingsDir = Add-WaitJob '20260716T000008Z-hhhhhhhh-test' running 0 fgrp x
    $script:checks = 0
    function Update-CcodexOrphanStatus {
        param([string]$JobDir, [int]$LockTimeoutSec)
        $script:checks++
        $s = Read-CcodexStatusFile -JobDir $JobDir
        if ($s.status -eq 'running') {
            if ($JobDir -eq $script:findingsDir) { $s.status = 'done'; $s.wrapper_exit_code = 0; $s.codex_exit_code = 0; Write-CcodexTextFile -Path (Join-Path $JobDir result.md) -Content $script:findingsBlockResult }
            elseif ($JobDir -eq $doneDir -or $JobDir -notin @($failedDir, $cancelDir, $script:soloCancelDir)) { $s.status = 'done'; $s.wrapper_exit_code = 0; $s.codex_exit_code = 0; Write-CcodexTextFile -Path (Join-Path $JobDir result.md) -Content 'SECRET-RESULT' }
            elseif ($JobDir -eq $failedDir) { $s.status = 'failed'; $s.wrapper_exit_code = 10 }
            elseif ($JobDir -eq $script:soloCancelDir) { $s.status = 'cancelled'; $s.wrapper_exit_code = 22 }
            else { $s.status = 'cancelled'; $s.wrapper_exit_code = 22 }
            Write-CcodexJsonFileAtomic -Path (Join-Path $JobDir status.json) -Object $s
        }
        [pscustomobject]@{ PossiblyStale = $false; Status = $s.status }
    }
    $mixed = Invoke-CcodexWaitAllCommand -StateRoot $root -Group g1 -Json
    $mixedJson = $mixed.Stdout | ConvertFrom-Json
    Assert-Equal $mixed.WrapperExitCode 10
    Assert-Equal $mixedJson.jobs.Count 3
    Assert-Equal $mixedJson.jobs[0].job_id '20260716T000003Z-cccccccc-test'
    Assert-Equal $mixedJson.summary.succeeded 1
    Assert-Equal $mixedJson.summary.failed 1
    Assert-Equal $mixedJson.summary.cancelled 1
    Assert-Equal @($mixedJson.jobs[0].PSObject.Properties).Count 11
    Assert-True ($mixedJson.jobs[0].PSObject.Properties.Name -contains 'findings') 'each nested wait --all envelope carries a findings key'
    Assert-True ($null -eq $mixedJson.jobs[0].findings) 'a reconciled job whose result has no findings block reports findings: null'
    Add-WaitJob '20260716T000007Z-gggggggg-test' running 0 human x | Out-Null
    $human = Invoke-CcodexWaitAllCommand -StateRoot $root -Group human
    Assert-True ($human.Stdout -match '  done  exit=0') 'human mode prints one terminal line'
    Assert-True ($human.Stdout -match 'ccodex: 1 jobs') 'human mode prints summary'
    Assert-True ($human.Stdout -notmatch 'SECRET-RESULT') 'human batch mode does not print result content'

    Write-Host 'wait --all nested envelope carries parsed findings when a reconciled result has a block'
    $fgrp = Invoke-CcodexWaitAllCommand -StateRoot $root -Group fgrp -Json
    $fgrpJson = $fgrp.Stdout | ConvertFrom-Json
    Assert-Equal $fgrpJson.jobs.Count 1 'findings-group batch has one job'
    Assert-True ($null -ne $fgrpJson.jobs[0].findings) 'reconciled findings-bearing result yields parsed findings in the batch entry'
    Assert-Equal $fgrpJson.jobs[0].findings.verdict 'batch verdict' 'batch entry findings verdict parsed'
    Assert-Equal $fgrpJson.jobs[0].findings.items[0].severity 'critical' 'batch entry findings item parsed'

    Write-Host 'cancelled-only precedence'
    $script:soloCancelDir = Add-WaitJob '20260716T000005Z-eeeeeeee-test' running 0 solo x
    $cancelled = Invoke-CcodexWaitAllCommand -StateRoot $root -Group solo -Json
    Assert-Equal $cancelled.WrapperExitCode 22

    Write-Host 'unknown entries are excluded from filtered wait selection'
    $bad = Join-Path (Get-CcodexJobsDir -RepoKey $repoKey -Root $root) '20260716T000006Z-ffffffff-test'
    New-Item -ItemType Directory -Path $bad -Force | Out-Null
    Write-CcodexTextFile -Path (Join-Path $bad status.json) -Content 'not-json'
    Assert-Equal (Invoke-CcodexWaitAllCommand -StateRoot $root -Group absent -Json).WrapperExitCode 0

    Write-Host 'shell usage validation'
    $cli = Join-Path (Split-Path $PSScriptRoot -Parent) ccodex.ps1
    & pwsh -NoProfile -File $cli wait --all fake-job --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'job id after --all rejected'
    & pwsh -NoProfile -File $cli wait fake-job --all --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'job id before --all rejected'
    & pwsh -NoProfile -File $cli wait --group x --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'group without all rejected'
    & pwsh -NoProfile -File $cli wait --label x --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'label without all rejected'
    & pwsh -NoProfile -File $cli wait --all --group --json --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'bare group rejected'
    & pwsh -NoProfile -File $cli wait --all --label --json --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'bare label rejected'
    & pwsh -NoProfile -File $cli list --group --json --state-root $root 2>$null | Out-Null
    Assert-Equal $LASTEXITCODE 2 'bare list group rejected'
} finally {
    Remove-Item function:Update-CcodexOrphanStatus -ErrorAction SilentlyContinue
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}

Complete-CcodexTests
