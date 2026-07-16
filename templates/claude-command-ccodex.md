---
description: Delegate a task to Codex CLI (via ccodex) for a second opinion, review, brainstorm, test run, worktree-isolated implementation, or long/parallel background work.
---

Use the installed `ccodex` CLI to delegate work to Codex as an external subagent. `$ARGUMENTS` is
the task text when the user supplies it inline; otherwise use the task described in the
conversation.

When command syntax is uncertain, run `ccodex <command> --help` (or `ccodex help <command>`).
Top-level `ccodex --help` and all valid help forms exit `0`; help for an unknown command exits
`2` without starting a job.

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

   `run`, `submit`, `review`, and `resume` also take optional `--model <model>` and
   `--effort <none|minimal|low|medium|high|xhigh|max|ultra>` to pick the Codex model/reasoning
   effort per call (not every model supports every effort) — omit both to use Codex's configured
   defaults (the right choice unless the task clearly needs a heavier or lighter setting).

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

5. **When Codex's answer is a clarifying question, or a finding needs pushback or refinement**,
   continue the *same* Codex session instead of starting a fresh `run` (which has no memory of
   the prior turn):

   ```powershell
   "<reply to the clarifying question, or your pushback>" | ccodex resume <job_id>
   "<background follow-up>" | ccodex submit --resume <job_id>
   ```

   `resume` always creates a brand-new job (new job id, new artifacts) — it never mutates the
   parent job you're resuming from. Worktree parents get a distinct child worktree seeded from
   their frozen snapshot; the child diff/apply is cumulative, so apply only the newest accepted
   descendant. If it fails with exit `2` naming a scrubbed/absent thread id, or fails with
   `failure_reason: thread_expired`, the session is gone —
   start a fresh `run` instead of retrying `resume`. Chain follow-ups off the latest child's job
   id, not the original parent, if the conversation continues past one reply.

   Use `submit --resume` for a background follow-up, then `wait`/`read` the returned child id.
   It has the same parent preconditions and inherits mode/access/repo/group/label; do not pass
   those flags. `--model`/`--effort` remain valid per-follow-up knobs.

6. **For long-running or parallelizable work** (e.g. a test pass, or several independent reviews
   at once), submit it in the background instead of blocking on `run`:

   ```powershell
   "<task text>" | ccodex submit --mode test --access workspace
   ```

   This prints a job id and job directory to stdout and returns immediately. Later, block for the
   result or poll for it:

   ```powershell
   ccodex wait <job_id> --json       # blocks; parse result and command_exit_code
   ccodex status <job_id> --json     # non-blocking lifecycle envelope
   ccodex read <job_id> --json       # non-blocking result envelope (exit 4 if unfinished)
   ```

   Submit multiple jobs before waiting on any of them to run them in parallel. Tag fan-out jobs
   with `--group <g>` and optional `--label <l>`, then gather once with
   `ccodex wait --all --group <g> --json` instead of hand-written polling loops.

   For these three commands, always use `--json` in automation and parse the stable top-level
   `schema_version: 1` envelope instead of scraping human text. `command_exit_code` matches the
   process exit and is distinct from the job's recorded `wrapper_exit_code`; lifecycle fields are
   present with `null` when unavailable, and `wait`/`read` carry result text in `result`. Missing
   job id remains a human usage error (exit `2`).

7. **Read stdout as the worker's final answer** for synchronous commands. For `wait --json` and
   `read --json`, read the envelope's `result` field. Do not parse prose from stderr to decide
   success or failure; use the process exit code and matching `command_exit_code`:

   | Exit code | Meaning |
   | --- | --- |
   | `0`  | Success — stdout is the final result. |
   | `2`  | Usage/validation error (bad flags, missing task, repo resolution failure; also `resume`/`submit --resume` against an absent/scrubbed thread id). |
   | `3`  | Job id not found (`status`/`wait`/`read`/`cancel`/`diff`/`apply`/`tail`/`debug`/`resume`/`submit --resume`). |
   | `4`  | Job exists but is not finished yet (`read`/`diff`/`apply`/`resume`/`submit --resume`) — use `wait` or check back later. |
   | `10` | Codex itself exited non-zero. |
   | `11` | Codex exited zero but produced no usable result. |
   | `12` | Wrapper-internal error. |
   | `20` | `wait` timed out; the job is still running — re-run `wait` to keep waiting. |
   | `21` | The per-job lock could not be acquired within its timeout — retry the command. |
   | `22` | `wait` returned because the job was cancelled (`ccodex cancel`). |
   | `23` | The background worker failed to launch, exited before stamping startup, or did not stamp startup within the configured window. |
   | `24` | The job hit `--hard-timeout-sec` and was killed. |
   | `25` | `ccodex apply` conflicted or failed; the main repo was left untouched — review `ccodex diff <job_id>` and resolve by hand. |

