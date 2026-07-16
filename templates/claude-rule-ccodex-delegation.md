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

## Follow-up instead of starting over

If Codex's answer to a `ccodex review`/`run` call is a clarifying question, or a finding needs
pushback or refinement, continue the *same* Codex session instead of starting a fresh call that
has no memory of the prior turn:

```powershell
"<reply, or your pushback>" | ccodex resume <job_id>
```

`resume` always creates a brand-new job — it never mutates the job you're resuming from — and
inherits that job's mode/access/repo. If it exits `2` naming a scrubbed/absent thread id or
worktree access, or fails with `failure_reason: thread_expired`, the session is gone; start a
fresh `run`/`review` instead of retrying `resume`. This does not count as a separate checkpoint —
it is a continuation of whichever checkpoint (or explicit request) started the original call, and
still counts toward `max_codex_calls_per_task`.

## Triage every finding

Never adopt a Codex finding uncritically and never dismiss one without checking it. For each
finding: verify it against the actual code/diff, then explicitly adopt it (and act on it) or
reject it with a stated reason. Summarize adopted and rejected findings distinctly when reporting
back to the user — do not present Codex's raw output as your own conclusion.

## Failure reactions

When checking a background job, call `ccodex status <job_id> --json`, `ccodex wait <job_id>
--json`, or `ccodex read <job_id> --json`. Parse the top-level `schema_version: 1` lifecycle
envelope instead of scraping human output. Its `command_exit_code` matches the process exit and
is separate from the job's recorded `wrapper_exit_code`; fields remain present with `null` when
unavailable, and `wait`/`read` return content in `result`. A missing job id is still a human usage
error (exit `2`).

React to the JSON `command_exit_code` and `status.json.failure_reason` without reading logs, per
the README's failure-class table:

| Signal | Reaction |
| --- | --- |
| exit `10` + `failure_reason: quota_or_rate_limit` | Note the limit to the user and continue the task without the review; never retry-loop. |
| exit `10` + `failure_reason: auth` | Note that Codex auth needs attention (`codex login`) and continue without the review. |
| exit `10` + `failure_reason: permission_or_sandbox` | Note it; consider `--access workspace` or a narrower scope on a future attempt, but do not retry automatically now. |
| exit `10` + `failure_reason: network` | One retry is safe; if it fails again, note it and continue. |
| exit `10` with no `failure_reason` | Read `status.json.error`/stderr for context, then continue; use judgment, do not retry-loop. |
| exit `10` + `failure_reason: thread_expired` (`resume` only) | Codex no longer recognizes the resumed session; start a fresh `run`/`review` instead of retrying `resume`. |
| exit `2`/`3`/`4` on `resume` | Parent is a worktree job or has an absent/scrubbed thread id (`2`), doesn't exist (`3`), or hasn't finished yet (`4`); start a fresh call or wait, as appropriate. |
| exit `11` | Codex produced no usable result; note it and continue without the review. |
| exit `20` | The job is still running; re-run `wait` rather than treating it as failed. |
| exit `21` | The per-job lock could not be acquired within its timeout; retry the command once. |
| exit `22` | The job was cancelled (`ccodex cancel`); treat it as intentionally stopped, not a failure. |
| exit `24` | The job hit its timeout; note it and continue — don't just retry unchanged. |
| exit `25` | `ccodex apply` conflicted or failed; the main repo was left untouched — review `ccodex diff <job_id>`, resolve by hand, report to the user; never retry `apply` unchanged. |
| exit `2`/`3`/`12`/`23` | Wrapper/usage/internal error; note it and continue without the review. |

In every failure case, the task itself is not blocked — a skipped or failed review is recorded as
a note in your final report, not a reason to stop.

**Environment-shaped failures first move:** when a failure looks environment-shaped rather than
task-specific — `auth`, `quota_or_rate_limit`, `permission_or_sandbox`, or the
`CreateProcessWithLogonW failed: 1385` signature — run `ccodex doctor` before retrying or trying a
workaround. It isolates whether Codex itself, the wrapper, or the state root is the actual
problem, so you react to the real cause instead of guessing.

## Delegated implementation: review the diff before applying

If a checkpoint or an explicit user request delegates an actual code edit (not just a review) to
Codex, use `ccodex run --mode implement` (or `submit --mode implement`) — it executes inside an
isolated, detached git worktree under the state root, so the working tree you're already in is
never touched by the job itself. Then, always in this order:

```powershell
ccodex diff <job_id>     # review every change yourself — treat it like a PR you're about to merge
ccodex apply <job_id>    # only once you've reviewed it and decided to land it
```

**Never auto-apply.** `apply` is the one command in this policy that must never be run
automatically at a checkpoint or unattended — always inspect `ccodex diff <job_id>` first and make
an explicit adopt/reject decision, exactly as with a review finding. `apply` requires a clean main
repo working tree and only accepts a `done` job; on conflict it exits `25` and leaves the main
repo untouched — report the conflict and let the user decide how to resolve it rather than
retrying blindly.

## Job lifecycle hygiene

- **Stopping a background job:** if a `submit`ted job is known to be the wrong task, stuck, or no
  longer needed, run `ccodex cancel <job_id>` rather than leaving it to run to a timeout or
  ignoring it.
- **Periodic hygiene:** run `ccodex cleanup --dry-run` occasionally (or whenever the user asks to
  reclaim disk or clear stale session data), then `ccodex cleanup --older-than <Nd|Nh>` to
  actually delete aged terminal jobs; add `--scrub-thread-ids` to also blank old jobs'
  `codex_thread_id` so they stop being resumable. This is housekeeping, not a checkpoint — it does
  not require `auto`/`ask`/`off` policy and is not counted against `max_codex_calls_per_task`.
