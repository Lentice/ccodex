# tests/UserConfig.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\UserConfig.ps1')

function New-CcodexTempAppData {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ccodex-userconfig-test-" + [System.Guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

Write-Host "defaults when config.json is missing"
$appData = New-CcodexTempAppData
try {
    $config = Get-CcodexUserConfig -AppDataRoot $appData
    Assert-Equal $config.retention.jobs_days 14 'defaults jobs_days to 14'
    Assert-Equal $config.retention.thread_ttl_days 30 'defaults thread_ttl_days to 30'
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "defaults when retention section is missing"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value '{}' -NoNewline -Encoding utf8
    $config = Get-CcodexUserConfig -AppDataRoot $appData
    Assert-Equal $config.retention.jobs_days 14 'missing retention section defaults jobs_days'
    Assert-Equal $config.retention.thread_ttl_days 30 'missing retention section defaults thread_ttl_days'
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "full round-trip when every key is set"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "jobs_days": 7,
    "thread_ttl_days": 60
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    $config = Get-CcodexUserConfig -AppDataRoot $appData
    Assert-Equal $config.retention.jobs_days 7 'round-trips jobs_days'
    Assert-Equal $config.retention.thread_ttl_days 60 'round-trips thread_ttl_days'
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "partial section falls back to per-key defaults"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "jobs_days": 3
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    $config = Get-CcodexUserConfig -AppDataRoot $appData
    Assert-Equal $config.retention.jobs_days 3 'keeps the explicit value'
    Assert-Equal $config.retention.thread_ttl_days 30 'defaults the unset thread_ttl_days'
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "malformed JSON throws"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value '{ not valid json' -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexUserConfig -AppDataRoot $appData } 'malformed JSON throws'
    try {
        Get-CcodexUserConfig -AppDataRoot $appData
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid config.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "non-numeric jobs_days throws the friendly contract message"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "jobs_days": "abc"
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexUserConfig -AppDataRoot $appData } 'non-numeric jobs_days throws'
    try {
        Get-CcodexUserConfig -AppDataRoot $appData
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid config.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "non-numeric thread_ttl_days throws the friendly contract message"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "thread_ttl_days": "nope"
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexUserConfig -AppDataRoot $appData } 'non-numeric thread_ttl_days throws'
    try {
        Get-CcodexUserConfig -AppDataRoot $appData
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid config.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "negative jobs_days throws"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "jobs_days": -1
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexUserConfig -AppDataRoot $appData } 'negative jobs_days throws'
    try {
        Get-CcodexUserConfig -AppDataRoot $appData
    } catch {
        Assert-True ($_.Exception.Message -like 'ccodex: invalid config.json:*') 'error message has the expected prefix'
    }
} finally {
    Remove-Item -Recurse -Force $appData
}

Write-Host "negative thread_ttl_days throws"
$appData = New-CcodexTempAppData
try {
    New-Item -ItemType Directory -Path (Join-Path $appData 'ccodex') -Force | Out-Null
    $json = @'
{
  "retention": {
    "thread_ttl_days": -5
  }
}
'@
    Set-Content -Path (Join-Path $appData 'ccodex/config.json') -Value $json -NoNewline -Encoding utf8
    Assert-Throws { Get-CcodexUserConfig -AppDataRoot $appData } 'negative thread_ttl_days throws'
} finally {
    Remove-Item -Recurse -Force $appData
}

Complete-CcodexTests
