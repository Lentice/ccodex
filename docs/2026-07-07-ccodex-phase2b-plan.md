# ccodex Adapter Phase 2b (Job Management: cleanup, locks, cancel, tail, debug, doctor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (fresh
> implementer per task, task-scoped review, fix loops, ledger at `.superpowers/sdd/progress.md`).
> Checkbox steps. Tests run with cwd = repo root: `pwsh -NoProfile -File tests/<name>.tests.ps1`.
> Governing design sections: "Retention, cleanup, and remaining-phase decisions (2026-07-07)" and
> the Phase-2 `status`/lock rules in `docs/2026-07-03-ccodex-adapter-design.md`.

**Goal:** make background jobs operable and the global state root maintainable: user-level
retention config, per-job locks (the second-writer gate), `ccodex cleanup` (delete aged terminal
jobs + dangling indexes, scrub stale `codex_thread_id`), `ccodex cancel` (identity-checked
process-tree termination), worker heartbeats with derived `health`, `ccodex tail`, `ccodex debug`,
and `ccodex doctor` (delegating to the built-in `codex doctor`).

**Architecture:** new single-responsibility libs — `lib/UserConfig.ps1`, `lib/JobLock.ps1`,
`lib/Cleanup.ps1` — plus dispatcher cases in `ccodex.ps1` and small extensions to
`lib/CodexInvoke.ps1` (heartbeat loop) and `lib/JobStatus.ps1` (health derivation). Existing
status writers (worker terminal write, orphan reconciliation) are re-routed through the lock.

## Global Constraints

- All Phase 1/2a/2a.1/2c constraints still bind: full suite green after every task (every
  `tests/*.tests.ps1` prints `0 failed`); UTF-8 without BOM; plain assertion tests (no Pester);
  `ccodex.ps1` stays a plain script using the existing `$args` parsing helpers
  (`Get-CcodexArgValue`/`Get-CcodexArgValues`); raw Codex JSONL never on parent stdout; job state
  only under the (test-overridable) state root; append-only `status.json` fields.
- Wrapper exit codes after this phase: `0/2/3/4/10/11/12/20/21/22/23/24`. `21` = per-job lock
  acquisition timed out. `22` = `wait` observed a terminal `cancelled` job (analogous to
  10/11/24). `cancel` itself exits `0` on success AND on the terminal-job no-op.
- **Lock discipline:** once Task 2 lands, every `status.json` WRITE goes through the lock:
  worker's running/terminal writes, orphan reconciliation's rewrite, cancel, and cleanup's scrub.
  Readers never lock. Lock acquisition timeout 10 s → throw → callers map to exit `21` (except
  the worker, which retries once then fails the job as `12` with evidence). Stale-lock breaking:
  only when owner pid is dead OR its start time mismatches owner.json, AND the lock is older than
  10 minutes.
- New status fields (append-only): `last_heartbeat_at`, `health` is NEVER stored — it is derived
  at read time by `status`/`debug`. `cancelled_at` is stored by cancel.
- Tests never touch the real user profile / `%APPDATA%` / `%LOCALAPPDATA%` (temp roots via
  existing hidden flags; user-config reader takes an explicit path in tests). Real codex calls
  only where a step explicitly says so (Task 9 doctor smoke).
- Cleanup deletes ONLY terminal jobs (plus `--include-stalled` reconciliation, below); it must
  never delete or rewrite a job younger than the threshold or one whose worker is alive.
- Git: one commit per task, exact message, NEVER any Co-Authored-By or trailer; never
  `--no-verify`; never commit `.superpowers/`.

## File Structure (additions)

```text
lib/UserConfig.ps1        # %APPDATA%\ccodex\config.json reader (retention section)
lib/JobLock.ps1           # per-job .lock/ directory acquire/release/stale-break
lib/Cleanup.ps1           # sweep/age/delete/dangling/scrub engine
tests/UserConfig.tests.ps1
tests/JobLock.tests.ps1
tests/Cleanup.tests.ps1
tests/CancelCommand.tests.ps1
tests/TailDebug.tests.ps1
tests/Doctor.tests.ps1
```

