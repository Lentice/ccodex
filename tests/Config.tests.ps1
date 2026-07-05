# tests/Config.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\Config.ps1')

function New-CcodexTempRepo {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ccodex-config-test-" + [System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

Write-Host "defaults when .ccodex/ccodex.json is missing"
$repoRoot = New-CcodexTempRepo
try {
    $config = Get-CcodexProjectConfig -RepoRoot $repoRoot
    Assert-Equal $config.delegation.review_after_changes 'ask' 'defaults review_after_changes to ask'
    Assert-Equal $config.delegation.review_min_changed_lines 50 'defaults review_min_changed_lines to 50'
    Assert-Equal $config.delegation.review_default_paths.Count 0 'defaults review_default_paths to empty array'
    Assert-Equal $config.delegation.plan_second_opinion 'ask' 'defaults plan_second_opinion to ask'
    Assert-Equal $config.delegation.max_codex_calls_per_task 2 'defaults max_codex_calls_per_task to 2'
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "defaults when delegation section is missing"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value '{}' -NoNewline -Encoding utf8
    $config = Get-CcodexProjectConfig -RepoRoot $repoRoot
    Assert-Equal $config.delegation.review_after_changes 'ask' 'missing delegation section defaults review_after_changes'
    Assert-Equal $config.delegation.max_codex_calls_per_task 2 'missing delegation section defaults max_codex_calls_per_task'
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "full round-trip when every key is set"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    $json = @'
{
  "delegation": {
    "review_after_changes": "auto",
    "review_min_changed_lines": 10,
    "review_default_paths": ["lib/", "src/x/"],
    "plan_second_opinion": "off",
    "max_codex_calls_per_task": 5
  }
}
'@
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value $json -NoNewline -Encoding utf8
    $config = Get-CcodexProjectConfig -RepoRoot $repoRoot
    Assert-Equal $config.delegation.review_after_changes 'auto' 'round-trips review_after_changes'
    Assert-Equal $config.delegation.review_min_changed_lines 10 'round-trips review_min_changed_lines'
    Assert-Equal ($config.delegation.review_default_paths -join ',') 'lib/,src/x/' 'round-trips review_default_paths'
    Assert-Equal $config.delegation.plan_second_opinion 'off' 'round-trips plan_second_opinion'
    Assert-Equal $config.delegation.max_codex_calls_per_task 5 'round-trips max_codex_calls_per_task'
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "partial section falls back to per-key defaults"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    $json = @'
{
  "delegation": {
    "review_after_changes": "off"
  }
}
'@
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value $json -NoNewline -Encoding utf8
    $config = Get-CcodexProjectConfig -RepoRoot $repoRoot
    Assert-Equal $config.delegation.review_after_changes 'off' 'keeps the explicit value'
    Assert-Equal $config.delegation.review_min_changed_lines 50 'defaults the unset review_min_changed_lines'
    Assert-Equal $config.delegation.review_default_paths.Count 0 'defaults the unset review_default_paths'
    Assert-Equal $config.delegation.plan_second_opinion 'ask' 'defaults the unset plan_second_opinion'
    Assert-Equal $config.delegation.max_codex_calls_per_task 2 'defaults the unset max_codex_calls_per_task'
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "malformed JSON throws"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value '{ not valid json' -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexProjectConfig -RepoRoot $repoRoot } 'malformed JSON throws'
    try {
        Get-CcodexProjectConfig -RepoRoot $repoRoot
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid .ccodex/ccodex.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "invalid enum value throws"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    $json = @'
{
  "delegation": {
    "review_after_changes": "sometimes"
  }
}
'@
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexProjectConfig -RepoRoot $repoRoot } 'invalid enum value throws'
    try {
        Get-CcodexProjectConfig -RepoRoot $repoRoot
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid .ccodex/ccodex.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Write-Host "invalid plan_second_opinion enum value throws"
$repoRoot = New-CcodexTempRepo
try {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot '.ccodex') -Force | Out-Null
    $json = @'
{
  "delegation": {
    "plan_second_opinion": "sometimes"
  }
}
'@
    Set-Content -Path (Join-Path $repoRoot '.ccodex/ccodex.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexProjectConfig -RepoRoot $repoRoot } 'invalid plan_second_opinion enum value throws'
} finally {
    Remove-Item -Recurse -Force $repoRoot
}

Complete-CcodexTests
