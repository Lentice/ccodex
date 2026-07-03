# tests/WorkerPrompt.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\WorkerPrompt.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-workerprompt-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$appDataRoot = Join-Path $tempRoot 'AppData'
New-Item -ItemType Directory -Path (Join-Path $appDataRoot 'ccodex\templates') -Force | Out-Null
$userTemplate = Join-Path $appDataRoot 'ccodex\templates\worker-prompt.md'
[System.IO.File]::WriteAllText($userTemplate, "USER TEMPLATE Mode={{MODE}} Access={{ACCESS}} Repo={{REPO_ROOT}} Artifact={{ARTIFACT_DIR}}", (New-Object System.Text.UTF8Encoding($false)))

$repoRoot = Join-Path $tempRoot 'repo'
New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

Write-Host "falls back to the user-level template when no project override exists"
$path = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $appDataRoot
Assert-Equal $path $userTemplate 'resolves to the user-level template'

Write-Host "prefers a project-local .ccodex/worker-prompt.md override"
New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
$projectTemplate = Join-Path $repoRoot '.ccodex\worker-prompt.md'
[System.IO.File]::WriteAllText($projectTemplate, "PROJECT TEMPLATE {{MODE}}", (New-Object System.Text.UTF8Encoding($false)))
$path2 = Get-CcodexWorkerPromptTemplatePath -RepoRoot $repoRoot -AppDataRoot $appDataRoot
Assert-Equal $path2 $projectTemplate 'project-local override wins over the user-level default'

Write-Host "Build-CcodexWorkerPrompt substitutes placeholders and appends task content"
$rendered = Build-CcodexWorkerPrompt -TemplatePath $userTemplate -Mode 'review' -Access 'read-only' -RepoRoot $repoRoot -ArtifactDir $null -TaskContent 'please review this diff'
Assert-True ($rendered -like '*Mode=review*') 'substitutes {{MODE}}'
Assert-True ($rendered -like '*Access=read-only*') 'substitutes {{ACCESS}}'
Assert-True ($rendered -like "*Repo=$repoRoot*") 'substitutes {{REPO_ROOT}}'
Assert-True ($rendered -like '*Artifact=N/A*') 'read-only access renders a not-applicable artifact placeholder'
Assert-True ($rendered -like '*please review this diff*') 'appends the task content'

Write-Host "Build-CcodexWorkerPrompt injects a real artifact dir for workspace access"
$artifactDir = Join-Path $tempRoot 'artifacts'
$rendered2 = Build-CcodexWorkerPrompt -TemplatePath $userTemplate -Mode 'test' -Access 'workspace' -RepoRoot $repoRoot -ArtifactDir $artifactDir -TaskContent 'run the browser test'
Assert-True ($rendered2 -like "*Artifact=$artifactDir*") 'substitutes the absolute artifact directory'

Write-Host "Build-CcodexWorkerPrompt throws when the template is missing"
Assert-Throws { Build-CcodexWorkerPrompt -TemplatePath (Join-Path $tempRoot 'missing.md') -Mode 'review' -Access 'read-only' -RepoRoot $repoRoot -ArtifactDir $null -TaskContent 'x' } 'throws on a missing template file'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
