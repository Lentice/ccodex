# tests/Repo.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Repo.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-repo-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Write-Host "Resolve-CcodexRepo with --repo override"
$overrideDir = Join-Path $tempRoot 'override'
New-Item -ItemType Directory -Path $overrideDir -Force | Out-Null
$resolved = Resolve-CcodexRepo -RepoOverride $overrideDir
Assert-Equal $resolved (Resolve-Path -LiteralPath $overrideDir).Path 'returns the resolved absolute override path'

Assert-Throws { Resolve-CcodexRepo -RepoOverride (Join-Path $tempRoot 'does-not-exist') } 'throws when --repo does not exist'

Write-Host "Resolve-CcodexRepo via git rev-parse"
$gitRepo = Join-Path $tempRoot 'gitrepo'
New-Item -ItemType Directory -Path $gitRepo -Force | Out-Null
Push-Location $gitRepo
try {
    & git init --quiet | Out-Null
    $resolvedGit = Resolve-CcodexRepo -RepoOverride $null
    Assert-Equal $resolvedGit (Resolve-Path -LiteralPath $gitRepo).Path 'falls back to git rev-parse --show-toplevel'
} finally {
    Pop-Location
}

Write-Host "Resolve-CcodexRepo outside any git repo"
$nonGitDir = Join-Path $tempRoot 'nongit'
New-Item -ItemType Directory -Path $nonGitDir -Force | Out-Null
Push-Location $nonGitDir
try {
    Assert-Throws { Resolve-CcodexRepo -RepoOverride $null } 'throws when no git repository is found and no --repo given'
} finally {
    Pop-Location
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
