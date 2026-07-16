# tests/JobStore.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\JobStore.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-jobstore-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Write-CcodexTextFile writes UTF-8 without BOM"
$textPath = Join-Path $tempRoot 'prompt.md'
Write-CcodexTextFile -Path $textPath -Content '請審查'
$bytes = [System.IO.File]::ReadAllBytes($textPath)
Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'no UTF-8 BOM is written'
Assert-Equal ([System.Text.Encoding]::UTF8.GetString($bytes)) '請審查' 'content round-trips exactly'

Write-Host "Write-CcodexJsonFile / Write-CcodexJsonFileAtomic"
$jsonPath = Join-Path $tempRoot 'status.json'
Write-CcodexJsonFileAtomic -Path $jsonPath -Object ([ordered]@{ a = 1; b = 'x' })
$roundTrip = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
Assert-Equal $roundTrip.a 1 'atomic JSON write round-trips field a'
Assert-Equal $roundTrip.b 'x' 'atomic JSON write round-trips field b'
$leftoverTemp = Get-ChildItem -LiteralPath $tempRoot -Filter 'status.json.tmp-*'
Assert-Equal $leftoverTemp.Count 0 'no leftover .tmp file after atomic write'

Write-Host "ConvertTo-CcodexCommandLineText"
$cmdText = ConvertTo-CcodexCommandLineText -Executable 'C:\codex.cmd' -Arguments @('exec', '--sandbox', 'read-only', 'a b')
Assert-Equal $cmdText 'C:\codex.cmd exec --sandbox read-only "a b"' 'quotes only arguments containing whitespace'

Write-Host "New-CcodexStatusObject"
$status = New-CcodexStatusObject -JobId 'job1' -Status 'running' -Mode 'review' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-03T00:00:00Z'
Assert-Equal $status.job_id 'job1' 'status object carries job_id'
Assert-Equal $status.status 'running' 'status object carries status'
Assert-Equal $status.codex_exit_code $null 'codex_exit_code defaults to null'

Write-Host "New-CcodexStatusObject defaults the new backend fields"
Assert-Equal $status.backend 'sync' 'backend defaults to sync when not specified'
Assert-True ([string]::IsNullOrEmpty($status.backend_id)) 'backend_id defaults to null/empty when not specified'
Assert-True ([string]::IsNullOrEmpty($status.started_at)) 'started_at defaults to null/empty when not specified'
Assert-True ([string]::IsNullOrEmpty($status.finished_at)) 'finished_at defaults to null/empty when not specified'

Write-Host "New-CcodexStatusObject round-trips explicit backend fields"
$status2 = New-CcodexStatusObject -JobId 'job2' -Status 'running' -Mode 'review' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-03T00:00:00Z' -Backend 'native' -BackendId '1234;2026-07-03T00:00:00.0000000Z' -StartedAt '2026-07-03T00:00:01Z' -FinishedAt '2026-07-03T00:05:00Z'
Assert-Equal $status2.backend 'native' 'backend round-trips'
Assert-Equal $status2.backend_id '1234;2026-07-03T00:00:00.0000000Z' 'backend_id round-trips'
Assert-Equal $status2.started_at '2026-07-03T00:00:01Z' 'started_at round-trips'
Assert-Equal $status2.finished_at '2026-07-03T00:05:00Z' 'finished_at round-trips'

$statusKeys = [System.Collections.Generic.List[string]]::new()
foreach ($key in $status2.Keys) { $statusKeys.Add($key) }
$createdAtIndex = $statusKeys.IndexOf('created_at')
Assert-Equal $statusKeys[$createdAtIndex + 1] 'backend' 'backend key is ordered immediately after created_at'
Assert-Equal $statusKeys[$createdAtIndex + 2] 'backend_id' 'backend_id key follows backend'
Assert-Equal $statusKeys[$createdAtIndex + 3] 'started_at' 'started_at key follows backend_id'
Assert-Equal $statusKeys[$createdAtIndex + 4] 'finished_at' 'finished_at key follows started_at'

Write-Host "New-CcodexStatusObject defaults FailureReason/CodexThreadId to null/absent"
Assert-True ([string]::IsNullOrEmpty($status.failure_reason)) 'failure_reason defaults to null when not specified'
Assert-True ([string]::IsNullOrEmpty($status.codex_thread_id)) 'codex_thread_id defaults to null when not specified'

Write-Host "New-CcodexStatusObject round-trips FailureReason and CodexThreadId"
$status3 = New-CcodexStatusObject -JobId 'job3' -Status 'failed' -Mode 'review' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-05T00:00:00Z' -FailureReason 'quota_or_rate_limit' -CodexThreadId 'thread-abc-123'
Assert-Equal $status3.failure_reason 'quota_or_rate_limit' 'failure_reason round-trips'
Assert-Equal $status3.codex_thread_id 'thread-abc-123' 'codex_thread_id round-trips'

Write-Host "New-CcodexStatusObject defaults the worktree fields to null (append-only additions)"
Assert-True ([string]::IsNullOrEmpty($status.main_repo)) 'main_repo defaults to null when not specified'
Assert-True ([string]::IsNullOrEmpty($status.worktree_repo)) 'worktree_repo defaults to null when not specified'
Assert-True ([string]::IsNullOrEmpty($status.base_commit)) 'base_commit defaults to null when not specified'
Assert-True ($null -eq $status.worktree_committed) 'worktree_committed defaults to null when not specified'