---

### Task 1: User-level retention config reader

**Files:** create `lib/UserConfig.ps1`, `tests/UserConfig.tests.ps1`.

**Interfaces:**
- `Get-CcodexUserConfig([string]$AppDataRoot = $env:APPDATA) -> [pscustomobject]` with a
  `retention` property carrying exactly: `jobs_days` (int, default 14), `thread_ttl_days` (int,
  default 30). Reads `<AppDataRoot>\ccodex\config.json`; missing file/section/keys → per-key
  defaults; malformed JSON or non-numeric/negative values → throw
  `"ccodex: invalid config.json: <detail>"` (callers map to exit 2). Follow `lib/Config.ps1`'s
  existing validation/error-message pattern exactly.

- [ ] Step 1: failing test — defaults (no file), full round-trip, partial section, malformed
  JSON → Assert-Throws with message prefix, negative/non-numeric → Assert-Throws.
- [ ] Step 2: verify red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex user-level retention config reader`

---

### Task 2: Per-job lock and writer re-routing

**Files:** create `lib/JobLock.ps1`, `tests/JobLock.tests.ps1`; modify `ccodex.ps1`
(execution core terminal/running writes), `lib/JobStatus.ps1` (`Update-CcodexOrphanStatus`
rewrite branch); extend `tests/JobStatus.tests.ps1`.

**Interfaces:**
- `Lock-CcodexJob([Parameter(Mandatory)][string]$JobDir, [int]$TimeoutSec = 10, [string]$CommandName = 'unknown') -> [pscustomobject]{ LockPath }`
  — atomically creates `<JobDir>\.lock\` (New-Item -ErrorAction Stop as the atomic primitive),
  writes `.lock\owner.json` (pid, process start time ISO `'o'`, command name, hostname,
  acquired_at). On contention: retry every 250 ms until timeout, checking staleness each pass;
  break a stale lock (rules in Global Constraints) by removing the directory and retrying; on
  timeout throw `"ccodex: could not acquire the job lock for '<jobdir>' within <n>s."`.
- `Unlock-CcodexJob([Parameter(Mandatory)][string]$JobDir) -> void` — removes `.lock\` if owned
  by this process (pid + start time match); no-op otherwise.
- Re-route writers: `Invoke-CcodexJobExecution`'s running + terminal status writes and
  `Update-CcodexOrphanStatus`'s rewrite acquire/release the lock (try/finally). Worker maps a
  lock-timeout during its own writes to a `failed`/12 job with evidence (it must not die
  silently); read-side reconciliation maps lock timeout to "skip reconcile this pass, report
  possibly-stale" (never blocks `status`).

- [ ] Step 1: failing tests — acquire/release round-trip; contention (second acquire with 1 s
  timeout while held → Assert-Throws); stale-break (fabricate owner.json with dead pid + old
  acquired_at + old directory timestamp → acquire succeeds); fresh foreign lock is NOT broken;
  owner.json fields present. JobStatus: reconciliation still works under the lock; a held lock
  makes reconciliation skip with PossiblyStale rather than throw.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite (regression gates:
  RunCommand/AsyncE2E/Worker/SubmitCommand unchanged).
- [ ] Step 5: commit — `feat: add ccodex per-job locks and route status writers through them`

---

### Task 3: `ccodex cleanup`

**Files:** create `lib/Cleanup.ps1`, `tests/Cleanup.tests.ps1`; modify `ccodex.ps1` (dispatcher
`cleanup` case + supported-commands message).

**Interfaces:**
- `Invoke-CcodexCleanup([int]$OlderThanDays, [Nullable[int]]$ThreadTtlDays, [string]$RepoFilter, [bool]$DryRun, [bool]$IncludeStalled, [bool]$ScrubThreadIds, [string]$StateRoot = $env:LOCALAPPDATA, [string]$AppDataRoot = $env:APPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Deleted; ScrubbedCount; SkippedCount; FailedCount }`
  — resolution: explicit params → user config → defaults. Engine:
  1. Enumerate `<stateroot>\ccodex\jobs\<repo_key>\<job_id>\` directories (tree scan, not index).
     `--repo` narrows to that repo's `repo_key` (via `Get-CcodexRepoKey`).
  2. Per job: read status (tolerant reader). Terminal + end-timestamp older than threshold →
     delete (index entry first, then dir). Non-terminal: skip (reported), unless
     `IncludeStalled` → run `Update-CcodexOrphanStatus` first and re-evaluate; still non-terminal
     → skip. Unreadable status + directory older than threshold → treat as failed-stale and
     delete (evidence gone anyway); younger → skip.
  3. Dangling index entries (`index\*.json` whose job_dir is missing) → remove.
  4. `ScrubThreadIds`: for RETAINED terminal jobs with non-null `codex_thread_id` older than
     thread-ttl → under the job lock, atomically rewrite status.json with
     `codex_thread_id = $null` only.
  5. `DryRun`: same walk, no mutations; each candidate line: `<job_id> <status> age=<days>d
     size=<kb>KB -> delete|scrub`.
  6. Best-effort: failures are counted + reported per item; exit 12 if `FailedCount > 0`, else 0.
- Dispatcher: `cleanup` with `--older-than <Nd|Nh>` (parse `^\d+[dh]$`, convert h→fractional days;
  bad syntax → exit 2), `--thread-ttl <Nd>`, `--repo <path>`, `--dry-run`, `--include-stalled`,
  `--scrub-thread-ids`, plus hidden `--state-root`. Update the default-case supported-commands
  message (now includes cleanup).

- [ ] Step 1: failing tests — fixture state root with: old done job (deleted; index gone; dir
  gone), young done job (kept), old running-alive job (kept + reported), old running-dead-with-
  evidence + `--include-stalled` (reconciled then deleted), dangling index (removed), old
  terminal job with thread id + `--scrub-thread-ids` (retained but thread id nulled, other
  fields byte-stable), `--dry-run` (nothing changes, candidates listed), bad `--older-than`
  syntax via dispatcher → exit 2, summary line fields.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex cleanup with retention and thread-id scrubbing`

