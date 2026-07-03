function Resolve-CcodexRepo {
    param([string]$RepoOverride)

    if ($RepoOverride) {
        if (-not (Test-Path -LiteralPath $RepoOverride -PathType Container)) {
            throw "ccodex: --repo '$RepoOverride' does not exist or is not a directory."
        }
        return (Resolve-Path -LiteralPath $RepoOverride).Path
    }

    $gitOutput = & git rev-parse --show-toplevel 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: no git repository found in the current directory. Pass --repo <path> or run from inside a git repository."
    }
    $gitPath = ($gitOutput | Select-Object -First 1).ToString().Trim()
    $nativePath = $gitPath -replace '/', '\'
    return (Resolve-Path -LiteralPath $nativePath).Path
}
