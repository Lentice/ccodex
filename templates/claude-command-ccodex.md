---
description: Delegate a task to Codex CLI (via ccodex) for a second opinion, review, brainstorm, test run, or long/parallel background work.
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

3. **For long-running or parallelizable work** (e.g. a test pass, or several independent reviews
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

4. **Read stdout as the worker's final answer** — nothing else. Do not parse prose from stderr to
   decide success or failure; use the exit code:

   | Exit code | Meaning |
   | --- | --- |
   | `0`  | Success — stdout is the final result. |
   | `2`  | Usage/validation error (bad flags, missing task, repo resolution failure). |
   | `3`  | Job id not found (`status`/`wait`/`read`). |
   | `4`  | Job exists but is not finished yet (`read` only) — use `wait` or check back later. |
   | `10` | Codex itself exited non-zero. |
   | `11` | Codex exited zero but produced no usable result. |
   | `12` | Wrapper-internal error. |
   | `20` | `wait` timed out; the job is still running — re-run `wait` to keep waiting. |
   | `23` | The background worker failed to start. |

5. **Merge Codex's findings into your own judgment.** Treat the result as input from a capable
   subagent, not as ground truth — you remain the final decision-maker on what to do with it.