---

### Task 4: `ccodex cancel`

**Files:** modify `ccodex.ps1`; create `tests/CancelCommand.tests.ps1`.

**Interfaces:**
- `Invoke-CcodexCancelCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3. Under the job lock (timeout → 21): re-read status; terminal → no-op message
  ("already <status>"), exit 0; `running` + worker alive (backend_id pid/start-time match) →
  `taskkill /PID <pid> /T /F`, poll process death (up to 10 s), write `cancelled` +
  `cancelled_at` (+ `wrapper_exit_code` untouched/null), exit 0, print one confirmation line;
  `running` + worker dead → release the lock path and run the normal orphan reconciliation
  instead (result reported; exit 0); `created` (never started) → mark `cancelled` directly.
- `wait` mapping: a terminal `cancelled` job → concise status line, exit `22` (add to
  `Invoke-CcodexWaitCommand`); `read` on cancelled behaves by existing rules (result present → 0,
  absent → 11). `status` line for cancelled shows codes as usual.

- [ ] Step 1: failing tests — fixture-backed: cancel a live fake worker mid-`CCODEX_FAKE_DELAY_MS`
  sleep (submit via startprocess mechanism; cancel; assert process tree dead, status
  `cancelled`+`cancelled_at`, artifacts preserved); cancel done job → no-op exit 0; cancel
  unknown → 3; cancel running-dead-with-evidence → reconciled (done/failed per evidence) not
  cancelled; `wait` on cancelled → 22; dispatcher wiring + supported-commands message.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex cancel with identity-checked tree termination`

---

### Task 5: Worker heartbeat and derived health

**Files:** modify `lib/CodexInvoke.ps1`, `ccodex.ps1` (worker plumbing), `lib/JobStatus.ps1`
(health derivation), `lib/JobStore.ps1` (optional `-LastHeartbeatAt`); extend
`tests/CodexInvoke.tests.ps1`, `tests/JobStatus.tests.ps1`, `tests/StatusWaitRead.tests.ps1`.

