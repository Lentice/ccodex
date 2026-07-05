# ccodex delegation policy

This rule teaches you how to apply the project's Codex delegation policy automatically, so the
user never has to re-prompt it. It applies whenever `ccodex` is installed and the current working
directory is inside a git repository.

## Read the policy

Before acting on either checkpoint below, read `<repo_root>/.ccodex/ccodex.json`'s `delegation`
section (repo root = the git root of the current project, or a submodule root when working
inside one):

```json
{
  "delegation": {
    "review_after_changes": "ask",
    "review_min_changed_lines": 50,
    "review_default_paths": [],
    "plan_second_opinion": "ask",
    "max_codex_calls_per_task": 2
  }
}
```

If the file or the `delegation` section is missing, use these defaults. Missing keys within a
present section fall back to their own defaults individually.

## Fixed checkpoints only

Do not auto-route work mid-task. Apply the policy at exactly these points:

1. **Post-change** — after you finish a feature/fix and before declaring the task done, consult
   `review_after_changes`.
2. **Post-plan** — after you write or update a plan or spec document, consult
   `plan_second_opinion`.
3. **Explicit user request** — always honored regardless of policy, and never counted against the
   auto/ask decision above (it is a direct instruction, not a checkpoint).

Never auto-delegate generative work (writing code, plans, or prose) itself — only
review/summary/second-opinion tasks are eligible for `auto`. Codex review is additive: keep
running your own tests and self-review regardless of what Codex reports.

## auto / ask / off semantics

- `auto` — run the scoped review at the checkpoint automatically, then triage every finding
  before acting on it (see Triage below), and fold the result into your final report.
- `ask` — offer the user a one-keystroke choice to run the review or skip it; do not run it
  without that choice.
- `off` — only run this checkpoint's review when the user explicitly asks for it in the moment.

## Cost guards (apply before running, regardless of auto/ask)

- **`review_min_changed_lines`** — before running a post-change review, estimate the changed line
  count for the scoped diff (e.g. `git diff --shortstat <base>..HEAD -- <paths>`). If it is under
  this threshold, skip the review (note the skip briefly; don't ask or run).
- **`max_codex_calls_per_task`** — track how many `ccodex` calls (review or otherwise) you have
  made for the current task. Once you hit this cap, do not make further calls for the rest of the
  task even if a checkpoint would otherwise trigger one; note that the cap was reached instead.

## Composing the review call

Scope the review to exactly the changes being evaluated:

```powershell
ccodex review --range <base>..HEAD --path <changed-path> --intent "<one-line change intent>" --embed-diff
```

- Default to `--embed-diff` — the wrapper runs `git diff` itself and embeds a size-capped diff in
  the prompt. This is the reliable form: on some hosts Codex's own sandbox cannot spawn
  processes, so asking Codex to run `git diff` itself fails (observed signature:
  `CreateProcessWithLogonW failed: 1385`). If you've confirmed this host's Codex sandbox can spawn
  processes, the lighter-weight no-flag (self-diff) form works too — Codex generates the diff
  itself instead of the wrapper embedding it.
- Use `--path` once per changed area (directory or file) instead of reviewing the whole repo.
- Use `review_default_paths` from the config as the default `--path` set when the caller hasn't
  narrowed it further.
- When the change lives in a submodule, target it directly instead of the superproject:

  ```powershell
  ccodex review --repo <submodule-path> --range <base>..HEAD --path <changed-path> --intent "<intent>" --embed-diff
  ```

- For a plan/spec second opinion, describe the plan's intent in `--intent`/`--focus` and scope
  `--path`/`--range` to the plan document(s) that changed.

## Triage every finding

Never adopt a Codex finding uncritically and never dismiss one without checking it. For each
finding: verify it against the actual code/diff, then explicitly adopt it (and act on it) or
reject it with a stated reason. Summarize adopted and rejected findings distinctly when reporting
back to the user — do not present Codex's raw output as your own conclusion.

## Failure reactions

React to `ccodex`'s exit code and `status.json.failure_reason` without reading logs, per the
README's failure-class table:

| Signal | Reaction |
| --- | --- |
| exit `10` + `failure_reason: quota_or_rate_limit` | Note the limit to the user and continue the task without the review; never retry-loop. |
| exit `10` + `failure_reason: auth` | Note that Codex auth needs attention (`codex login`) and continue without the review. |
| exit `10` + `failure_reason: permission_or_sandbox` | Note it; consider `--access workspace` or a narrower scope on a future attempt, but do not retry automatically now. |
| exit `10` + `failure_reason: network` | One retry is safe; if it fails again, note it and continue. |
| exit `10` with no `failure_reason` | Read `status.json.error`/stderr for context, then continue; use judgment, do not retry-loop. |
| exit `11` | Codex produced no usable result; note it and continue without the review. |
| exit `20` | The job is still running; re-run `wait` rather than treating it as failed. |
| exit `24` | The job hit its timeout; note it and continue — don't just retry unchanged. |
| exit `2`/`3`/`12`/`23` | Wrapper/usage/internal error; note it and continue without the review. |

In every failure case, the task itself is not blocked — a skipped or failed review is recorded as
a note in your final report, not a reason to stop.
