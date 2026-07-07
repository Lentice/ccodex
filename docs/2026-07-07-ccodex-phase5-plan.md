# ccodex Adapter Phase 5 (Multi-Turn Advisor: `resume`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox
> steps; tests via `pwsh -NoProfile -File tests/<name>.tests.ps1` from repo root. Governing design
> section: "Phase 5 multi-turn advisor (`resume`)" (2026-07-07 amendment) in
> `docs/2026-07-03-ccodex-adapter-design.md`. **Prerequisite: Phase 2b complete** (cleanup's
> thread-id scrubbing defines resume-ability's end of life). Independent of Phase 4.

**Goal:** let the caller continue a finished job's Codex session — answer Codex's clarifying
question, push back on a review finding, iterate on a brainstorm — as a NEW ccodex job:
`<follow-up> | ccodex resume <job_id>` runs `codex exec resume <codex_thread_id>` with the
parent's mode/access/repo, full job artifacts, and the normal result channel.

**Verified foundation:** `codex exec resume <SESSION_ID> [PROMPT]` exists in codex-cli 0.142.5
(help text confirmed 2026-07-04); every job already records `codex_thread_id` in `status.json`
(captured from the `thread.started` event on success AND failure), and the live gold-seal run
confirmed capture works (thread id `019f3318-...` recorded 2026-07-06).

## Global Constraints

- All prior-phase constraints bind (suite green per task; UTF-8 no BOM; plain tests; `$args`
  parsing; append-only status fields; JSONL never on parent stdout; exact commit messages, no
  trailers; no `.superpowers/` commits).
- No new exit codes. Preconditions map to the existing contract: parent not found → `3`; parent
  not terminal → `4`; thread id absent/scrubbed → `2` (usage-class: the caller must start a
  fresh run); expired-on-Codex-side → normal failure `10` with the NEW
  `failure_reason = "thread_expired"`.
- A resumed job is a REAL job: fresh job id + directory + prompt.md + full artifact set + index
  entry; `status.json` additionally records `parent_job_id` and `codex_thread_id` (its own —
  Codex may return the same or a new thread id for the continued session; store what the events
  say).
- `resume` is synchronous (run-like). An async variant (`resume --submit`) is explicitly out of
  scope for this phase — note it in the README roadmap only if asked.
- `--last`/guessing is deliberately NOT exposed: sessions are addressed only through a ccodex
  job id.
- The follow-up prompt goes through the SAME prompt-source machinery as `run` (pipe /
  `--prompt-file` / positional; same precedence and stdin-timeout rules). The worker-prompt
  contract template is NOT re-prepended on resume — the session already carries it; `prompt.md`
  for the resumed job contains exactly the follow-up text.
- Real codex calls only in the final task's live smoke.

## File Structure (additions)

```text
lib/Resume.ps1            # parent lookup/preconditions + resume argument building
tests/Resume.tests.ps1
tests/ResumeE2E.tests.ps1
```

---

### Task 1: Parent resolution, preconditions, and resume argument building

**Files:** create `lib/Resume.ps1`, `tests/Resume.tests.ps1`; modify `lib/FailureClassify.ps1`
(one new signature class); extend `tests/FailureClassify.tests.ps1`.

**Interfaces:**
- `Get-CcodexResumeContext([Parameter(Mandatory)][string]$ParentJobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ ParentJobId; ThreadId; Mode; Access; Repo }`
  — index lookup (missing → throw with the standard not-found message; callers map 3); parent
  status must be terminal (`done`/`failed`/`timed_out`/`cancelled` → else throw a distinct
  not-terminal message; callers map 4); `codex_thread_id` null/absent → throw
  `"ccodex: job '<id>' has no codex thread id (absent or scrubbed by cleanup) - start a fresh run."`
  (callers map 2). Returns the parent's mode/access/repo verbatim from its status.json.
- `Build-CcodexResumeArgs([Parameter(Mandatory)][string]$ThreadId, [Parameter(Mandatory)][string]$Access, [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$ResultPath) -> string[]`
  — exactly the Phase-1 argument shape with the resume subcommand spliced in:
  `--ask-for-approval never exec resume <ThreadId> --sandbox <map(Access)> --json --color never
  -C <RepoRoot> --output-last-message <ResultPath> -`. Reuse `ConvertTo-CcodexSandboxFlag`; do
  not fork a second flag-mapping path.
- `Get-CcodexFailureReason` gains a FIFTH class checked FIRST: `thread_expired` (signatures:
  `session not found`, `thread not found`, `no session`, `conversation not found`,
  case-insensitive, same stderr-tail + error-event sources). Hint line:
  `"Codex session expired or was pruned - start a fresh ccodex run."`.

- [ ] Step 1: failing tests — context: terminal done parent with thread → full context; running
  parent → not-terminal throw; scrubbed thread (null) → distinct throw; unknown id → not-found
  throw; failed parent WITH thread → allowed (answering a failure follow-up is legitimate).
  Args: exact array equality against the spliced shape for read-only and workspace access.
  Classification: each new signature → `thread_expired`; precedence over quota when both
  present; existing four classes' assertions unchanged.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex resume context, argument building, and thread-expired class`

---

### Task 2: `ccodex resume` command

**Files:** modify `ccodex.ps1` (dispatcher + a resume-shaped variant of the run flow),
`lib/JobStore.ps1` (optional `-ParentJobId`, append-only); extend `tests/JobStore.tests.ps1`;
create the command-level sections of `tests/Resume.tests.ps1`.

**Interfaces:**
- `Invoke-CcodexResume([Parameter(Mandatory)][string]$ParentJobId, <the same prompt-source params as Invoke-CcodexRun>, [string]$CodexPath, [string]$LocalAppDataRoot = $env:LOCALAPPDATA, [string]$AppDataRoot = $env:APPDATA, [int]$HardTimeoutSec = 0) -> [pscustomobject]{ WrapperExitCode; Stdout; JobDir; JobId; Message }`
  — flow: `Get-CcodexResumeContext` (its three throw classes map to 3/4/2 respectively — match
  on the message shapes established in Task 1); read the follow-up via the standard
  prompt-source machinery (usage errors → 2 with the same messages as run); reserve a new job
  (mode = parent's mode) + index entry; write `prompt.md` = the follow-up text only;
  initial + terminal status carry `parent_job_id` and the parent-inherited mode/access/repo;
  execute through `Invoke-CcodexJobExecution` with the Task-1 resume args (pass a prebuilt
  argument array — extend the core with an optional `-CodexArgs` override rather than forking
  the pipeline; when present the core skips `Build-CcodexCodexArgs`); result/validation/
  classification identical to run (thread_expired now surfaces via failure_reason).
- Dispatcher: `resume <job_id> [prompt sources] [--hard-timeout-sec <n>]` + hidden
  `--state-root`/`--codex-path`; supported-commands message updated. Pipeline stdin capture
  mirrors run/submit exactly.

- [ ] Step 1: failing tests — fixture-backed (fake-codex answers regardless of the resume argv;
  extend the fixture ONLY if argv parsing requires it, additively): happy path (parent done job
  seeded with thread id → resume exits 0, child status has parent_job_id + parent's mode/access
  + its own thread id captured, prompt.md is exactly the follow-up, result printed); command.txt
  contains `exec resume <thread>`; parent running → 4; parent scrubbed → 2 with the scrub
  message; unknown parent → 3; multiple prompt sources → 2; shell-level dispatcher case (piped
  follow-up through `pwsh -File ccodex.ps1 resume <id> --state-root ... --codex-path ...`) →
  exit 0.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite (RunCommand/SubmitCommand/
  AsyncE2E regression gates untouched).
- [ ] Step 5: commit — `feat: add ccodex resume for multi-turn codex sessions`

---

### Task 3: Lineage surfacing in status/debug

**Files:** modify `ccodex.ps1` (`Invoke-CcodexStatusCommand`, `Invoke-CcodexDebugCommand` if
Phase 2b landed it); extend `tests/StatusWaitRead.tests.ps1`.

- `status` line for a job with `parent_job_id` appends ` parent=<parent_job_id>`; `debug` (when
  present) prints the parent line and, for parents, nothing (no reverse index — children are
  discoverable via the index scan cleanup already does; a `children=` line is explicitly out of
  scope).

- [ ] Step 1: failing tests — resumed-job fixture → status line carries `parent=`; parentless
  job line unchanged (byte-stable assertions from existing tests keep guarding this).
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: surface ccodex job lineage in status`

---

### Task 4: Guidance, docs, live smoke

**Files:** modify `README.md`, `templates/claude-command-ccodex.md`,
`templates/claude-rule-ccodex-delegation.md`, `templates/claude-skill-ccodex.md` (verify the
resume claims match implemented behavior; fix only inaccuracies — the skill is
availability-gated); re-run `install.ps1`.

- [ ] Step 1: `/ccodex` command + delegation rule gain the follow-up pattern: "if Codex's answer
  is a clarifying question, or a finding needs pushback/refinement, answer with
  `<reply> | ccodex resume <job_id>` instead of starting over; if it exits 2 with the
  scrubbed-thread message or fails with `failure_reason=thread_expired`, start a fresh run."
  README per CLAUDE.md: Phase 5 done — `resume` usage + preconditions + exit mapping + the
  thread-ttl/cleanup interplay; Quick-reference row ("continue a discussion with the same Codex
  session"); Roadmap updated. Verify every claim against the code.
- [ ] Step 2: live smoke (two real codex calls, evidence in the task report only):
  `"Reply with exactly the word SEED." | ccodex run --mode brainstorm --repo <this repo>` →
  capture job id; `"Now reply with exactly the word CONTINUED." | ccodex resume <job id>` →
  expect stdout `CONTINUED`, exit 0, child status carrying parent_job_id + thread id. Also one
  negative: `ccodex resume <job id of a job whose thread was scrubbed via cleanup
  --scrub-thread-ids --thread-ttl 0d>` → exit 2 with the scrub message (uses cleanup from 2b;
  do this against a temp state root, not the real one). DONE_WITH_CONCERNS with evidence if the
  environment blocks the live part.
- [ ] Step 3: install.ps1 re-run + byte-match verify; FULL suite green.
- [ ] Step 4: commit — `docs: document ccodex resume and multi-turn guidance`

---

## Self-Review

| Design requirement | Covered by |
|---|---|
| Resume = new job with parent_job_id, inherited mode/access/repo | Task 2 |
| `codex exec resume <thread>` argument splice, no forked flag mapping | Task 1 |
| Preconditions → 3 / 4 / 2 exactly | Tasks 1–2 |
| `thread_expired` classification + hint | Task 1 |
| No worker-prompt re-prepend; prompt.md = follow-up only | Task 2 |
| No `--last`; job-addressed sessions only | Tasks 1–2 (never built) |
| Cleanup scrub ends resume-ability with a clear message | Task 2 tests + Task 4 negative smoke |
| Lineage visible in status | Task 3 |
| Claude guidance: clarifying-question → resume pattern | Task 4 |
| Live continuation verified | Task 4 |