**Behavior:**
- `Invoke-CcodexCodexProcess` gains `[scriptblock]$OnHeartbeat = $null` and reworks its wait into
  a 1 s `WaitForExit(1000)` poll loop (this loop ALSO carries the existing HardTimeoutMs check —
  refactor, behavior-identical for timeout semantics). Every 30 loop passes it invokes
  `$OnHeartbeat` (best-effort; exceptions swallowed).
- The worker passes an `$OnHeartbeat` that rewrites its own status.json under the job lock with
  `last_heartbeat_at = now('o')` (all other fields preserved). `run` (sync) passes none — the
  caller is watching.
- `Get-CcodexJobHealth([pscustomobject]$Status, [int]$StaleAfterSec = 90) -> 'ok'|'stale'|$null`
  in `lib/JobStatus.ps1`: null unless status is `running`; `stale` when
  `last_heartbeat_at` is absent or older than the threshold (fallback for absent: `started_at`);
  `status`/`debug` append ` health=<v>` to their running-job lines (replacing today's
  possibly-stale wording for the heartbeat-based case; the reconciliation `PossiblyStale` flag
  keeps its existing wording).

- [ ] Step 1: failing tests — CodexInvoke: heartbeat scriptblock invoked ≥2 times during a 3 s
  fixture run with a 1-pass heartbeat interval override (add `[int]$HeartbeatEveryPasses = 30`
  param for testability); hard-timeout behavior unchanged (existing assertions stay green).
  JobStatus: health derivation matrix (running+fresh → ok; running+old → stale; done → null).
  StatusWaitRead: status line shows `health=ok|stale` for running jobs.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex worker heartbeat and derived health`

---

### Task 6: `ccodex tail`

**Files:** modify `ccodex.ps1`; create `tests/TailDebug.tests.ps1` (tail section).

**Interfaces:**
- `Invoke-CcodexTailCommand([Parameter(Mandatory)][string]$JobId, [int]$Lines = 40, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3. Prints a `== stderr.log (last N) ==` block then
  `== codex-events.jsonl (last N) ==` block. Implementation reads only the file tails
  (read last ≤64 KB via stream seek, then split lines) — never the whole file. Missing files →
  `(absent)` placeholder. Exit 0. Flag `--lines <n>` (validate positive int → else 2).

- [ ] Step 1: failing tests — fixture job dir with >N lines in both files (assert exactly the
  last N and the 64 KB seek path via a >64 KB file), missing files, unknown id → 3, bad
  `--lines` → 2.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex tail`

---

### Task 7: `ccodex debug`

**Files:** modify `ccodex.ps1`; extend `tests/TailDebug.tests.ps1` (debug section).

**Interfaces:**
- `Invoke-CcodexDebugCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3. Performs the same narrow orphan reconciliation `status` does, then prints a
  compact multi-line diagnosis: job id, status (+health for running), mode/access/backend,
  repo, created/started/finished/terminated/cancelled timestamps (only those present),
  backend_id + live/dead verdict, codex_exit_code/wrapper_exit_code, failure_reason (+ the
  matching hint line), codex_thread_id presence (id shown, or "absent/scrubbed"),
  result.md present/size, last 5 stderr lines, job dir path, and one "next command"
  recommendation (`wait` if running, `read` if done, `tail` if failed, `resume` pointer once
  Phase 5 exists — emit only commands that exist). Exit 0.

- [ ] Step 1: failing tests — running-alive fixture (shows health + wait recommendation),
  failed-with-reason fixture (shows failure_reason + hint + tail lines), done fixture,
  unknown → 3. Assert key lines by pattern, not whole-output equality.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex debug`

---

### Task 8: `ccodex doctor`

**Files:** modify `ccodex.ps1`; create `tests/Doctor.tests.ps1`.

**Interfaces:**
- `Invoke-CcodexDoctorCommand([bool]$NoSmoke, [string]$CodexPath, [string]$StateRoot = $env:LOCALAPPDATA, [string]$AppDataRoot = $env:APPDATA, [string]$RepoOverride) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — check list, each printed as `ok|FAIL <name>: <detail>`:
  1. `codex` resolvable to a launchable `.cmd`/`.exe` (`Resolve-CcodexCodexPath`) + `codex
     --version` output captured.
  2. Built-in delegation: run `codex doctor` (through the launch-plan machinery), capture its
     exit code + last line; nonzero → FAIL with pointer to its output (full output into stdout
     block, not swallowed).
  3. State root writable (create+delete a probe file under `jobs\`), templates present
     (worker-prompt at the APPDATA path), index/jobs consistency (counts of dangling indexes and
     unindexed job dirs, informational).
  4. Unless `NoSmoke`: one live smoke through the normal run pipeline (`"Reply with exactly the
     word OK." → run --mode review` against `--repo` or the current repo), asserting exit 0 +
     result `OK`.
  - Exit 0 when every check passed (informational counts never fail it); exit 10 if the smoke
    failed; exit 12 if any environment check failed; usage errors 2.
- Dispatcher: `doctor [--no-smoke] [--repo <path>]` + hidden `--codex-path`/`--state-root`.

- [ ] Step 1: failing tests — fixture-injected: all-green path with `--no-smoke` and
  fake `--codex-path` whose `codex doctor`/`--version` are simulated by extending
  `tests/fixtures/fake-codex.ps1` to answer `--version` and `doctor` argv (additive; suite stays
  green); unwritable state root (point at a file, not dir) → FAIL line + exit 12; smoke path
  against the fixture → exit 0 with `OK`.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex doctor with codex-doctor delegation`

---

### Task 9: Phase docs, README, /ccodex + rule updates, live smokes

**Files:** modify `README.md`, `templates/claude-command-ccodex.md`,
`templates/claude-rule-ccodex-delegation.md`, `templates/claude-skill-ccodex.md` (verify the
Phase 2b command claims match implemented behavior; the skill is availability-gated so wording
usually needs no change — fix only inaccuracies); re-run `pwsh -NoProfile -File install.ps1`.

- [ ] Step 1: README — per CLAUDE.md's mandate: move Phase 2b to done; document
  `cleanup`/`cancel`/`tail`/`debug`/`doctor` with examples; exit-code table gains 21/22 rows
  (and marks them active); Quick reference gains cleanup + cancel rows; config.json retention
  schema section; verify every claim against the code. `/ccodex` command + delegation rule gain:
  when a background job must be stopped → `cancel`; periodic hygiene → `cleanup --older-than`
  guidance; `doctor` as the first move on environment-shaped failures (auth/quota/1385-style).
- [ ] Step 2: live smokes (evidence in the task report, NOT tests/): `ccodex doctor` (full,
  including its live smoke) and `ccodex cleanup --dry-run` against the real state root; record
  commands + verbatim output + exit codes. `cancel` is exercised by fixture tests only.
- [ ] Step 3: run install.ps1; verify installed copies byte-match; FULL suite green.
- [ ] Step 4: commit — `docs: document ccodex job management and retention`

---

## Self-Review

| Requirement (design 2026-07-07 section) | Covered by |
|---|---|
| Retention config (`config.json`, 14d/30d defaults, validation) | Task 1 |
| Locks land before the second writer; all writers routed | Task 2 |
| Lock timeout → 21; stale-break rules; readers never block | Task 2 |
| cleanup deletes aged terminal jobs, index-first order, dangling indexes, tree-scan | Task 3 |
| cleanup never touches young/live jobs; `--include-stalled` reconciles first | Task 3 |
| `codex_thread_id` scrubbing under lock (user requirement) | Task 3 |
| `--dry-run`, summary line, best-effort exit 12 | Task 3 |
| cancel: identity-checked tree kill, cancelled_at, no-op on terminal, 22 via wait | Task 4 |
| Heartbeat single-writer + derived health (never stored) | Task 5 |
| tail reads tails only | Task 6 |
| debug compact diagnosis + next-command | Task 7 |
| doctor delegates to `codex doctor` + wrapper checks + smoke | Task 8 |
| README/command/rule accuracy + live evidence | Task 9 |
| Codes 21/22 activate; nothing else new | Tasks 2/4 |
