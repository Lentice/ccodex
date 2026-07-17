# Canonical human-facing command metadata. Keep command discovery, top-level help, per-command
# help, and the dispatcher's unknown-command inventory sourced from this one ordered table.
$script:CcodexHelpCommands = [ordered]@{
    run = [ordered]@{
        Summary = 'Run one Codex task synchronously and print its final result.'
        Usage   = 'ccodex run --mode <review|brainstorm|test|implement> [options] [task]'
        Flags   = @(
            [ordered]@{ Flag = '--mode <mode>'; Desc = 'Required task mode.' }
            [ordered]@{ Flag = '--access <access>'; Desc = 'review/brainstorm: read-only (default); test: workspace or worktree (required); implement: worktree (default).' }
            [ordered]@{ Flag = '--prompt-file <path>'; Desc = 'Read task text from a UTF-8 file instead of stdin/position.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Target repository (defaults to the current repository).' }
            [ordered]@{ Flag = '--model <model>'; Desc = 'Use a specific Codex model for this call.' }
            [ordered]@{ Flag = '--effort <level>'; Desc = 'Set reasoning effort: none through ultra.' }
            [ordered]@{ Flag = '--hard-timeout-sec <n>'; Desc = 'Kill the Codex process tree after n seconds; 0 disables.' }
            [ordered]@{ Flag = '--group <g> / --label <l>'; Desc = 'Attach batch metadata to the job.' }
        )
        Example = '"Review this change." | ccodex run --mode review'
    }
    review = [ordered]@{
        Summary = 'Run a scoped, read-only Codex review of a git diff.'
        Usage   = 'ccodex review (--range <a..b> | --staged | --working) [options]'
        Flags   = @(
            [ordered]@{ Flag = '--range <a..b>'; Desc = 'Review a commit range.' }
            [ordered]@{ Flag = '--staged / --working'; Desc = 'Review the index or working-tree diff.' }
            [ordered]@{ Flag = '--path <path>'; Desc = 'Repeat to restrict the review to selected paths.' }
            [ordered]@{ Flag = '--intent <text> / --focus <text>'; Desc = 'Describe the change and an emphasis area.' }
            [ordered]@{ Flag = '--embed-diff'; Desc = 'Generate and embed the diff before invoking Codex.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Target repository (defaults to the current repository).' }
            [ordered]@{ Flag = '--model <model> / --effort <level>'; Desc = 'Optional Codex model and effort.' }
        )
        Example = 'ccodex review --working --path lib/ --intent "Harden argument parsing" --embed-diff'
    }
    resume = [ordered]@{
        Summary = 'Continue a finished job in the same Codex session as a new child job.'
        Usage   = 'ccodex resume <job_id> [--prompt-file <path>] [options]'
        Flags   = @(
            [ordered]@{ Flag = '--prompt-file <path>'; Desc = 'Read follow-up text from a UTF-8 file; stdin is also accepted.' }
            [ordered]@{ Flag = '--model <model> / --effort <level>'; Desc = 'Optional per-follow-up Codex model and effort.' }
            [ordered]@{ Flag = '--hard-timeout-sec <n>'; Desc = 'Bound the follow-up runtime in seconds.' }
        )
        Example = '"Check the alternative." | ccodex resume <job_id>'
    }
    submit = [ordered]@{
        Summary = 'Submit a Codex task or follow-up to a detached background worker.'
        Usage   = 'ccodex submit (--mode <mode> | --resume <job_id>) [options] [task]'
        Flags   = @(
            [ordered]@{ Flag = '--mode <mode>'; Desc = 'Required for a new job; accepts the run modes.' }
            [ordered]@{ Flag = '--resume <job_id>'; Desc = 'Continue a finished parent asynchronously.' }
            [ordered]@{ Flag = '--access <access>'; Desc = 'New jobs: review/brainstorm: read-only (default); test: workspace or worktree (required); implement: worktree (default). Inherited for --resume.' }
            [ordered]@{ Flag = '--prompt-file <path>'; Desc = 'Read task text from a UTF-8 file instead of stdin/position.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Target repository for a new job.' }
            [ordered]@{ Flag = '--model <model> / --effort <level>'; Desc = 'Optional Codex model and effort.' }
            [ordered]@{ Flag = '--hard-timeout-sec <n>'; Desc = 'Bound the worker runtime in seconds.' }
            [ordered]@{ Flag = '--group <g> / --label <l>'; Desc = 'Attach batch metadata to a new job.' }
        )
        Example = '"Run the tests." | ccodex submit --mode test --access workspace'
    }
    list = [ordered]@{
        Summary = 'List jobs newest first, optionally filtered across repositories.'
        Usage   = 'ccodex list [--json] [--repo <path>] [--state <state>] [--group <g>] [--label <l>]'
        Flags   = @(
            [ordered]@{ Flag = '--json'; Desc = 'Emit a schema-versioned JSON envelope.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Limit results to one repository.' }
            [ordered]@{ Flag = '--state <state>'; Desc = 'Repeat to include selected lifecycle states.' }
            [ordered]@{ Flag = '--group <g> / --label <l>'; Desc = 'Filter by exact batch metadata.' }
        )
        Example = 'ccodex list --state running --json'
    }
    status = [ordered]@{
        Summary = 'Show a job lifecycle state without waiting.'
        Usage   = 'ccodex status <job_id> [--json]'
        Flags   = @(
            [ordered]@{ Flag = '--json'; Desc = 'Emit a schema-versioned lifecycle envelope.' }
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex status <job_id> --json'
    }
    wait = [ordered]@{
        Summary = 'Wait for one job or a snapshot batch to reach terminal state.'
        Usage   = 'ccodex wait <job_id> [--json] [--wait-timeout-sec <n>] | ccodex wait --all [filters]'
        Flags   = @(
            [ordered]@{ Flag = '--all'; Desc = 'Wait for a snapshot of matching non-terminal jobs.' }
            [ordered]@{ Flag = '--group <g> / --label <l>'; Desc = 'Filter a --all batch by exact metadata.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Filter a --all batch to one repository.' }
            [ordered]@{ Flag = '--wait-timeout-sec <n>'; Desc = 'Stop waiting after n seconds without cancelling jobs.' }
            [ordered]@{ Flag = '--json'; Desc = 'Emit a schema-versioned result envelope.' }
        )
        Example = 'ccodex wait <job_id> --json --wait-timeout-sec 600'
    }
    read = [ordered]@{
        Summary = 'Read a job result without waiting.'
        Usage   = 'ccodex read <job_id> [--json]'
        Flags   = @(
            [ordered]@{ Flag = '--json'; Desc = 'Emit a schema-versioned result envelope.' }
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex read <job_id> --json'
    }
    cancel = [ordered]@{
        Summary = 'Stop a created or running background job.'
        Usage   = 'ccodex cancel <job_id>'
        Flags   = @(
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex cancel <job_id>'
    }
    diff = [ordered]@{
        Summary = 'Inspect the cumulative changes from a worktree job.'
        Usage   = 'ccodex diff <job_id> [--stat | --name-only]'
        Flags   = @(
            [ordered]@{ Flag = '--stat'; Desc = 'Print only the diffstat (size a diff before pulling the full patch).' }
            [ordered]@{ Flag = '--name-only'; Desc = 'Print only the changed file paths. Mutually exclusive with --stat.' }
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex diff <implement_job_id>'
    }
    apply = [ordered]@{
        Summary = 'Apply a done worktree job to its main repository.'
        Usage   = 'ccodex apply <job_id> [--allow-untracked] [--message <msg>] [--reset-author]'
        Flags   = @(
            [ordered]@{ Flag = '--allow-untracked'; Desc = 'Allow non-overlapping untracked files; tracked dirt still blocks.' }
            [ordered]@{ Flag = '--message <msg>'; Desc = 'Set the landed commit message (single-commit apply only).' }
            [ordered]@{ Flag = '--reset-author'; Desc = 'Reauthor the landed commit to your git identity (single-commit apply only).' }
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex apply <implement_job_id> --reset-author'
    }
    tail = [ordered]@{
        Summary = 'Print the tail of a job stderr and Codex event logs.'
        Usage   = 'ccodex tail <job_id> [--lines <n>]'
        Flags   = @(
            [ordered]@{ Flag = '--lines <n>'; Desc = 'Number of lines per log; defaults to 40.' }
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex tail <job_id> --lines 80'
    }
    cleanup = [ordered]@{
        Summary = 'Delete aged terminal jobs and optionally scrub stale session ids.'
        Usage   = 'ccodex cleanup [--dry-run] [--older-than <Nd|Nh>] [options]'
        Flags   = @(
            [ordered]@{ Flag = '--dry-run'; Desc = 'Preview candidates without changing state.' }
            [ordered]@{ Flag = '--older-than <Nd|Nh>'; Desc = 'Override the job retention threshold.' }
            [ordered]@{ Flag = '--include-stalled'; Desc = 'Reconcile stalled jobs before sweeping.' }
            [ordered]@{ Flag = '--scrub-thread-ids'; Desc = 'Blank expired Codex thread ids on retained jobs.' }
            [ordered]@{ Flag = '--thread-ttl <Nd>'; Desc = 'Override the thread-id retention threshold.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Limit job deletion to one repository.' }
        )
        Example = 'ccodex cleanup --dry-run --older-than 14d'
    }
    doctor = [ordered]@{
        Summary = 'Diagnose Codex, wrapper, state-root, and optional smoke-test health.'
        Usage   = 'ccodex doctor [--json] [--no-smoke] [--repo <path>]'
        Flags   = @(
            [ordered]@{ Flag = '--json'; Desc = 'Emit a schema-versioned diagnostic envelope.' }
            [ordered]@{ Flag = '--no-smoke'; Desc = 'Skip the live Codex smoke test.' }
            [ordered]@{ Flag = '--repo <path>'; Desc = 'Use a specific repository for checks.' }
        )
        Example = 'ccodex doctor --json --no-smoke'
    }
    debug = [ordered]@{
        Summary = 'Print a compact diagnostic report for one job.'
        Usage   = 'ccodex debug <job_id>'
        Flags   = @(
            [ordered]@{ Flag = '--state-root <path>'; Desc = 'Override the state root (test/support use).' }
        )
        Example = 'ccodex debug <job_id>'
    }
}

function Get-CcodexCommandNames {
    return @($script:CcodexHelpCommands.Keys)
}

function Get-CcodexTopLevelHelpText {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('ccodex delegates tasks to Codex and manages their job artifacts.')
    $lines.Add('')
    $lines.Add('Usage: ccodex <command> [options]')
    $lines.Add('')
    $lines.Add('Commands:')
    foreach ($name in (Get-CcodexCommandNames | Where-Object { $_ -ne 'debug' })) {
        $lines.Add(('  {0,-9} {1}' -f $name, $script:CcodexHelpCommands[$name].Summary))
    }
    $lines.Add('')
    $lines.Add(('Diagnostic: debug <job_id> - {0}' -f $script:CcodexHelpCommands.debug.Summary))
    $lines.Add('')
    $lines.Add('Common flags (availability depends on the command):')
    $lines.Add('  --json                  Emit machine-readable JSON.')
    $lines.Add('  --repo <path>           Target or filter by repository.')
    $lines.Add('  --model <model>         Select a Codex model for this call.')
    $lines.Add('  --effort <level>        Select reasoning effort (none through ultra).')
    $lines.Add('  --state-root <path>     Override the job-state root (test/support use).')
    $lines.Add('  --group <g>             Attach or filter exact batch-group metadata.')
    $lines.Add('  --label <l>             Attach or filter exact job-label metadata.')
    $lines.Add('  --hard-timeout-sec <n>  Bound Codex runtime; 0 disables the bound.')
    $lines.Add('')
    $lines.Add('Run ccodex <command> --help for command-specific usage.')
    return ($lines -join [Environment]::NewLine)
}

function Get-CcodexCommandHelpText {
    param([Parameter(Mandatory)][string]$Command)

    if (-not $script:CcodexHelpCommands.Contains($Command)) { return $null }
    $entry = $script:CcodexHelpCommands[$Command]
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Usage: $($entry.Usage)")
    $lines.Add('')
    $lines.Add($entry.Summary)
    if (@($entry.Flags).Count -gt 0) {
        $lines.Add('')
        $lines.Add('Flags:')
        foreach ($flag in $entry.Flags) {
            $lines.Add(('  {0,-30} {1}' -f $flag.Flag, $flag.Desc))
        }
    }
    $lines.Add('')
    $lines.Add("Example: $($entry.Example)")
    return ($lines -join [Environment]::NewLine)
}

function Get-CcodexUnknownCommandText {
    param([AllowEmptyString()][string]$Command)

    $supported = (Get-CcodexCommandNames) -join ', '
    return "ccodex: command '$Command' is not implemented. Supported commands: $supported."
}
