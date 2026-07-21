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

    # The default (self-diff) prompt asks Codex to RUN `git diff <range> -- <paths>` verbatim, so
    # any shell metacharacter in a caller-supplied range/path would be reconstructed into an
    # executable command line — a command-injection vector even though the review sandbox is
    # read-only. A legitimate git ref or pathspec never needs these characters, so reject them
    # here (this also keeps the embed form's "produced by" line honest).
    $shellMeta = '[;&|`$(){}<>\n\r''"]'
    if ($Range -and $Range -match $shellMeta) {
        throw "ccodex: --range contains an unsupported shell metacharacter: '$Range'."
    }
    if ($Paths) {
        foreach ($p in $Paths) {
            if ($p -match $shellMeta) {
                throw "ccodex: --path contains an unsupported shell metacharacter: '$p'."
            }
        }
    }

    # Git selector tokens shared by the display string and the embed invocation.
    $selectorArgs = @()
    if ($Range) { $selectorArgs = @($Range) }
    elseif ($Staged) { $selectorArgs = @('--staged') }
    # Working tree: no selector token.

    $pathArgs = @()
    if ($Paths -and $Paths.Count -gt 0) { $pathArgs = @('--') + $Paths }

    # Human-readable command line embedded in the prompt (self-diff instruction AND the
    # embed form's "produced by" line, both below). Any path containing whitespace is
    # wrapped in double quotes so the rendered line reads unambiguously; $pathArgs itself
    # (used for the real `git diff` invocation in the embed form further down) is passed
    # as separate array elements straight to the process and is left unquoted there.
    $displayPathArgs = @()
    if ($Paths -and $Paths.Count -gt 0) {
        $displayPaths = $Paths | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $displayPathArgs = @('--') + $displayPaths
    }
    $diffCommand = (@('git', 'diff') + $selectorArgs + $displayPathArgs) -join ' '

    $metaLines = @()
    if ($Intent) { $metaLines += "Change intent: $Intent" }
    if ($Focus) { $metaLines += "Additional focus: $Focus" }
    $metaBlock = if ($metaLines.Count -gt 0) { ($metaLines -join "`n") + "`n`n" } else { '' }

    # The appendix instruction below is part of this SHARED block so the self-diff and embed-diff
    # return forms cannot diverge (amendment #9): both append $instructions verbatim. The prose
    # review stays first; the machine-readable block is an appendix AFTER the one-line verdict
    # (amendment #2). The marker line + json fence + schema keys mirror exactly what
    # lib/ReviewFindings.ps1's parser reads (backlog #19); keep the two in lockstep.
    $instructions = @'
Review instructions:
- Judge the change on its own merits. Any stated change intent or focus above describes the
  scope and expected behavior; treat it as context, not evidence that the code is correct.
  Do not treat it as a conclusion to endorse — verify the code independently and report
  problems even when the intent implies the change is already fine.
- Lead with severity-ordered findings: Critical first, then Important, then Minor. For
  each finding give the file:line location and a concrete suggested fix.
- Explicitly hunt for omissions and edge cases the author may have missed (error
  handling, boundary values, concurrency, resource cleanup, missing tests).
- Be specific and terse; do not restate the diff.
- End the prose review with a single one-line verdict.

After the prose review, append EXACTLY ONE machine-readable findings block: a line
containing the marker `<!-- ccodex:findings -->` followed immediately by a ```json fenced
block with this shape (this appendix is last; the prose review above comes first):

<!-- ccodex:findings -->
```json
{
  "verdict": "one-line overall verdict (mirror the prose verdict)",
  "items": [
    {
      "severity": "critical | important | minor",
      "file": "repo-relative path or null",
      "line": 42,
      "claim": "one-sentence statement of the issue",
      "evidence": "why this is real, referencing the diff/code",
      "suggested_fix": "concrete change"
    }
  ]
}
```

Rules for the block: `severity` and `claim` are required per item; `file`, `line`,
`evidence`, and `suggested_fix` may be null. `severity` must be one of critical, important,
or minor. Emit an empty `items` array if there are no findings. Emit the block exactly once,
as the very last thing in your output.
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

    # Embed form: the wrapper runs the diff itself from the repo root and embeds it. Check git's
    # exit code (merging stderr into the captured text via 2>&1): a bad range/pathspec — e.g. a
    # nonexistent ref that still passed the <a>..<b> shape check above — must surface as a usage
    # error, not get embedded as an empty diff that Codex then "reviews" as if nothing changed.
    $diffOut = (& git -C $RepoRoot diff @selectorArgs @pathArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git diff failed for the review selection (exit $LASTEXITCODE): $($diffOut.Trim())"
    }
    $statOut = (& git -C $RepoRoot diff --stat @selectorArgs @pathArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "ccodex: git diff --stat failed for the review selection (exit $LASTEXITCODE): $($statOut.Trim())"
    }
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

Note: the embedded diff is capped at 100 KB total (the whole diff above, not per file); if
the cap is exceeded, the diff is truncated at that point with a single marker.

$metaBlock$instructions
"@
}
