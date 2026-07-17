# ccodex Technical Reference

> Audience: developers and agents integrating with or extending `ccodex`. This is the exhaustive
> per-command/flag/exit-code/file-format reference. For the "why" and a quick start, see
> [`README.md`](../README.md). For architecture rationale, goals, non-goals, and phase-by-phase
> design decisions, see
> [`2026-07-03-ccodex-adapter-design.md`](2026-07-03-ccodex-adapter-design.md); for non-obvious
> conventions, regression-guarded pitfalls, and test recipes, see
> [`2026-07-07-ccodex-dev-notes.md`](2026-07-07-ccodex-dev-notes.md); for current project status
> and the full document index, see
> [`2026-07-07-ccodex-handoff.md`](2026-07-07-ccodex-handoff.md).

## Contents

1. [Command reference](#command-reference)
   - [help](#help)
   - [run and submit](#run-and-submit)
   - [review](#review)
   - [implement, diff, and apply](#implement-diff-and-apply)
   - [resume](#resume)
   - [status, wait, and read](#status-wait-and-read)
   - [cancel, tail, debug, cleanup, and doctor](#cancel-tail-debug-cleanup-and-doctor)
2. [Configuration](#configuration)
   - [Delegation policy](#delegation-policy)
   - [Retention config](#retention-config)
3. [Exit codes](#exit-codes)
4. [Failure classes](#failure-classes)
5. [Hard timeout](#hard-timeout)
6. [Job artifacts and status fields](#job-artifacts-and-status-fields)
7. [Repository layout](#repository-layout)
8. [Testing](#testing)
9. [Roadmap and status history](#roadmap-and-status-history)

## Command reference

`ccodex.ps1` dispatches to `help`, `run`, `submit`, `status`, `wait`, `read`, `review`, `resume`,
`cancel`, `diff`, `apply`, `tail`, `debug`, `cleanup`, `doctor`, and the internal `worker`
subcommand (never called directly — it is the entrypoint the detached backend launches for
`submit`). Any other subcommand exits `2` with a "not implemented" message.

### help

Help is intercepted before command validation and never starts or mutates a job:

```powershell
ccodex                         # top-level help
ccodex help                    # top-level help
ccodex --help                  # top-level help
ccodex -h                      # top-level help
ccodex help <command>          # per-command help
ccodex <command> --help        # per-command help
ccodex <command> -h            # per-command help
```

Top-level help contains the synopsis, canonical command inventory, one-line summaries, common
flags, and a diagnostic note for `debug`. Per-command help contains a usage line, summary,
relevant flags, and a short example. Every valid help form exits `0`; `help <unknown>` and
`<unknown> --help` print the standard unknown-command message and exit `2`. The command
inventory and both help forms are generated from `lib/Help.ps1`, the same source used by the
dispatcher's unknown-command message, so they cannot drift. The internal `worker` command is
never listed.

### run and submit

`ccodex run` and `ccodex submit` both read task text from exactly one of a piped or redirected
stdin stream, `--prompt-file <path>`, or a positional task argument. `run` sends it to `codex exec`
non-interactively and blocks until it finishes; `submit` prepares the same job and hands it to a
detached background worker, returning immediately (see [status, wait, and read](#status-wait-and-read)).

Before reporting a successful hand-off, `submit` waits for the detached worker to move
`status.json` off `created`. This startup sentinel defaults to a generous 120-second anti-hang
window so a healthy worker can cold-start on a saturated host. Set
`CCODEX_STARTUP_TIMEOUT_SEC` to a non-negative integer to override the window for the current
process; an explicitly bound `Invoke-CcodexSubmit -StartupTimeoutSec` value takes precedence.
A non-empty environment value that is not a non-negative integer is a usage error (exit `2`)
before any job directory is reserved.

`ccodex submit --resume <parent_job_id>` is the asynchronous follow-up form. Its task-text
sources are identical to plain `submit` (stdin, `--prompt-file`, or positional task text), while
the value following `--resume` names the finished parent job. It synchronously validates the
parent, creates a new child carrying the inherited thread/context metadata, launches the same
detached worker, and prints the child job id plus job directory immediately:

```powershell
"Continue with this additional constraint." | ccodex submit --resume <parent_job_id>
# -> <child_job_id>
#    <child_job_dir>
```

The async child inherits the parent's `mode`, `access`, `repo`, `group`, and `label`; supplying
any of `--mode`/`--access`/`--repo`/`--group`/`--label` with `--resume` is a usage error (exit
`2`). `--model`/`--effort`, `--hard-timeout-sec`, and the hidden test/support flags
`--state-root`/`--codex-path`/`--detach-mechanism` remain per-invocation submit options.

Parent validation happens before any child directory is reserved, in this order:

| `submit --resume` precondition | Exit |
| --- | ---: |
| `--resume` is missing its required value, task text is absent/ambiguous, or an inherited-context flag is supplied | `2` |
| Parent has no index entry, or its indexed job directory is missing | `3` |
| Parent is not terminal (`done`/`failed`/`timed_out`/`cancelled`) | `4` |
| Parent has no `codex_thread_id` (absent or scrubbed) | `2` |
| Worktree parent's worktree directory was removed | `3` |
| Worktree parent has `worktree_finalize_error`, lacks `snapshot_commit`, or its snapshot is not descended from the cumulative base | `12` |

The parent checks are shared with synchronous `resume`. Worktree continuations additionally
validate positive finalization evidence before reserving the child. A launch/sentinel failure
remains exit `23`, and success keeps plain submit's exact two-line output shape.

```powershell
# Synchronous, read-only review or brainstorming (defaults to --access read-only)
"Review this diff for correctness issues." | ccodex run --mode review
"What are the trade-offs of X vs Y?" | ccodex run --mode brainstorm

# Positional task text or --prompt-file instead of piping
ccodex run --mode review "Review this diff for correctness issues."
ccodex run --mode review --prompt-file .\review-task.md

# Test tasks need explicit write access for artifacts (screenshots, traces, logs)
"Run the login flow in Playwright and report the result." | ccodex run --mode test --access workspace

# Point at a repo other than the current directory's
"Review this diff." | ccodex run --mode review --repo D:\Documents\GitHub\some-other-repo
```

Mode/access matrix:

| Mode | Valid `--access` | Default when `--access` is omitted |
| --- | --- | --- |
| `review` | `read-only` only | `read-only` |
| `brainstorm` | `read-only` only | `read-only` |
| `test` | `workspace` or `worktree` | none — `--access` must be given explicitly (`read-only` is rejected) |
| `implement` | `worktree` only | `worktree` |

Pass `--hard-timeout-sec <n>` to either command to bound how long Codex may run — see
[Hard timeout](#hard-timeout).

Both commands (and `review`/`resume`) also accept two optional per-invocation Codex knobs;
omitting both leaves the codex argv byte-identical to before these flags existed:

- `--model <model>` — forwarded verbatim to Codex as exec-level `-m <model>` (model names are an
  open set, so ccodex does not validate them; an unknown model fails inside Codex and classifies
  like any other Codex failure). Omitted → Codex's own configured default model.
- `--effort <none|minimal|low|medium|high|xhigh|max|ultra>` — forwarded as exec-level
  `-c model_reasoning_effort=<value>` (one bare argv element; the value is intentionally not
  TOML-quoted — a bare value falls back to a literal string inside Codex, which sidesteps
  cmd-shim quote layering). Validation is case-sensitive; any other value is a usage error
  (exit `2`) naming the flag. The allowed list mirrors Codex's `ReasoningEffort` enum
  (verified against codex-cli 0.144.1); per-model support varies — an effort the chosen model
  does not support fails inside Codex and classifies like any other Codex failure. Omitted →
  Codex's own configured default effort. On a Codex upgrade, re-derive the list per the
  codex-upgrade-check skill.

For `submit`, the flags travel to the detached worker on its launch command line (never via
`status.json`, which carries neither — they are per-invocation knobs, not job lifecycle state).

`run` and `submit` accept optional `--group <g>` and `--label <l>`. These nullable job-metadata
values travel through `status.json`, survive lifecycle rewrites, and are inherited by resume
children. Bare flags are usage errors.

| Flag | Commands | Meaning |
| --- | --- | --- |
| `--group <g>` | `run`, `submit` | Exact, case-sensitive batch grouping metadata. |
| `--label <l>` | `run`, `submit` | Exact, case-sensitive descriptive metadata. |

### review

`ccodex review` is sugar over the `run` pipeline (always `--mode review`, `--access read-only`):
it composes a review prompt from a diff selector and hands it to the same execution path as
`run` — identical job artifacts, exit codes, and failure classification. It never reads piped
stdin; the task text is the composed prompt, not caller-supplied text. By default it tells Codex
to run `git diff` itself (inside its own read-only sandbox) and review the result, which keeps
the prompt tiny and lets Codex open surrounding files for context.

Pick exactly one range selector:

```powershell
# A commit range
ccodex review --range abc123..HEAD --path lib/ --intent "Add retry logic to CodexInvoke"

# The staged index
ccodex review --staged --path lib/Config.ps1 --intent "New config reader"

# The working tree (uncommitted, unstaged changes)
ccodex review --working --path lib/ --intent "In-progress refactor"
```

Other flags:

- `--path <p>` — repeatable; scopes the diff to one or more paths (directories or files) instead
  of the whole repo. Omit it to review the full range.
- `--intent "<text>"` — one-line description of what the change is trying to do; included in the
  prompt to give Codex context.
- `--focus "<text>"` — an additional angle to emphasize (e.g. "concurrency" or "error handling").
- `--embed-diff` — instead of having Codex run `git diff` itself, the wrapper runs it up front
  (from `--repo`'s root) and embeds the diff plus a `git diff --stat` summary directly in the
  prompt, capped at 100 KB with a truncation note. Use this when Codex regenerating the diff
  itself would be unreliable (unusual git states, detached worktrees, etc) — and treat it as the
  default on hosts where Codex's sandbox cannot spawn processes at all (Codex reports
  `CreateProcessWithLogonW failed: 1385`; the self-diff form cannot work there).
- `--repo <path>` — as with `run`/`submit`, target a repository other than the current directory.
- `--model <model>` / `--effort <none|minimal|low|medium|high|xhigh|max|ultra>` — the same
  per-invocation Codex knobs as `run`/`submit` (review is sugar over the `run` pipeline, so they
  flow straight through).

Findings always come back severity-ordered (Critical, then Important, then Minor) with a
file:line and a suggested fix per finding, plus a one-line verdict — success prints exactly that
to stdout, and failures behave exactly like a failed `run` (same exit codes and
`failure_reason` hints).

**Submodule scoping:** when the change under review lives inside a git submodule, point `--repo`
directly at the submodule instead of the superproject, so the diff and path scoping resolve
against the submodule's own history:

```powershell
ccodex review --repo D:\Documents\GitHub\superproject\vendor\some-submodule `
  --range abc123..HEAD --path src/ --intent "Bump dependency and adjust call sites"
```

### implement, diff, and apply

`--mode implement` runs an edit-capable Codex worker inside an isolated, detached git worktree
under the state root (`%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`) — never inside the caller's own
working tree, and the main repo is never mutated by the run itself:

```powershell
"Add input validation to the signup form." | ccodex run --mode implement --repo D:\some\repo
# -> blocks until Codex finishes, then prints its final message (same as any other `run`)

# Or run it in the background like any other job:
"Add input validation to the signup form." | ccodex submit --mode implement --repo D:\some\repo
ccodex wait <job_id>
```

When the process exits (success, failure, or a hard-timeout kill), the wrapper stages and commits
whatever the worker left behind into one deterministic snapshot commit (author
`ccodex-worker <ccodex@local>`, message `ccodex: worker output <job_id>`) on top of the worktree's
base commit — a no-op worker leaves the worktree at its base commit instead (`status.json`'s
`worktree_committed` is `false`). Every finalized worktree job records that frozen HEAD in
`snapshot_commit`. `status.json`/`debug.json` additionally record `main_repo`, `worktree_repo`,
and `base_commit` for a worktree job (`null` for non-worktree jobs); a resumed worktree child
also records `series_base_commit`, the original main-repo base inherited through the lineage.

**`ccodex diff <job_id> [--stat | --name-only]`** — read-only inspection of a worktree job's
changes. Its range base is `series_base_commit` when present, otherwise `base_commit`; its
endpoint is `snapshot_commit` when present, otherwise live worktree `HEAD` for pre-F3 jobs. By
default it prints `git diff --stat <range_base>..<endpoint>` followed by the full diff.
`--stat` prints only the diffstat block; `--name-only` prints only the changed file paths — both
let a reviewer size a diff before pulling the whole patch, and they are mutually exclusive
(passing both is exit `2`). An empty change set prints an informational
"no changes to diff" line instead in every mode
(still exit `0`). Exit `3` for an unknown job id or a worktree already removed by `cleanup`
("worktree removed; artifacts remain at `<job_dir>`"); exit `4` if the job hasn't finished yet;
exit `2` if the job wasn't run with `--access worktree` in the first place.

```powershell
ccodex diff <job_id>              # stat + full patch
ccodex diff <job_id> --stat       # diffstat only (size before loading the patch)
ccodex diff <job_id> --name-only  # changed paths only
```

**`ccodex apply [--allow-untracked] [--message <msg>] [--reset-author] <job_id>`** — explicitly lands a **done** worktree job's resolved cumulative
range onto the main repo: `git format-patch <range_base>..<endpoint> --stdout` from the worktree, piped to
`git am --3way` in the main repo. By default the main repo's working tree must be fully clean
(exit `2`, naming the dirty files, otherwise). `--allow-untracked` permits a tree whose only
differences are untracked files, but first compares the patch's touched paths with the normalized
pre-existing untracked inventory; any overlap is rejected with exit `2` and the overlapping paths
named. Tracked modifications, staged changes, or deletions always block, with or without the flag.
Only `done` jobs may be applied (`failed`/`timed_out`/`cancelled` → exit `2`); an empty change set
is a no-op (exit `0`, main repo untouched). On
success it prints the applied commit range and exits `0`. **Any** non-success outcome — a textual
conflict, or a patch `git am` accepts as a no-op without advancing `HEAD` (e.g. already applied) —
runs `git am --abort` and force-restores the main repo to its pre-apply `HEAD`, then exits **`25`**
naming the conflicting files and pointing at `ccodex diff <job_id>`. The main repo is never left
mutated except by a genuinely successful apply; with `--allow-untracked`, the pre-existing
untracked files are preserved and do not make a successful rollback look incomplete.

By default the landed commit keeps the worker's synthetic identity (author `ccodex-worker
<ccodex@local>`, message `ccodex: worker output <job_id>`). `--reset-author` reauthors it to the
main repo's configured git user; `--message <msg>` sets its commit message — landing with operator
identity in one step instead of a manual `git commit --amend --reset-author`. Both amend the single
landed commit after a successful `am`; because a resumed cumulative series applies more than one
commit (where a single message/author would be ambiguous), either flag on a multi-commit range is
rejected up front with exit `2` **before** the main repo is touched. If the post-`am` amend itself
fails (e.g. no git identity is configured for `--reset-author`), the main repo is restored to its
pre-apply `HEAD` and the command exits `12`.

For a resumed implement series, apply only the newest accepted descendant. Its range is already
cumulative (parent + child work); never apply an ancestor and then its cumulative descendant.
The existing failed-apply restore path handles that misuse safely as exit `25`, but it is still
an operator error.

```powershell
ccodex diff <job_id>    # ALWAYS review before applying — never auto-apply
ccodex apply <job_id>
ccodex apply --allow-untracked <job_id>  # only for non-overlapping untracked files
ccodex apply --reset-author <job_id>     # land under your git identity, worker message kept
ccodex apply --reset-author --message 'feat: ...' <job_id>  # identity + message in one step
# -> ccodex: applied job <job_id> to <main_repo>
#      range: <base_commit>..<new_head>
```

`ccodex cleanup` removes a deleted job's worktree directory (via the recorded `main_repo`) before
removing its job dir, and separately sweeps any dangling worktree directory whose job dir is
already gone — see
[cancel, tail, debug, cleanup, and doctor](#cancel-tail-debug-cleanup-and-doctor) below.

### resume

`ccodex resume <job_id>` continues a **finished** job's Codex session with a follow-up, instead of
starting a fresh `run` that has no memory of the prior turn. It reads follow-up text from exactly
the same prompt sources as `run` (piped/redirected stdin, `--prompt-file`, or — since the
positional slot is taken by the parent job id — no positional task text) and accepts
`--hard-timeout-sec` like `run`/`submit`. It rejects `--repo`, `--mode`, and `--access` with a
usage error (exit `2`): the child always inherits the parent's `mode`, `access`, and `repo`
verbatim. `--model`/`--effort` are accepted, though — they are per-invocation knobs, not
inherited parent context, so a follow-up may run with a different model or effort than the
parent did (same placement rules: they land in the exec-level argv segment, before the
`resume <thread-id>` token). It likewise rejects a second positional argument after the job id (exit `2`) — the
follow-up text must come from stdin or `--prompt-file`, never a positional.

For the asynchronous form, use `ccodex submit --resume <job_id>` instead. It accepts plain
submit's full task-source set (including positional task text), returns the new child id and job
directory immediately, and is collected later with `wait`/`read`; parent preconditions and
failure classification are shared with synchronous `resume`.

```powershell
"Reply with exactly SEED." | ccodex run --mode brainstorm
# -> <job_id_1>
"Now say CONTINUED instead." | ccodex resume <job_id_1>
# -> CONTINUED, from the SAME Codex thread — job_id_1's context carries forward
```

**`resume` always creates a brand-new job** — a fresh job id, job directory, `prompt.md`, and
index entry — and the parent job's directory/`status.json` are strictly read-only to it; nothing
about the parent is ever mutated. Non-worktree `prompt.md` is the follow-up text only. A worktree
parent creates a new detached child worktree at the parent's recorded `snapshot_commit`; its
prompt prepends a relocation envelope naming the new worktree and child artifact directory so
paths remembered from earlier turns are not reused. The child's `status.json` carries
`parent_job_id` (the parent's job id) for lineage,
alongside the same `codex_thread_id`, `group`, and `label`. Group and label are inherited-only;
`resume --group` and `resume --label` are rejected as usage errors (exit 2). Internally it invokes
`codex exec resume <thread_id>` (the
Task-1 `--ask-for-approval never … --sandbox <mapped-access> --json --color never -C <repo>
--output-last-message <result.md> -` shape with `exec resume <thread_id>` spliced in place of
`exec`) so result validation, `failure_reason` classification, and the terminal status write are
identical to `run`.

**Preconditions**, checked in this order, each with its own exit code:

| Precondition | Exit | Message shape |
| --- | --- | --- |
| Parent job id has no index entry, or its job directory is missing | `3` | same "not found" message `status`/`wait`/`read` use |
| Parent job exists but is not yet terminal (`done`/`failed`/`timed_out`/`cancelled`) | `4` | names the job id and its current status |
| Worktree parent's directory was removed | `3` | "worktree removed"; the WIP no longer exists |
| Worktree parent recorded `worktree_finalize_error` | `12` | names the finalization failure |
| Worktree parent lacks `snapshot_commit` | `12` | cancelled or predates worktree-resume support; start fresh |
| Parent's `codex_thread_id` is absent or was scrubbed | `2` | "has no codex thread id (absent or scrubbed by cleanup) - start a fresh run" |
| Worktree snapshot is not descended from `series_base_commit ?? base_commit` | `12` | history is not linear from its base |

For worktree parents, the directory/finalization/snapshot checks precede the thread-id and ancestry
checks, and every nonzero precondition returns before a child is reserved. Beyond these, `resume` shares
`run`'s usual usage-error exit `2` (bad/ambiguous prompt source, etc.) and its `10`/`11`/`12`/`24`
failure exits.

**`thread_expired` failure class:** if Codex itself rejects the resume (its own session storage no
longer recognizes the thread id — signature: "session not found", "thread not found", "no
session", "conversation not found"), the job fails with wrapper exit `10` and
`status.json.failure_reason = "thread_expired"` (hint: "Codex session expired or was pruned -
start a fresh ccodex run."). This takes precedence over quota/auth/permission/network
classification when its signature is present. It is distinct from the exit-`2` preconditions
above: those are ccodex's own local checks before ever calling Codex; `thread_expired` is Codex
itself rejecting a thread id that locally still looked valid.

**Interplay with `cleanup --scrub-thread-ids`:** `cleanup`'s thread-TTL scrub (see
[cancel, tail, debug, cleanup, and doctor](#cancel-tail-debug-cleanup-and-doctor) below) is what
usually produces the exit-`2` "absent or scrubbed" case above — once a retained job's
`codex_thread_id` is blanked (by age, or forced for testing via `--scrub-thread-ids --thread-ttl
0d`), that job becomes permanently non-resumable even though its artifacts and job directory
remain. There is no way to un-scrub a thread id; the only recovery is a fresh `run`.

If Codex's answer to a `resume` is itself another clarifying question, keep chaining
`ccodex resume <job_id>` off of the latest child's job id, not the original parent — each call
returns a new job id to resume from next.

### status, wait, and read

`submit` returns as soon as the job is prepared and handed to a detached worker — it prints the
job id then the job directory (two lines) and exits `0` without waiting for Codex to finish. Use
`status`/`wait`/`read` from any directory to check on it later, including after the submitting
process has exited:

```powershell
"Run the full test suite and report failures." | ccodex submit --mode test --access workspace
# -> <job_id>
#    <job_dir>

ccodex status <job_id> [--json]   # non-blocking lifecycle state
ccodex wait <job_id> [--json]     # blocks until terminal (or its wait timeout)
ccodex wait --all [--group <g>] [--label <l>] [--json] [--wait-timeout-sec <n>]
ccodex read <job_id> [--json]     # non-blocking result read; exits 4 if not finished yet
```

Submit several jobs before waiting on any of them to run independent tasks in parallel.
The same collection flow applies to a child returned by `submit --resume <parent_job_id>`.

`wait --all` takes one snapshot of currently `created`/`running` jobs, optionally filtered by
exact case-sensitive group, label, and repo. Later submissions are excluded. The timeout applies
to the whole batch; zero matches exit 0. Human output is one line per resolved job plus a summary.
JSON contains ordered `schema_version`, `jobs`, `summary`, and `command_exit_code`; every nested
job is the unchanged single-job wait envelope. Summary fields are `total`, `succeeded`, `failed`,
`timed_out`, `no_result`, `cancelled`, and `wait_timeout`. Exit precedence is 3, 20, 12, 10, 24,
11, 22, 0. A job id with `--all`, or group/label without `--all`, is exit 2. Single-job wait is
unchanged.

With no matches, human mode prints exactly `ccodex: no non-terminal jobs match.`; JSON returns
`jobs: []`, zeroes every summary count, and exits 0. Batch deadline envelopes retain each job's
actual last-known state, and deadline expiry never writes `status.json`.

| Batch JSON field | Contract |
| --- | --- |
| `schema_version` | Always `1`. |
| `jobs` | One unchanged single-job wait envelope per snapshot job, job-id descending. |
| `summary` | Always has `total`, `succeeded`, `failed`, `timed_out`, `no_result`, `cancelled`, `wait_timeout`. |
| `command_exit_code` | Batch process exit code from the precedence table below. |

| Precedence | Exit | Condition |
| ---: | ---: | --- |
| 1 | 3 | Missing or unenumerable state root. |
| 2 | 20 | Batch deadline leaves at least one job non-terminal. |
| 3 | 12 | Any internal-error result. |
| 4 | 10 | Any failed result. |
| 5 | 24 | Any hard-timeout result. |
| 6 | 11 | Any terminal job without a usable result. |
| 7 | 22 | Any cancelled result. |
| 8 | 0 | All succeeded, or the snapshot is empty. |

Each command accepts the presence flag `--json`. Without it, the existing human text is the
default and is unchanged. With it, stdout is an ordered JSON envelope rendered by
`ConvertTo-Json -Depth 10`; this applies to lifecycle outcomes with nonzero exits as well as
success. `--json` never changes the process exit code. A missing job id is a usage error (exit
`2`) and intentionally remains human text rather than a lifecycle envelope.

All normal lifecycle envelopes begin with top-level `schema_version: 1`. This envelope version
is distinct from the `schema_version` inside a job's `status.json`. Every field listed for a
normal envelope is always present, with JSON `null` when its source value is absent. The new
`command_exit_code` is the exit-code-equivalent for this invocation; it is deliberately distinct
from `wrapper_exit_code`, which is the job's recorded wrapper exit in `status.json`.

**`status --json` envelope contract:**

- Fields: `schema_version`, `job_id`, `status`, `codex_exit_code`, `wrapper_exit_code`, `health`,
  `parent_job_id`, `job_dir`, `command_exit_code`.
- `status` is the recorded or reconciled state (falling back to `unknown`); `health` is
  `possibly-stale` for that reconciliation verdict, otherwise the derived `ok`/`stale` value or
  `null`. `job_dir` is absolute. A successful status query has `command_exit_code: 0`.
- An unknown/unloadable job returns exit `3` and
  `{schema_version,job_id,status:"unknown",error,job_dir:null,command_exit_code:3}`.

**`read --json` envelope contract:**

- Fields: `schema_version`, `job_id`, `status`, `finished`, `result_present`, `result`, `health`,
  `job_dir`, `command_exit_code`.
- `finished` means the status is `done`, `failed`, `timed_out`, or `cancelled`.
  `result_present` reflects result validation and `result` is the full `result.md` text only when
  usable. Exit/code pairs are success `0`, unfinished `4`, terminal missing/empty result `11`,
  and unknown job `3` (using the same error envelope shape as `status`).

**`wait --json` envelope contract:**

- Fields: `schema_version`, `job_id`, `status`, `codex_exit_code`, `wrapper_exit_code`, `result`,
  `timeout_reason`, `health`, `job_dir`, `command_exit_code`.
- It blocks and polls exactly like human-mode `wait`, then emits one envelope. Exit/code pairs
  are done with a valid result `0`, done with no usable result `11`, failed `10`/`11`/`12` as
  recorded and validated, hard timed-out `24` by default (or the recorded wrapper exit),
  cancelled `22`, wait's own elapsed `--wait-timeout-sec` `20`, and unknown job `3` (the shared
  error shape). `timeout_reason` surfaces the recorded hard-timeout reason. On wait's own timeout,
  `status` is the current non-terminal state and `health` may be `possibly-stale`; the command does
  not modify `status.json`.

**`doctor --json` envelope contract:**

```json
{
  "schema_version": 1,
  "ok": false,
  "env_failed": true,
  "smoke_failed": false,
  "checks": [
    {
      "name": "codex resolvable",
      "status": "fail",
      "detail": "'codex --version' exited 1",
      "output": null
    }
  ],
  "command_exit_code": 12
}
```

- Fields, in order: `schema_version`, `ok`, `env_failed`, `smoke_failed`, `checks`,
  `command_exit_code`. `schema_version` is `1`; `ok` is true exactly when
  `command_exit_code` is `0`.
- `checks` contains one ordered object per human check, in emission order. Each object always has
  `name`, `status`, `detail`, and `output`. `name` is the human line's name segment; `status` is
  `pass`, `fail`, `warn`, or `skip`; and `detail` is the text after `<name>: `. `output` is
  non-null only when delegated `codex doctor` exits nonzero, where it contains the raw text shown
  under the human `== codex doctor output ==` block.
- Nonzero index/jobs consistency counts map to `warn` (but remain human `ok` and never fail the
  command); `--no-smoke` maps the smoke check to `skip`; other successful and failed checks map
  to `pass` and `fail`.
- The envelope is rendered with `ConvertTo-Json -Depth 10` and written to stdout on exits `0`,
  `10`, and `12`. Exit precedence is unchanged. Usage errors such as a bad `--repo` remain exit
  `2` human text even when `--json` was requested.

For a resumed job created by either `ccodex resume` or `ccodex submit --resume`, `status`/`debug` append `parent=<parent_job_id>` /
`parent: <parent_job_id>` to name the job it continued — see [resume](#resume) above.

### list

**`ccodex list [--json] [--repo <path>] [--state <s> ...] [--group <g>] [--label <l>]`** enumerates jobs, newest first. It is
the job-enumeration endpoint the batch/orchestration use cases build on.

```powershell
ccodex list                                        # human table, all repos, newest first
ccodex list --repo D:\some\repo                     # narrow to one repo's jobs
ccodex list --state running --state failed          # repeatable: only these states
ccodex list --json                                  # machine-readable envelope
ccodex list --group ci --label full                 # exact, case-sensitive metadata filters
```

- **Flags:** `--json` (presence) switches to the JSON envelope below; absent ⇒ human text (always
  the default). `--repo <path>` resolves to a repo key and scans only that subtree; absent ⇒
  **global** across all repos. `--state <s>` is repeatable (`created|running|done|failed|timed_out|
  cancelled`); absent ⇒ all states; an invalid value is a usage error (exit `2`). `--state-root
  <root>` is a hidden test-support flag mirroring the other subcommands.
- **Enumeration source:** the `jobs/` tree (`<root>\ccodex\jobs\<repo_key>\<job_id>\status.json`),
  the same authoritative source `cleanup` uses — not the flat `index/`, which can carry dangling
  entries and miss a crash-orphaned dir. Sorted by `job_id` descending; the id's leading UTC
  timestamp makes lexical order chronological.
- **Read-only. Zero writes. No reconciliation.** Unlike `status`/`wait`/`read`, `list` never calls
  `Update-CcodexOrphanStatus`. A `running` job's `health` is the heartbeat-derived `ok|stale` from
  `Get-CcodexJobHealth` (needs no lock). Tradeoff: a job whose worker died without completion
  evidence still shows `running` here, with `health=stale` as the signal — run `ccodex status <id>`
  for an authoritative, reconciled verdict.
- **Human line format** (one per job):

  ```
  <job_id>  <status>[ health=stale]  <mode>/<access>  <backend>  <repo>
  ```

  `health=stale` is appended only for a `running` job whose derived health is `stale` (an `ok`
  running job and every non-running job append nothing — mirrors the `status` line's restraint). A
  job whose `status.json` is missing/unreadable renders as `<job_id>  unknown  (<error>)`. Zero
  jobs ⇒ `ccodex: no jobs found.` and exit `0`.
- **`--json` envelope:** a top-level `schema_version` (currently `1`, distinct from each job
  object's own `schema_version`), `count`, and `jobs[]`. Each normal job = that job's `status.json`
  fields plus a derived `health` and its absolute `job_dir`; an unreadable/missing status.json
  yields a minimal `{ job_id, status:"unknown", error, job_dir }`. Rendered with `ConvertTo-Json
  -Depth 10`. Zero jobs ⇒ `{ "schema_version": 1, "count": 0, "jobs": [] }`.
- **Exit codes:** `0` (success, including zero jobs); `2` (invalid `--state` value or an
  unresolvable `--repo`); `12` (wrapper-internal error, rare).

### cancel, tail, debug, cleanup, and doctor

**`ccodex cancel <job_id>`** stops a `running` (or still-`created`) job: it identity-checks the
recorded `backend_id` (pid + start time, so a reused pid is never mistaken for the job's own
worker), force-kills the whole process tree (worker + whatever `codex` child it spawned), and
marks the job `cancelled` with a `cancelled_at` timestamp. It is a no-op — exit `0`, printing
`<job_id> already <status>` — on a job that is already terminal (`done`/`failed`/`timed_out`/
`cancelled`); a `wait` on an already-cancelled job returns exit `22`.

```powershell
ccodex cancel <job_id>
# -> <job_id> cancelled
```

**`ccodex tail <job_id> [--lines <n>]`** prints the last `n` lines (default `40`) of
`stderr.log` and `codex-events.jsonl` for a job — read-only, never reconciles or mutates
`status.json`. A missing file renders as `(absent)` rather than failing the whole command.

```powershell
ccodex tail <job_id> --lines 80
```

**`ccodex debug <job_id>`** prints a compact one-shot diagnosis: status (with `health=ok|stale`
while running), mode/access/backend/repo, a `parent: <job_id>` line if the job was created by
`ccodex resume` or `ccodex submit --resume`, every recorded timestamp, `backend_id` with a live/dead
verdict, exit codes, `failure_reason` (with its hint line), `codex_thread_id` (or
`absent/scrubbed`), whether `result.md` is present, the last 5 lines of `stderr.log`, the job
directory, and a suggested next command (`ccodex wait`/`read`/`tail` depending on status).

```powershell
ccodex debug <job_id>
```

**`ccodex cleanup`** sweeps the jobs tree (not just the index — a crash mid-delete can leave an
unindexed job directory the tree scan still finds) and deletes terminal jobs older than the
retention threshold, in index-entry-then-directory order, plus any dangling index entries whose
job directory is already gone. It never touches a young or still-live job. When a deleted job
carries a recorded worktree (a `--access worktree` job), its worktree directory is removed first
via `git worktree remove` against the job's `main_repo` (best-effort — a worktree-teardown failure
never blocks the job dir/index delete); separately, any *dangling* worktree directory under
`worktrees\` whose job dir is already gone anywhere is swept too. Pass `--dry-run` to preview
without deleting (worktree candidates are listed alongside job candidates); `--include-stalled`
first reconciles non-terminal jobs with a dead worker (same check `status`/`wait`/`read` do)
before judging them; `--scrub-thread-ids` blanks `codex_thread_id` (under the per-job lock,
byte-stable rewrite — no other field changes) on retained jobs older than the thread TTL, making
them non-resumable. `--older-than <Nd|Nh>` and `--thread-ttl <Nd>` override the configured
thresholds for one run; `--repo <path>` narrows the sweep to one repo's jobs (the worktree sweep
itself is deliberately unfiltered by `--repo`, since worktrees live in one global directory, not
per-repo). Best-effort: exit `0` normally, `12` only if an individual delete/scrub failed (the
sweep still completes and reports the count). Defaults come from
[Retention config](#retention-config).

```powershell
ccodex cleanup --dry-run                            # preview only
ccodex cleanup                                      # delete aged terminal jobs (+ their worktrees)
ccodex cleanup --older-than 7d --repo D:\some\repo   # narrower, repo-scoped sweep
ccodex cleanup --include-stalled --scrub-thread-ids # reconcile stalled jobs + scrub old thread ids
# -> cleanup: deleted=<n> reclaimed_kb=<n> dangling=<n> scrubbed=<n> skipped=<n> failed=<n> worktrees_swept=<n>
```

**`ccodex doctor [--json] [--no-smoke] [--repo <path>]`** is the first move whenever a failure looks
environment-shaped rather than task-specific (auth, quota, sandbox denial, the
`CreateProcessWithLogonW failed: 1385` signature) — it isolates whether Codex, the wrapper, or the
state root itself is the problem before you retry anything. It runs, in order: `codex --version`
resolvable and successful; delegated `codex doctor` (its own output is echoed on failure);
state-root writability (create+delete a probe file under `jobs\`); worker-prompt template
present; an informational index/jobs consistency count (dangling indexes, unindexed job
directories — never fails the command); and, unless `--no-smoke` is passed, a real end-to-end
`ccodex run` smoke test expecting the literal reply `OK`. An environment check failure always
yields exit `12`, even if the smoke test also failed — a broken environment is the more
fundamental problem. A smoke-test-only failure yields exit `10`. A bad `--repo` is a usage error
(exit `2`), same as `run`/`review`.

With `--json`, doctor emits the schema-version-1 envelope documented above on stdout regardless
of a `0`, `10`, or `12` exit. Human output and all exit codes are unchanged without the flag;
usage exit `2` intentionally remains human text.

```powershell
ccodex doctor              # full check including the live smoke test
ccodex doctor --no-smoke   # environment checks only, no real Codex call
ccodex doctor --json --no-smoke # programmatic environment checks
```

## Configuration

### Delegation policy

A project can opt into automatic delegation checkpoints — teaching a Claude Code session when to
run a `ccodex review` on its own — by adding `<repo_root>/.ccodex/ccodex.json`:

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

This file is configuration only — it is never touched by job execution and lives outside the
job-state tree entirely. The file and the `delegation` section are both optional; a missing file,
a missing section, or missing individual keys all fall back to the defaults shown above.
Malformed JSON or an invalid enum value is a usage error (exit `2`) naming the file.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `review_after_changes` | `"auto"` \| `"ask"` \| `"off"` | `"ask"` | Post-change checkpoint: run a review automatically, ask the user first, or only review on explicit request. |
| `review_min_changed_lines` | int | `50` | Below this changed-line count, skip the post-change review entirely (cost guard). |
| `review_default_paths` | string[] | `[]` | Default `--path` set for the post-change review when the caller hasn't narrowed it further. |
| `plan_second_opinion` | `"auto"` \| `"ask"` \| `"off"` | `"ask"` | Post-plan checkpoint: same auto/ask/off semantics, applied after writing or updating a plan/spec document. |
| `max_codex_calls_per_task` | int | `2` | Cap on total `ccodex` calls (review or otherwise) per task; once reached, no further calls are made for the rest of the task. |

Installing `ccodex` installs a Claude Code rule at `~/.claude/rules/ccodex-delegation.md` that
teaches every session how to read this file and apply the checkpoints — the user never has to
re-explain the policy per project or per session.

### Retention config

`cleanup`'s default thresholds come from an optional `retention` section in
`%APPDATA%\ccodex\config.json` (distinct from the per-project `.ccodex/ccodex.json` delegation
config above — this one is user-level, applying to every repo):

```json
{
  "retention": {
    "jobs_days": 14,
    "thread_ttl_days": 30
  }
}
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `jobs_days` | non-negative int | `14` | A terminal job older than this (measured from `finished_at`, else `terminated_at`, else `cancelled_at`, else `created_at`) is deleted by `cleanup`. |
| `thread_ttl_days` | non-negative int | `30` | With `--scrub-thread-ids`, a *retained* terminal job older than this has its `codex_thread_id` blanked. |

The file and the `retention` section are both optional; a missing file, a missing section, or
missing individual keys fall back to the defaults above. A malformed `config.json`, a
non-integer value, or a negative value is a usage error naming the file. `--older-than <Nd|Nh>`
and `--thread-ttl <Nd>` on the `cleanup` command line always take precedence over this file for
that one invocation.

## Exit codes

Callers can rely on these wrapper exit codes:

| Code | Meaning |
| ---- | ------- |
| `0`  | Success — help was printed; `result.md` was produced and its content was printed to stdout (`run`/`wait`/`read`); or the job id + job dir were printed (`submit`). |
| `2`  | Usage/validation error (bad `--mode`/`--access`, missing/ambiguous prompt source, repo resolution failure, unknown subcommand, etc.). |
| `3`  | Job id not found (`status`/`wait`/`read`). |
| `4`  | Job exists but has not reached a terminal status yet (`read` only — `wait` blocks instead). |
| `10` | The `codex exec` process itself exited non-zero. |
| `11` | `codex exec` exited zero but `result.md` is missing or empty. |
| `12` | Wrapper-internal error (unexpected I/O/serialization failure). |
| `20` | `wait` timed out (`--wait-timeout-sec`) before the job reached a terminal status; the job's lifecycle is unaffected — re-run `wait` to keep waiting. |
| `21` | `cancel` or `apply` could not acquire the per-job lock within its timeout. Retry the command. (An internal status-write lock failure surfaces as `12`, not `21`.) |
| `22` | `wait` returned because the job's terminal status is `cancelled` (someone ran `ccodex cancel` on it). |
| `23` | The background worker failed to launch, exited before stamping startup (detected immediately after a 500 ms status re-check), or did not stamp startup within the configured window during `submit`. The default window is 120 seconds and `CCODEX_STARTUP_TIMEOUT_SEC` can override it. |
| `24` | The job hit `--hard-timeout-sec` before Codex exited; the process tree was killed and the job is terminal `timed_out`. Raise the timeout or split the task before retrying. |
| `25` | `ccodex apply <job_id>` failed or conflicted; `git am --abort` ran and the main repo was force-restored to its pre-apply `HEAD` (never left mutated). Review `ccodex diff <job_id>`, resolve by hand, and re-run `apply`. |

`diff` and `apply` additionally use exit `2` for a non-worktree job, (for `diff`) both `--stat`
and `--name-only` at once, or (for `apply`) a non-`done`
job, tracked-dirty main repo, default-mode untracked file, `--allow-untracked` path overlap, or
`--message`/`--reset-author` on a multi-commit series;
they use exit `4` for a job that hasn't finished yet — see
[implement, diff, and apply](#implement-diff-and-apply) above. `cancel`, `tail`, `debug`, and
`cleanup` additionally use exit `3` for an unknown job id (same as `status`/`wait`/`read`) and
exit `12` for a wrapper-internal failure; `cleanup` and `doctor` are documented in full in
[cancel, tail, debug, cleanup, and doctor](#cancel-tail-debug-cleanup-and-doctor) above. `resume`
and `submit --resume` additionally use exit `3` for an unknown parent job id, exit `4` for a parent that hasn't reached
a terminal status yet, and exit `2` for a worktree-access parent or a parent whose
`codex_thread_id` is absent/scrubbed — see [resume](#resume) above.

## Failure classes

When `codex exec` itself fails (wrapper exit `10`) or a pre-launch internal failure occurs
(exit `12`), `status.json` may carry a `failure_reason` — a conservative, best-effort HINT
derived from matching known signatures in the tail of `stderr.log` and any `"error"`-bearing
event lines. It is never stamped on a successful run, and exit codes remain authoritative;
treat `failure_reason` as a shortcut to the right reaction, not a guarantee:

| `failure_reason` | Meaning | Recommended reaction |
| ---- | ------- | ------- |
| `quota_or_rate_limit` | Codex usage/rate limit reached (signature: `usage limit`, `rate limit`, `quota`, `429`). | Report to the user; do not auto-retry. |
| `auth` | Codex auth/credential problem (signature: `login`, `auth`, `401`, `unauthorized`, `credential`). | Suggest running `codex login`. |
| `permission_or_sandbox` | Sandbox or approval denial (signature: `sandbox`, `denied`, `approval`, `permission`). | Narrow the scope. Only `test`/`implement` may use `--access workspace`; keep `review`/`brainstorm` read-only. |
| `network` | Transient network failure (signature: `network`, `connection`, `dns`, `502`, `503`). | One retry is safe. |
| `thread_expired` | Codex itself no longer recognizes the resumed thread id (signature: "session not found", "thread not found", "no session", "conversation not found"). Only seen on synchronous `resume` or a `submit --resume` child. | Start a fresh `ccodex run` — the session is gone, not retryable. |
| *(absent)* | No recognized signature, or the run succeeded. | Fall back to the exit code and `error` message. |

Alongside that compatibility string, `status.json.failure` is non-null exactly when
`failure_reason` is non-null and has this ordered shape:

| `failure` field | Contract |
| --- | --- |
| `reason` | The same enum string as `failure_reason`; always identical to it. |
| `matched_signal` | The single winning lowercase literal alternative (for example `rate limit`, `429`, or `session not found`). |
| `source` | `stderr`, `events`, or `both`, according to which filtered input stream(s) contain the winning alternative. |
| `confidence` | `high`, `medium`, or `low`, from the winning signal descriptor. |
| `http_code` | A contextual HTTP 4xx/5xx code when present, otherwise the signal's static code where defined, otherwise `null`. |

Classification is driven by one ordered signal-descriptor table; the first matching row wins.
Its class order reproduces the legacy precedence exactly: thread_expired beats quota beats auth
beats permission beats network, so `failure_reason` is unchanged for every prior input. Within a
class, alternatives retain their former left-to-right order. Confidence is `high` for
unambiguous domain phrases, `medium` for real words that may occur in unrelated prose, and `low`
for bare numeric substrings plus the generic token `auth`.

`status.json` also records
`codex_thread_id` (the Codex `thread_id`, captured on both success and failure whenever the
events log carries one) — this is exactly the value `ccodex resume <job_id>` uses to continue the
session; `submit --resume` uses the same value asynchronously. See [resume](#resume) above.

## Hard timeout

Pass `--hard-timeout-sec <n>` to `run` or `submit` to bound how long Codex is allowed to run
before the wrapper kills its whole process tree:

```powershell
"Run the full test suite." | ccodex run --mode test --access workspace --hard-timeout-sec 120
"Run the full test suite." | ccodex submit --mode test --access workspace --hard-timeout-sec 120
```

On expiry the job becomes terminal `timed_out` with `timeout_reason` (e.g.
`hard_timeout_sec=120 exceeded`) and `terminated_at` recorded in `status.json`,
`codex_exit_code` stays `null` (Codex never produced one), and the wrapper/`wait` exit code is
`24`. All artifacts (`prompt.md`, `codex-events.jsonl`, `stderr.log`, `status.json`) are kept for
inspection. The default is `0`, meaning no hard timeout is applied — a quiet job is not assumed
dead.

## Job artifacts and status fields

Every job leaves behind `prompt.md`, `command.txt`, `debug.json`, `status.json`,
`worker-complete.json`, `codex-events.jsonl`, `stderr.log`, and (on success) `result.md` under
`%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`. `exit_code.txt` is written whenever Codex exits
on its own; a hard-timeout kill (exit `24`) leaves none. There is also an index entry at
`%LOCALAPPDATA%\ccodex\index\<job_id>.json` that lets `status`/`wait`/`read` find the job from any
directory. `status.json` additionally records `backend` (`sync` for `run`, `native` for
`submit`/`worker`), `backend_id`, `started_at`, `finished_at`, `failure_reason`, `failure`,
`codex_thread_id`, `hard_timeout_sec`, `timeout_reason`, `terminated_at`, `cancelled_at`,
`last_heartbeat_at`, `parent_job_id` (the parent's job id for a `resume`d job, `null` otherwise),
`group`, and `label` (nullable strings, always present and inherited by resumed children),
and — for a `--access worktree` job — `main_repo`, `worktree_repo`, `base_commit`,
`worktree_committed`, `worktree_finalize_error`, and `snapshot_commit`; resumed worktree children
also carry `series_base_commit` (all are `null` when not applicable; see [Failure classes](#failure-classes),
[Hard timeout](#hard-timeout), [implement, diff, and apply](#implement-diff-and-apply),
[resume](#resume), and
[cancel, tail, debug, cleanup, and doctor](#cancel-tail-debug-cleanup-and-doctor) above). Every
writer of `status.json` — the worker's running/terminal writes, `cancel`, and `cleanup`'s
thread-id scrub — serializes through a per-job lock (`<job_dir>\.lock\`) so two writers can
never race each other; a lock that cannot be acquired within its timeout surfaces as wrapper exit
`21` rather than corrupting the file.

For `submit --resume`, `parent_job_id` and the inherited `codex_thread_id` are present from the
initial `created` status. This status metadata is how the worker recognizes a resumed child and
builds `codex exec … resume <thread-id> -`, targeting `worktree_repo` when present; no resume flag is added to the worker launch line.
As with plain submit, only `--model`/`--effort` travel on that launch line and neither enters
`status.json`.

## Repository layout

```text
ccodex.ps1          # dispatcher: parses args, intercepts help, and implements run/submit/status/
                    #   wait/read/review/resume/cancel/diff/apply/tail/debug/cleanup/doctor/worker
ccodex.cmd          # PATH shim: forwards to `pwsh -File ccodex.ps1`
install.ps1         # installs to %USERPROFILE%\.local\bin\ccodex\, ~\.claude\commands\ccodex.md,
                    #   ~\.claude\commands\ccodex\<name>.md (the /ccodex:<name> commands),
                    #   ~\.claude\rules\ccodex-delegation.md, and ~\.claude\skills\ccodex\SKILL.md
templates/          # worker-prompt contract, the /ccodex Claude command, the per-function
                    #   claude-commands/ set (/ccodex:review, :ask, :implement, :resume, :jobs,
                    #   :doctor, :cleanup), the delegation rule template, and the agent skill
lib/                # single-responsibility PowerShell modules, dot-sourced by ccodex.ps1
                    #   (includes lib/Help.ps1 as the command/help inventory,
                    #   lib/Worktree.ps1 for --access worktree jobs, and
                    #   lib/Resume.ps1 for ccodex resume)
tests/              # plain PowerShell assertion scripts (no Pester — see the Phase 1 plan)
docs/               # design spec and phase plans
```

### Module reference

Each dispatcher subcommand and `lib/` module, verified against the current code:

- `ccodex.ps1` — dispatcher for `run`, `submit`, `status`, `wait`, `read`, `review`, `resume`,
  `cancel`, `diff`, `apply`, `tail`, `debug`, `cleanup`, `doctor`, and the internal `worker`
  subcommand; `run`/`submit` accept `--mode` (including `implement`), `--access` (including
  `worktree`), `--repo`, `--prompt-file`, a positional task argument, or a piped/redirected-stdin
  task; `review` accepts a diff selector (`--range`/`--staged`/`--working`), `--path`, `--intent`,
  `--focus`, `--embed-diff`, and `--repo`; `resume <job_id>` accepts the same prompt sources as
  `run` (minus `--repo`, which is always inherited from the parent) plus `--hard-timeout-sec`;
  `submit --resume <job_id>` is the detached async follow-up form, accepts plain submit's task
  sources, and inherits the parent context;
  `run`/`submit`/`review`/`resume` all additionally accept the optional `--model`/`--effort`
  Codex knobs (see [run and submit](#run-and-submit));
  `diff`/`apply` take a worktree job id (`diff` also `--stat`/`--name-only`; `apply` also
  `--allow-untracked`/`--message`/`--reset-author`); `cancel`/`tail`/`debug` take a job id (`tail` also
  accepts `--lines`); `cleanup` accepts `--older-than`,
  `--thread-ttl`, `--dry-run`, `--include-stalled`, `--scrub-thread-ids`, and `--repo`; `doctor`
  accepts `--no-smoke` and `--repo`
- `lib/Help.ps1` — canonical ordered command metadata plus top-level/per-command help rendering;
  also supplies the unknown-command inventory used by the dispatcher
- `ccodex.cmd` — `PATH` shim that forwards to `pwsh -File ccodex.ps1`
- `install.ps1` — copies `ccodex.ps1` + `lib/` to `%USERPROFILE%\.local\bin\ccodex\`, writes the
  `ccodex.cmd` shim there, installs the default worker-prompt template to
  `%APPDATA%\ccodex\templates\worker-prompt.md`, installs the `/ccodex` Claude command to
  `%USERPROFILE%\.claude\commands\ccodex.md` and the per-function `templates/claude-commands/*.md`
  set to `%USERPROFILE%\.claude\commands\ccodex\<name>.md` (surfaced as `/ccodex:<name>`),
  installs the delegation policy rule to `%USERPROFILE%\.claude\rules\ccodex-delegation.md`, and
  installs the agent skill to `%USERPROFILE%\.claude\skills\ccodex\SKILL.md`. Re-running it is
  the upgrade path: the script-dir copy and the `/ccodex:<name>` command set are **mirrored**,
  not merged — the new script tree is staged at `<dest>.staging` and swapped in whole (the old
  install is only removed once the complete new copy exists), and the namespaced command dir is
  emptied of `*.md` first — so files an older version installed but the new one no longer ships
  (a renamed `lib/` module, a removed command) never survive an upgrade, and a failed copy never
  leaves a half-installed CLI. Because the mirror deletes its destination, the installer refuses
  a `-InstallDir` whose `ccodex\` script dir would collide with the job-state root
  (`%LOCALAPPDATA%\ccodex`) or replace an existing non-empty directory lacking a `ccodex.ps1`
  marker (all regression-guarded by `tests/Install.tests.ps1`)
- `lib/Paths.ps1` — global state-root path helpers and `repo_key` hashing
- `lib/Repo.ps1` — `--repo` override / `git rev-parse --show-toplevel` resolution
- `lib/JobId.ps1` — job id generation and atomic job-directory reservation
- `lib/PromptSource.ps1` / `lib/StdinTimeout.ps1` — prompt-source precedence (`--prompt-file` /
  positional task / piped or redirected stdin) and bounded-timeout stdin reading
- `lib/WorkerPrompt.ps1` — worker-prompt template resolution and rendering
- `lib/ModeAccess.ps1` — mode/access validation and `codex exec` argument construction
- `lib/JobStore.ps1` — job file writers (`prompt.md`, `command.txt`, `debug.json`, `status.json`,
  `worker-complete.json`)
- `lib/CodexInvoke.ps1` — `codex exec` process invocation, event/stderr log capture
- `lib/ResultValidation.ps1` — `result.md` validation into status + wrapper exit code
- `lib/JobIndex.ps1` — global job-id → job-dir lookup, callable from any directory
- `lib/JobStatus.ps1` — status.json read, worker liveness check, narrowly-gated orphan
  reconciliation, and `Get-CcodexJobHealth` (derives `ok`/`stale` from `last_heartbeat_at`,
  never stored itself)
- `lib/Worker.ps1` — the internal worker entrypoint (`ccodex worker --job-id <id>`); runs the same
  Codex flow as `run` but reads the prepared job directory instead of taking task text on the
  command line, and re-stamps `last_heartbeat_at` on a fixed cadence while Codex runs
- `lib/Detach.ps1` — detached-process launch (CIM `Win32_Process.Create` in production,
  `Start-Process` for tests) plus a PID-aware startup sentinel so `submit` can report exit `23`
  quickly if the worker exits before stamping startup, or after the configured window if a live
  worker never starts; also process-tree termination (`Stop-CcodexProcessTree`) used by `cancel`
- `lib/Config.ps1` — `.ccodex/ccodex.json` `delegation` section reader, with per-key defaults and
  enum/type validation
- `lib/UserConfig.ps1` — `%APPDATA%\ccodex\config.json` `retention` section reader (`jobs_days`/
  `thread_ttl_days`), with per-key defaults and non-negative-integer validation
- `lib/JobLock.ps1` — the per-job advisory lock (`<job_dir>\.lock\`) every status.json writer
  (worker, `cancel`, `cleanup`'s thread-id scrub) routes through; stale-lock breaking after a
  10-minute owner-dead window; lock acquisition failure surfaces as wrapper exit `21`
- `lib/Cleanup.ps1` — the `ccodex cleanup` retention-sweep engine: deletes aged terminal jobs
  (index entry first, then the job directory), removes dangling index entries, optionally
  reconciles and sweeps stalled jobs (`--include-stalled`), scrubs `codex_thread_id` on
  retained-but-expired jobs (`--scrub-thread-ids`) under the per-job lock, and removes a deleted
  job's worktree via `lib/Worktree.ps1` and sweeps any dangling worktree directory whose job dir
  is already gone
- `lib/ReviewPrompt.ps1` — composes the `ccodex review` task text (self-diff and `--embed-diff`
  forms) from a diff selector, paths, intent, and focus
- `lib/Worktree.ps1` — the `--access worktree` lifecycle: `New-CcodexJobWorktree` creates a
  detached git worktree at the main repo's current HEAD under
  `%LOCALAPPDATA%\ccodex\worktrees\<job_id>\`; `New-CcodexResumeWorktree` creates a distinct
  continuation worktree at an explicit parent snapshot; `Complete-CcodexJobWorktree` stages and commits
  whatever the worker left behind (as `ccodex-worker <ccodex@local>`) into one deterministic
  snapshot commit after the process exits; `Remove-CcodexJobWorktree` tears the worktree down
  (best-effort when the main repo itself is already gone)
- `lib/Resume.ps1` — the `ccodex resume` lifecycle: `Get-CcodexResumeContext` resolves a parent
  job id to its Codex thread id and inherited mode/access/repo, enforcing the resume preconditions
  and exposing frozen worktree context when applicable; `Build-CcodexResumeArgs`
  splices `exec resume <thread_id>` into the same argument shape `run` uses, so result validation
  and failure classification never fork
- `templates/worker-prompt.md` — default worker-prompt contract template
- `templates/claude-command-ccodex.md` — the `/ccodex` Claude command template (includes `review`,
  job-management, delegated-implementation `implement` → `diff` → `apply`, and multi-turn
  `resume` guidance)
- `templates/claude-commands/*.md` — the per-function Claude command set, installed to
  `~/.claude/commands/ccodex/<name>.md` and surfaced as `/ccodex:<name>`: `review` (scoped
  post-change review, `--background` submits it), `ask` (brainstorm/second opinion), `implement`
  (worktree-isolated edit with the diff-before-apply gate), `resume` (multi-turn follow-up),
  `jobs` (status/wait/read/tail/cancel/debug), `doctor`, and `cleanup`
- `templates/claude-rule-ccodex-delegation.md` — the always-on delegation policy rule, installed
  to `~/.claude/rules/ccodex-delegation.md` (includes the never-auto-apply `implement`/`diff`/
  `apply` guidance and the resume-on-follow-up pattern)
- `templates/claude-skill-ccodex.md` — the `ccodex` Claude Code agent skill, installed to
  `~/.claude/skills/ccodex/SKILL.md`, teaching any session how and when to use every phase's
  commands (discovered at runtime via `ccodex help`'s exit-0 canonical command list)
- A full plain-PowerShell test suite under `tests/` (no Pester; see [Testing](#testing) below)

`tmux` was considered as an execution backend but is superseded by the native detached backend
(CIM `Win32_Process.Create`) for async execution — see Phase 2a in
[Roadmap and status history](#roadmap-and-status-history).

## Testing

No Pester dependency. Each `lib/*.ps1` module has a matching `tests/*.tests.ps1` file that is a
plain PowerShell script — run it directly and check its exit code:

```powershell
pwsh -NoProfile -File tests/Paths.tests.ps1
```

For the full-suite run recipe, the test harness (`tests/TestHelpers.ps1`,
`tests/fixtures/fake-codex.ps1`, `tests/fixtures/stub-worker.ps1`), and regression-guarded
pitfalls to check before changing `ccodex.ps1` or `lib/`, see
[`2026-07-07-ccodex-dev-notes.md`](2026-07-07-ccodex-dev-notes.md).

## Roadmap and status history

`ccodex` was built in phases; all planned phases are complete:

- **Phase 1 — Synchronous CLI:** `ccodex run`, prompt transport, job files, install script. *(done)*
- **Phase 2a — Async result channel:** `submit`, `status`, `wait`, `read`, internal `worker`, native detached backend with a startup sentinel. *(done)*
- **Phase 3 — Claude slash command:** `/ccodex` installed to `~\.claude\commands\ccodex.md`. *(done)*
- **Phase 2c — Scoped review + delegation policy:** `ccodex review`, `.ccodex/ccodex.json`
  delegation config, `~\.claude\rules\ccodex-delegation.md`. *(done)*
- **Phase 2b — Job management:** retention config, per-job locks, `cleanup` (including
  `--scrub-thread-ids` for stale session data), `cancel`, heartbeat/health, `tail`, `debug`,
  `doctor`. *(done — [`docs/archive/2026-07-07-ccodex-phase2b-plan.md`](archive/2026-07-07-ccodex-phase2b-plan.md))*
- **Phase 4 — Worktree isolation:** `--mode implement` (default `--access worktree`) runs
  edit-capable workers in an isolated git worktree under the state root, with explicit
  `ccodex diff`/`ccodex apply` and worktree-aware `cleanup`.
  *(done — [`docs/archive/2026-07-07-ccodex-phase4-plan.md`](archive/2026-07-07-ccodex-phase4-plan.md))*
- **Phase 5 — Multi-turn advisor:** `ccodex resume <job_id>` continues a finished job's Codex
  session for follow-up discussion, always as a brand-new job carrying `parent_job_id` lineage.
  *(done — [`docs/archive/2026-07-07-ccodex-phase5-plan.md`](archive/2026-07-07-ccodex-phase5-plan.md))*

See [`2026-07-03-ccodex-adapter-design.md`](2026-07-03-ccodex-adapter-design.md) for the full
rationale, non-goals, and phase-by-phase verification criteria, and
[`2026-07-07-ccodex-handoff.md`](2026-07-07-ccodex-handoff.md) for the current development
handoff (verified state, verification backlog history, and the full document index) —
including live-evidence notes (gold-seal round-trip, real quota-exhaustion classification, and
the Phase 4/5 live smoke tests).
