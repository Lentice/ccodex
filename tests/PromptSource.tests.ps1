# tests/PromptSource.tests.ps1
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\lib\PromptSource.ps1')

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ccodex-promptsource-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CcodexTestParams {
    param([hashtable]$Overrides = @{})
    $base = @{
        ExpectingPipelineInput = $false
        PipelineObjects        = $null
        PromptFile             = $null
        PositionalTask         = $null
        StdinStream            = $null
        StdinIsRedirected      = $false
    }
    foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
    return $base
}

Write-Host "positional task text"
$p = New-CcodexTestParams -Overrides @{ PositionalTask = 'do the thing' }
Assert-Equal (Get-CcodexPromptContent @p) 'do the thing' 'returns positional task text verbatim'

Write-Host "--prompt-file"
$promptFile = Join-Path $tempRoot 'prompt.txt'
[System.IO.File]::WriteAllText($promptFile, "line one`r`nline two", (New-Object System.Text.UTF8Encoding($false)))
$p = New-CcodexTestParams -Overrides @{ PromptFile = $promptFile }
Assert-True ((Get-CcodexPromptContent @p) -like '*line one*line two*') 'reads --prompt-file content'

Write-Host "missing --prompt-file"
$p = New-CcodexTestParams -Overrides @{ PromptFile = (Join-Path $tempRoot 'missing.txt') }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when --prompt-file does not exist'

Write-Host "both --prompt-file and positional task"
$p = New-CcodexTestParams -Overrides @{ PromptFile = $promptFile; PositionalTask = 'x' }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when both explicit sources are given'

Write-Host "PowerShell pipeline input"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('multi', 'line') }
Assert-Equal (Get-CcodexPromptContent @p) "multi$([Environment]::NewLine)line" 'joins pipeline objects with Environment.NewLine'

Write-Host "empty PowerShell pipeline input"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @() }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when pipeline input is empty'

Write-Host "whitespace-only pipeline input is preserved, not rejected"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('   ') }
Assert-Equal (Get-CcodexPromptContent @p) '   ' 'whitespace pipeline content counts as non-empty'

Write-Host "pipeline input plus an explicit source conflicts"
$p = New-CcodexTestParams -Overrides @{ ExpectingPipelineInput = $true; PipelineObjects = @('x'); PositionalTask = 'y' }
Assert-Throws { Get-CcodexPromptContent @p } 'throws when pipeline and positional task are both present'

Write-Host "explicit source present must not touch stdin stream"
$blockingStream = [System.IO.Stream]::Null  # any non-null marker; function must never call .Read on it in this branch
$p = New-CcodexTestParams -Overrides @{ PositionalTask = 'z'; StdinIsRedirected = $true; StdinStream = $blockingStream }
Assert-Equal (Get-CcodexPromptContent @p) 'z' 'positional task short-circuits before any stdin probing'

Write-Host "no source at all"
$p = New-CcodexTestParams
Assert-Throws { Get-CcodexPromptContent @p } 'throws when nothing is provided and stdin is not redirected'

Remove-Item -LiteralPath $tempRoot -Recurse -Force
Complete-CcodexTests
