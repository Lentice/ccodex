# lib/WorkerPrompt.ps1
function Get-CcodexWorkerPromptTemplatePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$AppDataRoot = $env:APPDATA
    )
    $projectTemplate = Join-Path $RepoRoot '.ccodex\worker-prompt.md'
    if (Test-Path -LiteralPath $projectTemplate -PathType Leaf) {
        return $projectTemplate
    }
    return Join-Path $AppDataRoot 'ccodex\templates\worker-prompt.md'
}

function Build-CcodexWorkerPrompt {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Access,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ArtifactDir,
        [Parameter(Mandatory)][string]$TaskContent
    )
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "ccodex: worker prompt template not found at '$TemplatePath'. Run install.ps1 or check .ccodex/worker-prompt.md."
    }
    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $artifactText = if ($ArtifactDir) { $ArtifactDir } else { 'N/A (read-only access; no file writes permitted)' }

    $contract = $template.Replace('{{ARTIFACT_DIR}}', $artifactText).Replace('{{MODE}}', $Mode).Replace('{{ACCESS}}', $Access).Replace('{{REPO_ROOT}}', $RepoRoot)

    return "$contract`n`n---`n`n$TaskContent"
}
