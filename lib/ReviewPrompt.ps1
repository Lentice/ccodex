# lib/ReviewPrompt.ps1
#
# Composes the task text for `ccodex review` (a scoped code review over a git diff
# range). Two forms:
#   * Default "self-diff": instruct Codex to run the exact `git diff` command itself
#     inside its read-only sandbox, then review the result. Tiny prompt, exact scoping,
#     Codex can open surrounding files for context.
#   * `--embed-diff` fallback: the wrapper runs the same `git diff` from $RepoRoot and
#     embeds the (size-capped) output plus a `git diff --stat` summary, for unusual git
#     states where having Codex regenerate the diff is unreliable.
# The composed string is fed to the existing `run` pipeline as the task content; this
# module owns no job state and never invokes Codex.

function Build-CcodexReviewPrompt {
    param(
        [string]$Range,
        [bool]$Staged,
        [bool]$Working,
        [string[]]$Paths,
        [string]$Intent,
        [string]$Focus,
        [bool]$EmbedDiff,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    # Exactly one range selector must be chosen.
    $selectorCount = 0
    if ($Range) { $selectorCount++ }
    if ($Staged) { $selectorCount++ }
    if ($Working) { $selectorCount++ }
    if ($selectorCount -ne 1) {
        throw "ccodex: review requires exactly one of --range <a>..<b>, --staged, or --working."
    }
    if ($Range -and $Range -notmatch '^[^\s]+\.\.[^\s]+$') {
        throw "ccodex: --range must be of the form <base>..<head> (e.g. abc123..HEAD); got '$Range'."
    }

    # Git selector tokens shared by the display string and the embed invocation.
    $selectorArgs = @()
    if ($Range) { $selectorArgs = @($Range) }
    elseif ($Staged) { $selectorArgs = @('--staged') }
    # Working tree: no selector token.

    $pathArgs = @()
    if ($Paths -and $Paths.Count -gt 0) { $pathArgs = @('--') + $Paths }

    # Human-readable command line embedded in the prompt (and asserted by tests).
    $diffCommand = (@('git', 'diff') + $selectorArgs + $pathArgs) -join ' '

    $metaLines = @()
    if ($Intent) { $metaLines += "Change intent: $Intent" }
    if ($Focus) { $metaLines += "Additional focus: $Focus" }
    $metaBlock = if ($metaLines.Count -gt 0) { ($metaLines -join "`n") + "`n`n" } else { '' }

    $instructions = @'
Review instructions:
- Lead with severity-ordered findings: Critical first, then Important, then Minor. For
  each finding give the file:line location and a concrete suggested fix.
- Explicitly hunt for omissions and edge cases the author may have missed (error
  handling, boundary values, concurrency, resource cleanup, missing tests).
- Be specific and terse; do not restate the diff.
- End with a single one-line verdict.
'@

    if (-not $EmbedDiff) {
        return @"
You are performing a scoped code review of the repository at $RepoRoot.

Run exactly this command inside the repository to obtain the change under review, then
review the resulting diff:

    $diffCommand

$metaBlock$instructions
"@
    }

    # Embed form: the wrapper runs the diff itself from the repo root and embeds it.
    $diffOut = (& git -C $RepoRoot diff @selectorArgs @pathArgs 2>$null | Out-String)
    $statOut = (& git -C $RepoRoot diff --stat @selectorArgs @pathArgs 2>$null | Out-String)
    if ($null -eq $diffOut) { $diffOut = '' }
    if ($null -eq $statOut) { $statOut = '' }

    $capBytes = 100 * 1024
    if ($diffOut.Length -gt $capBytes) {
        $diffOut = $diffOut.Substring(0, $capBytes) + "`n... [truncated: diff exceeded the 100 KB embed cap] ...`n"
    }

    return @"
You are performing a scoped code review of the repository at $RepoRoot.

The change under review was produced by: $diffCommand

Summary (git diff --stat):

$statOut

Diff:

$diffOut

Note: the embedded diff is capped at 100 KB; any file whose diff exceeds the cap is
truncated with a per-file marker.

$metaBlock$instructions
"@
}