Write-Host "New-CcodexStatusObject round-trips the worktree fields and keeps the existing key order intact"
$statusWt = New-CcodexStatusObject -JobId 'jobwt' -Status 'done' -Mode 'implement' -Access 'worktree' -Repo 'D:\Repo' -CreatedAt '2026-07-07T00:00:00Z' -MainRepo 'D:\Repo' -WorktreeRepo 'D:\State\ccodex\worktrees\jobwt' -BaseCommit 'abc123def456' -WorktreeCommitted $true
Assert-Equal $statusWt.main_repo 'D:\Repo' 'main_repo round-trips'
Assert-Equal $statusWt.worktree_repo 'D:\State\ccodex\worktrees\jobwt' 'worktree_repo round-trips'
Assert-Equal $statusWt.base_commit 'abc123def456' 'base_commit round-trips'
Assert-Equal $statusWt.worktree_committed $true 'worktree_committed round-trips'
# The new fields are appended, so the earlier backend-block ordering is unchanged.
$statusWtKeys = [System.Collections.Generic.List[string]]::new()
foreach ($key in $statusWt.Keys) { $statusWtKeys.Add($key) }
Assert-Equal $statusWtKeys[$statusWtKeys.IndexOf('created_at') + 1] 'backend' 'backend key still immediately follows created_at after the worktree additions'

Write-Host "New-CcodexStatusObject defaults parent_job_id to null (append-only lineage field)"
Assert-True ([string]::IsNullOrEmpty($status.parent_job_id)) 'parent_job_id defaults to null when not specified'

Write-Host "New-CcodexStatusObject round-trips parent_job_id and appends it after the worktree fields"
$statusResume = New-CcodexStatusObject -JobId 'jobresume' -Status 'done' -Mode 'brainstorm' -Access 'read-only' -Repo 'D:\Repo' -CreatedAt '2026-07-07T00:00:00Z' -ParentJobId 'parent-abc-123'
Assert-Equal $statusResume.parent_job_id 'parent-abc-123' 'parent_job_id round-trips'
$statusResumeKeys = [System.Collections.Generic.List[string]]::new()
foreach ($key in $statusResume.Keys) { $statusResumeKeys.Add($key) }
Assert-Equal $statusResumeKeys[$statusResumeKeys.Count - 3] 'parent_job_id' 'parent_job_id precedes metadata keys'
Assert-Equal $statusResumeKeys[$statusResumeKeys.Count - 2] 'group' 'group follows parent_job_id'
Assert-Equal $statusResumeKeys[$statusResumeKeys.Count - 1] 'label' 'label follows group'
Assert-True ([string]::IsNullOrEmpty($statusResume.group)) 'group defaults null'
Assert-True ([string]::IsNullOrEmpty($statusResume.label)) 'label defaults null'
Assert-Equal $statusResumeKeys[$statusResumeKeys.IndexOf('created_at') + 1] 'backend' 'backend key still immediately follows created_at after the parent_job_id addition'

Write-Host "New-CcodexDebugObject"
$debugObj = New-CcodexDebugObject -JobId 'job1' -Repo 'D:\Repo' -JobDir 'D:\Job' -Mode 'review' -Access 'read-only' -CodexPath 'C:\codex.cmd' -CodexArgs @('exec')
Assert-Equal $debugObj.backend 'sync' 'debug object records sync backend'
Assert-Equal $debugObj.codex_path 'C:\codex.cmd' 'debug object records resolved codex path'
Assert-True ([string]::IsNullOrEmpty($debugObj.worktree_repo)) 'debug object worktree_repo defaults to null'

Write-Host "New-CcodexDebugObject records the worktree fields when supplied"
$debugObjWt = New-CcodexDebugObject -JobId 'job1' -Repo 'D:\Repo' -JobDir 'D:\Job' -Mode 'implement' -Access 'worktree' -CodexPath 'C:\codex.cmd' -CodexArgs @('exec') -MainRepo 'D:\Repo' -WorktreeRepo 'D:\State\ccodex\worktrees\job1' -BaseCommit 'abc123def456'
Assert-Equal $debugObjWt.main_repo 'D:\Repo' 'debug object records main_repo'
Assert-Equal $debugObjWt.worktree_repo 'D:\State\ccodex\worktrees\job1' 'debug object records worktree_repo'
Assert-Equal $debugObjWt.base_commit 'abc123def456' 'debug object records base_commit'

Write-Host "New-CcodexDebugObject honors an explicit -Backend"
$debugObj2 = New-CcodexDebugObject -JobId 'job1' -Repo 'D:\Repo' -JobDir 'D:\Job' -Mode 'review' -Access 'read-only' -CodexPath 'C:\codex.cmd' -CodexArgs @('exec') -Backend 'native'
Assert-Equal $debugObj2.backend 'native' 'debug object honors -Backend native'

Write-Host "New-CcodexWorkerCompleteObject"
$complete = New-CcodexWorkerCompleteObject -JobId 'job1' -StatusCandidate 'done' -CodexExitCode 0 -WrapperExitCode 0 -ResultPresent $true -CompletedAt '2026-07-03T00:01:00Z'
Assert-Equal $complete.status_candidate 'done' 'worker-complete records the status candidate'
Assert-Equal $complete.result_present $true 'worker-complete records result presence'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