8. **React to failure classes without reading logs.** On exit `10`, check `status.json`'s
   `failure_reason` (a best-effort hint, not a guarantee — exit codes remain authoritative) and
   react accordingly. Its adjacent structured `failure` object supplies `matched_signal`,
   `source`, `confidence`, and `http_code`; use those fields to judge borderline matches and be
   more skeptical when `confidence` is `low`:

   | Signal | Reaction |
   | --- | --- |
   | `10` + `failure_reason: quota_or_rate_limit` | Report the limit to the user; do not auto-retry. |
   | `10` + `failure_reason: auth` | Suggest the user run `codex login`. |
   | `10` + `failure_reason: network` | Safe to retry once. |
   | `10` + `failure_reason: thread_expired` (resumed job only) | Codex no longer recognizes the session; start a fresh `run` instead of retrying the follow-up. |
   | `10` + `failure_reason` absent | Read `error` in `status.json` / stderr; use judgment. |
   | `24` (`timed_out`) | Raise `--hard-timeout-sec` or split the task into smaller pieces; don't just retry unchanged. |
   | `20` | The job is still running — re-run `wait` rather than treating it as failed. |
   | `23` | The worker failed to launch, exited before stamping startup, or exceeded the configured startup window. Inspect the message and job directory (`status.json`, `stderr.log`) to distinguish the cause before retrying. |

   When the failure looks environment-shaped rather than task-specific (auth, quota, sandbox
   denial, or the `CreateProcessWithLogonW failed: 1385` signature), run `ccodex doctor` FIRST
   (`ccodex doctor --json` for a programmatic schema-v1 result on stdout even on exit `10`/`12`) —
   it isolates whether Codex/the wrapper/the state root itself is broken before you touch the
   task again.

   For long-running work, pass `--hard-timeout-sec <n>` on `run`/`submit` to bound how long Codex
   may run before the wrapper kills it:

   ```powershell
   "<task text>" | ccodex run --mode test --access workspace --hard-timeout-sec 120
   ```

9. **Manage background jobs** with `cancel`/`tail`/`debug`/`cleanup`:

   ```powershell
   ccodex list                       # enumerate jobs (--repo/--state/--group/--label filter; --json for a machine envelope)
   ccodex cancel <job_id>            # a submitted job needs to be stopped now, not waited out
   ccodex tail <job_id> --lines 80   # raw stderr.log / codex-events.jsonl tail for a stuck job
   ccodex debug <job_id>             # compact one-shot diagnosis + suggested next command
   ccodex cleanup --dry-run          # periodic hygiene: preview the retention sweep first
   ccodex cleanup --older-than 14d   # then actually delete aged terminal jobs
   ```

   `list` is read-only and does not reconcile a dead-worker job — a crashed job may still show
   `running`/`health=stale`; use `ccodex status <id>` for an authoritative verdict.

   Reach for `cancel` the moment a background job is known to be the wrong task or stuck — don't
   just let it run to a timeout. Reach for `cleanup --older-than <Nd|Nh>` periodically (or when
   the user asks to reclaim disk / clear stale sessions), ideally after a `--dry-run` preview; add
   `--scrub-thread-ids` to also blank old jobs' `codex_thread_id` so they stop being resumable.

10. **Merge Codex's findings into your own judgment.** Treat the result as input from a capable
   subagent, not as ground truth — you remain the final decision-maker on what to do with it.
   The same applies to a delegated implementation: `ccodex apply` lands exactly what the diff
   showed, nothing more — you decide whether it's landed, not Codex.
