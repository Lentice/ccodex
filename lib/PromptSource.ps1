# lib/PromptSource.ps1
function Get-CcodexPromptContent {
    param(
        [bool]$ExpectingPipelineInput,
        [object[]]$PipelineObjects,
        [string]$PromptFile,
        [string]$PositionalTask,
        [System.IO.Stream]$StdinStream,
        [bool]$StdinIsRedirected,
        [int]$StdinFirstByteTimeoutMs = 2000,
        [int]$StdinNoProgressTimeoutMs = 5000
    )

    $explicitSources = @()
    if ($PromptFile) { $explicitSources += 'PromptFile' }
    if ($PositionalTask) { $explicitSources += 'PositionalTask' }

    if ($explicitSources.Count -gt 1) {
        throw "ccodex: multiple prompt sources given ($($explicitSources -join ', ')). Provide exactly one of --prompt-file, positional task text, or stdin."
    }

    if ($explicitSources.Count -eq 1 -and $ExpectingPipelineInput) {
        throw "ccodex: prompt source conflict. PowerShell pipeline input was received in addition to $($explicitSources[0])."
    }

    if ($explicitSources -contains 'PromptFile') {
        if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
            throw "ccodex: --prompt-file '$PromptFile' was not found."
        }
        return Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
    }

    if ($explicitSources -contains 'PositionalTask') {
        return $PositionalTask
    }

    if ($ExpectingPipelineInput) {
        $items = @($PipelineObjects)
        $strings = $items | ForEach-Object { [string]$_ }
        $joined = $strings -join [Environment]::NewLine
        if ($joined.Length -eq 0) {
            throw "ccodex: PowerShell pipeline input was empty. Provide task text via the pipeline, --prompt-file, or positional task text."
        }
        return $joined
    }

    if ($StdinIsRedirected) {
        $content = Read-CcodexStdinWithTimeout -Stream $StdinStream -FirstByteTimeoutMs $StdinFirstByteTimeoutMs -NoProgressTimeoutMs $StdinNoProgressTimeoutMs
        if ($content.Length -eq 0) {
            throw "ccodex: redirected stdin produced no data. Provide task text via --prompt-file or positional task text."
        }
        return $content
    }

    throw "ccodex: no prompt source found. Pipe task text, use --prompt-file <path>, or pass positional task text."
}
