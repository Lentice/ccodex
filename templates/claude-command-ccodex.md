---
description: Delegate a task to Codex CLI (via ccodex) for a second opinion, review, brainstorm, test run, worktree-isolated implementation, or long/parallel background work.
---

Use the installed `ccodex` CLI to delegate work to Codex as an external subagent. `$ARGUMENTS` is
the task text when the user supplies it inline; otherwise use the task described in the
conversation.

1. **Summarize the task clearly.** Write a short, self-contained task description — Codex has no
   access to this conversation, only what you send it.

2. **For a synchronous second opinion or review** (the common case — task is short-lived), run
   from the project directory:

   ```powershell
   "<task text>" | ccodex run --mode review
   "<task text>" | ccodex run --mode brainstorm
   ```

   Add `--repo <path>` when acting on behalf of a different repository than the current directory:

   ```powershell
   "<task text>" | ccodex run --mode review --repo <path>
   ```

3. **For a scoped code review**, prefer `ccodex review` over hand-writing a review prompt.

   Default to `--embed-diff`: the wrapper runs `git diff` itself and embeds a size-capped diff in
   the prompt. Use this by default — on some hosts Codex's own sandbox cannot spawn processes, so
   asking Codex to run `git diff` itself fails (observed signature: `CreateProcessWithLogonW
   failed: 1385`).

   ```powershell
   ccodex review --range <base>..<head> --path <p> --intent "<one-line change intent>" --embed-diff
   ccodex review --staged --path <p> --intent "<intent>" --embed-diff
   ccodex review --working --path <p> --intent "<intent>" --embed-diff
   ```

   Target a submodule directly with `--repo` instead of the superproject:

   ```powershell
   ccodex review --repo <submodule-path> --range <base>..<head> --path <p> --intent "<intent>" --embed-diff
   ```

   If you've confirmed Codex can spawn processes in its sandbox on this host, the lighter-weight
   no-flag (self-diff) form works too — it has Codex generate the diff itself (inside its
   read-only sandbox) instead of the wrapper embedding it:

   ```powershell
   ccodex review --range <base>..<head> --path <p> --intent "<one-line change intent>"
   ```

   `--path` is repeatable; add `--focus "<extra focus>"` for a specific angle. See
   `~/.claude/rules/ccodex-delegation.md` for when to run this automatically.

4. **For a delegated implementation** (the user or the task explicitly wants Codex to make an
   edit, not just advise on one), use `--mode implement`. It runs inside an isolated, detached git
   worktree under the state root — your own working tree is never touched by the job itself:

   ```powershell
   "<implementation task text>" | ccodex run --mode implement --repo <path>
   ```

   Then **always** inspect before integrating — never auto-apply:

   ```powershell
   ccodex diff <job_id>     # review every change yourself before deciding anything
   ccodex apply <job_id>    # only after you've reviewed the diff and want it landed
   ```

   `apply` requires a clean main-repo working tree and only applies a `done` job; on conflict it
   exits `25` and leaves the main repo untouched — report the conflict to the user rather than
   retrying blindly. Treat the diff exactly like a human PR you're about to merge: read it, decide,
   then act.

5. **For long-running or parallelizable work** (e.g. a test pass, or several independent reviews
   at once), submit it in the background instead of blocking on `run`:

   ```powershell
   "<task text>" | ccodex submit --mode test --access workspace
   ```

   This prints a job id and job directory to stdout and returns immediately. Later, block for the
   result or poll for it:

   ```powershell
   ccodex wait <job_id>       # blocks until the job finishes, then prints the result
   ccodex status <job_id>     # non-blocking lifecycle check
   ccodex read <job_id>       # non-blocking result read (fails if not finished yet)
   ```

   Submit multiple jobs before waiting on any of them to run them in parallel.

6. **Read stdout as the worker's final answer** — nothing else. Do not parse prose from stderr to
   decide success or failure; use the exit code:

   | Exit code | Meaning |
   | --- | --- |
   | `0`  | Success — stdout is the final result. |
   | `2`  | Usage/validation error (bad flags, missing task, repo resolution failure). |
   | `3`  | Job id not found (`status`/`wait`/`read`/`cancel`/`diff`/`apply`/`tail`/`debug`). |
   | `4`  | Job exists but is not finished yet (`read`/`diff`/`apply`) — use `wait` or check back later. |
   | `10` | Codex itself exited non-zero. |
   | `11` | Codex exited zero but produced no usable result. |
   | `12` | Wrapper-internal error. |
   | `20` | `wait` timed out; the job is still running — re-run `wait` to keep waiting. |
   | `21` | The per-job lock could not be acquired within its timeout — retry the command. |
   | `22` | `wait` returned because the job was cancelled (`ccodex cancel`). |
   | `23` | The background worker failed to start. |
   | `24` | The job hit `--hard-timeout-sec` and was killed. |
   | `25` | `ccodex apply` conflicted or failed; the main repo was left untouched — review `ccodex diff <job_id>` and resolve by hand. |

7. **React to failure classes without reading logs.** On exit `10`, check `status.json`'s
   `failure_reason` (a best-effort hint, not a guarantee — exit codes remain authoritative) and
   react accordingly:

   | Signal | Reaction |
   | --- | --- |
   | `10` + `failure_reason: quota_or_rate_limit` | Report the limit to the user; do not auto-retry. |
   | `10` + `failure_reason: auth` | Suggest the user run `codex login`. |
   | `10` + `failure_reason: network` | Safe to retry once. |
   | `10` + `failure_reason` absent | Read `error` in `status.json` / stderr; use judgment. |
   | `24` (`timed_out`) | Raise `--hard-timeout-sec` or split the task into smaller pieces; don't just retry unchanged. |
   | `20` | The job is still running — re-run `wait` rather than treating it as failed. |
   | `23` | Backend/environment issue — inspect the job directory (`status.json`, `stderr.log`) before retrying. |

   When the failure looks environment-shaped rather than task-specific (auth, quota, sandbox
   denial, or the `CreateProcessWithLogonW failed: 1385` signature), run `ccodex doctor` FIRST —
   it isolates whether Codex/the wrapper/the state root itself is broken before you touch the
   task again.

   For long-running work, pass `--hard-timeout-sec <n>` on `run`/`submit` to bound how long Codex
   may run before the wrapper kills it:

   ```powershell
   "<task text>" | ccodex run --mode test --access workspace --hard-timeout-sec 120
   ```

8. **Manage background jobs** with `cancel`/`tail`/`debug`/`cleanup`:

   ```powershell
   ccodex cancel <job_id>            # a submitted job needs to be stopped now, not waited out
   ccodex tail <job_id> --lines 80   # raw stderr.log / codex-events.jsonl tail for a stuck job
   ccodex debug <job_id>             # compact one-shot diagnosis + suggested next command
   ccodex cleanup --dry-run          # periodic hygiene: preview the retention sweep first
   ccodex cleanup --older-than 14d   # then actually delete aged terminal jobs
   ```

   Reach for `cancel` the moment a background job is known to be the wrong task or stuck — don't
   just let it run to a timeout. Reach for `cleanup --older-than <Nd|Nh>` periodically (or when
   the user asks to reclaim disk / clear stale sessions), ideally after a `--dry-run` preview; add
   `--scrub-thread-ids` to also blank old jobs' `codex_thread_id` so they stop being resumable.

9. **Merge Codex's findings into your own judgment.** Treat the result as input from a capable
   subagent, not as ground truth — you remain the final decision-maker on what to do with it.
   The same applies to a delegated implementation: `ccodex apply` lands exactly what the diff
   showed, nothing more — you decide whether it's landed, not Codex.
