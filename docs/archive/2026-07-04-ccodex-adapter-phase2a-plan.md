# ccodex Adapter Phase 2a (Async Result Channel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the smallest useful background-delegation loop per the design spec's
"Phase 2 scope amendment (2026-07-04)" (docs/2026-07-03-ccodex-adapter-design.md): `ccodex submit`
returns a job id immediately, an internal `ccodex worker --job-id` executes the same Codex flow as
`run` in a detached native Windows process that survives the submitting process's exit, and
`status` / `wait` / `read` retrieve lifecycle and the final result from any directory. Plus the
Phase 3 user-level `/ccodex` Claude command, which makes both product goals (delegation and
second opinions) callable from any project.

**Architecture:** Reuse Phase 1 libs untouched where possible. New single-responsibility libs:
`lib/JobIndex.ps1` (job lookup via the global index), `lib/JobStatus.ps1` (status read, worker
liveness, narrowly-gated orphan reconciliation), `lib/Worker.ps1` (worker entrypoint logic),
`lib/Detach.ps1` (detached launch + startup sentinel). `ccodex.ps1` gains an extracted execution
core shared by `run` and `worker`, plus `submit`/`status`/`wait`/`read`/`worker` dispatcher cases.

**Tech stack:** PowerShell 7+, CIM (`Invoke-CimMethod Win32_Process Create`) for the production
detached launch (children are parented outside the caller's Job Object by construction — verified
by local probe 2026-07-04), `Start-Process` as the test/fallback mechanism (also verified to
survive parent exit in this environment), the existing fake-codex fixtures for all automated tests.

**Repository:** `D:\Documents\GitHub\ccodex` (this repo). All paths below are relative to it.
Tests run with cwd = repo root: `pwsh -NoProfile -File tests/<name>.tests.ps1`.

## Global Constraints

- Every Phase 1 Global Constraint still binds (PowerShell 7+ only; no Pester — plain assertion
  scripts via `tests/TestHelpers.ps1`; UTF-8 **without BOM** for all wrapper-authored files via
  `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`; raw Codex JSONL only ever to
  `codex-events.jsonl`, never parent stdout; jobs only under the global state root).
- **The full existing Phase 1 suite must stay green after every task.** Tasks that refactor
  `ccodex.ps1`/`lib/JobStore.ps1` are regression-gated: run all `tests/*.tests.ps1` before the
  task's commit, every file must print `0 failed`.
- Wrapper exit codes in 2a: Phase 1's `0/2/10/11/12` plus `3` (job not found), `4` (job exists but
  not terminal — `read` only), `20` (`wait` timeout expired; lifecycle unchanged), `23` (backend
  failed to start or worker did not survive/stamp startup). Codes `21`, `22`, `24` must not be
  produced.
- **Single-writer status discipline; no locks in 2a.** After a successful launch handoff only the
  worker mutates `status.json`, always via `Write-CcodexJsonFileAtomic`. `status`/`wait`/`read`
  are read-only except `Update-CcodexOrphanStatus`, which may rewrite ONLY when all three hold:
  recorded status is `running`, the recorded worker (pid + process start time) is definitely not
  alive, and completion evidence exists (`exit_code.txt`, plus `result.md` presence for the
  success case). Otherwise it must not write and reports "possibly stale" instead. Do NOT
  implement `.lock` directories, `cancel`, `tail`, `debug`, `doctor`, heartbeats, health
  monitoring, or tmux — all Phase 2b+.
- `status.json` gains only append-only fields: `backend`, `backend_id`
  (format `<pid>;<process-start-time UTC ISO-8601 'o'>`), `started_at`, `finished_at`. The 2b
  fields (`health`, `warnings`, pid lists, `command_hash`, heartbeat timestamps, timeout fields,
  `terminated_at`, `cancelled_at`) must not be added.
- `worker` is internal (invoked by `submit`'s detached process), not Claude-facing. Test-support
  flags `--state-root`, `--codex-path`, `--detach-mechanism` exist so tests can inject temp state
  roots / the fake-codex fixture / the `startprocess` mechanism (CIM children get a fresh user
  environment, so env-var overrides do NOT propagate through the `cim` mechanism — tests must
  pass explicit flags and use `startprocess`; production defaults use `cim` with no flags). These
  flags are deliberately undocumented in README/help.
- Any subcommand other than `run`, `submit`, `status`, `wait`, `read`, `worker` exits `2` with a
  message naming the supported commands.
- Git: one commit per task with the exact message given; NEVER add Co-Authored-By or any trailer.
- Live real-codex verification happens once, manually, in Task 11 only (record evidence in the
  task report; do not add live calls to `tests/`).

## File Structure (additions)

```text
D:\Documents\GitHub\ccodex\
|-- ccodex.ps1                          # modified: execution core extraction + new subcommands
|-- install.ps1                         # modified: installs the /ccodex Claude command
|-- templates/
|   `-- claude-command-ccodex.md        # NEW: source of the user-level /ccodex command
|-- lib/
|   |-- JobIndex.ps1                    # NEW: Get-CcodexJobRecord
|   |-- JobStatus.ps1                   # NEW: status read / liveness / orphan reconciliation
|   |-- Worker.ps1                      # NEW: Invoke-CcodexWorker
|   `-- Detach.ps1                      # NEW: Start-CcodexDetachedWorker / Wait-CcodexWorkerLaunch
`-- tests/
    |-- JobIndex.tests.ps1
    |-- JobStatus.tests.ps1
    |-- Worker.tests.ps1
    |-- Detach.tests.ps1
    |-- SubmitCommand.tests.ps1
    |-- StatusWaitRead.tests.ps1
    `-- AsyncE2E.tests.ps1
```

---

### Task 1: Job index lookup

**Files:** Create `lib/JobIndex.ps1`, `tests/JobIndex.tests.ps1`.

**Interfaces:**
- `Get-CcodexJobRecord([Parameter(Mandatory)][string]$JobId, [string]$Root = $env:LOCALAPPDATA) -> [pscustomobject]@{ JobId; RepoKey; JobDir }`
- Reads `Get-CcodexIndexPath -JobId $JobId -Root $Root` (from `lib/Paths.ps1`). Throws
  `"ccodex: job '<id>' not found (no index entry)."` when the index file is missing, and
  `"ccodex: job '<id>' index entry exists but its job directory is missing: <dir>"` when the
  recorded `job_dir` does not exist. Callers map both to wrapper exit `3`.

- [ ] **Step 1: failing test** — scenarios: (a) round-trip: write an index JSON (shape
  `{ job_id, repo_key, job_dir }`, as `Invoke-CcodexRun` writes it) into a temp `$Root` plus the
  matching job dir, assert all three properties; (b) missing index file → `Assert-Throws`;
  (c) index present but job dir deleted → `Assert-Throws`. Dot-source `Paths.ps1` + `JobStore.ps1`
  in the test for setup helpers.
- [ ] **Step 2: verify red** (`Get-CcodexJobRecord` undefined).
- [ ] **Step 3: implement** — read with `Get-Content -Raw | ConvertFrom-Json`.
- [ ] **Step 4: verify green**, run the full suite, confirm `0 failed` everywhere.
- [ ] **Step 5: commit** — `feat: add ccodex job index lookup`

---

### Task 2: Status read, worker liveness, and narrow orphan reconciliation

**Files:** Create `lib/JobStatus.ps1`, `tests/JobStatus.tests.ps1`.

**Interfaces:**
- `Read-CcodexStatusFile([Parameter(Mandatory)][string]$JobDir) -> [pscustomobject]|$null` — reads
  `<JobDir>/status.json`; on missing file or parse failure retries up to 3 attempts, 100 ms apart,
  then returns `$null` (readers tolerate a mid-rename window).
- `ConvertTo-CcodexBackendId([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][DateTime]$StartTime) -> string`
  — `"<pid>;<StartTime.ToUniversalTime().ToString('o')>"`.
- `Test-CcodexWorkerAlive([string]$BackendId) -> bool` — `$false` for null/empty/unparseable;
  otherwise `Get-Process -Id <pid>` and compare the process's UTC start time to the recorded one
  with ±2 s tolerance (PID-reuse guard). Any exception → `$false`.
- `Update-CcodexOrphanStatus([Parameter(Mandatory)][string]$JobDir) -> [pscustomobject]@{ Status; Reconciled; PossiblyStale }`
  — the ONLY writer besides the worker, gated exactly as the Global Constraints define:
  - status missing/unparseable → `@{ Status = $null; Reconciled = $false; PossiblyStale = $true }`.
  - status not `running` → pass through, no write.
  - `running` + worker alive → no write.
  - `running` + worker dead + `exit_code.txt` exists → derive the terminal state with
    `Test-CcodexResult` (codex exit code from `exit_code.txt`, result path `<JobDir>/result.md`),
    rewrite `status.json` atomically preserving all existing fields and updating `status`,
    `codex_exit_code`, `wrapper_exit_code`, `finished_at` (now, ISO `'o'`), `error` (set
    `"worker process exited; state reconciled from completion evidence"` only for the failed
    case) → `Reconciled = $true`.
  - `running` + worker dead + no `exit_code.txt` → NO write, `PossiblyStale = $true`.

- [ ] **Step 1: failing test** — build fixture job dirs in a temp root covering every branch above
  (dead-worker cases use a fabricated `backend_id` like `"999999;2020-01-01T00:00:00.0000000Z"`;
  the alive case uses `$PID` + this process's real start time). Assert rewrite happened/didn't by
  re-reading `status.json` (and that a rewrite preserved `job_id`/`mode`/`access`/`repo`).
  Dot-source `JobStore.ps1`, `ResultValidation.ps1`.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement.**
- [ ] **Step 4: verify green + full suite.**
- [ ] **Step 5: commit** — `feat: add ccodex status read, worker liveness, and orphan reconciliation`

---

### Task 3: Execution-core extraction and JobStore field extensions

**Files:** Modify `ccodex.ps1`, `lib/JobStore.ps1`, `tests/JobStore.tests.ps1`.

**Interfaces:**
- `New-CcodexStatusObject` gains optional appended params (defaults preserve current output
  shape with nulls): `[string]$Backend = 'sync'`, `[string]$BackendId = $null`,
  `[string]$StartedAt = $null`, `[string]$FinishedAt = $null` — emitted as ordered keys
  `backend`, `backend_id`, `started_at`, `finished_at` after `created_at`.
- `New-CcodexDebugObject` gains `[string]$Backend = 'sync'` replacing the hardcoded value.
- `ccodex.ps1`: extract from `Invoke-CcodexRun` a shared core
  `Invoke-CcodexJobExecution([string]$JobDir, [string]$RepoRoot, [string]$Mode, [string]$Access, [string]$WorkerPrompt, [string]$CodexPath, [string]$CreatedAt, [string]$Backend = 'sync', [string]$BackendId = $null, [string]$StartedAt = $null) -> [pscustomobject]@{ WrapperExitCode; Stdout; Message; CodexExitCode; Status }`
  covering: codex path resolution (`Resolve-CcodexCodexPath` when `$CodexPath` empty, routed
  through the existing internal-failure evidence writer), `command.txt`/`debug.json` writes, the
  `running` status write, process invocation, worker-complete evidence (both writes), result
  validation, and the final status write (which now also stamps `finished_at`, and carries
  `backend`/`backend_id`/`started_at` through). `Invoke-CcodexRun` becomes: validate → reserve →
  index → prompt → call the core. **Behavior of `run` must not change.**

- [ ] **Step 1: extend `tests/JobStore.tests.ps1` (failing first)** — new assertions: status object
  with no new args has `backend = 'sync'` and null `backend_id`/`started_at`/`finished_at`; with
  args, values round-trip; debug object honors `-Backend 'native'`.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement** the JobStore extension and the `ccodex.ps1` extraction.
- [ ] **Step 4: verify green + FULL suite green** (this is the regression-gated refactor;
  `RunCommand.tests.ps1` and `RealInvocation.tests.ps1` are the contract).
- [ ] **Step 5: commit** — `refactor: extract ccodex job execution core and extend job store fields`

---

### Task 4: Worker entrypoint

**Files:** Create `lib/Worker.ps1`, `tests/Worker.tests.ps1`; modify `ccodex.ps1` (dispatcher).

**Interfaces:**
- `Invoke-CcodexWorker([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA, [string]$CodexPath) -> [pscustomobject]@{ WrapperExitCode; Message }`
  — flow: `Get-CcodexJobRecord` (not found → wrapper 3 in the returned object, no throw to
  caller); read `status.json` (must exist; carries `mode`, `access`, `repo`, `created_at`); read
  `<JobDir>/prompt.md` as the already-rendered worker prompt; stamp the `running` status
  atomically with `backend = 'native'`, `backend_id = ConvertTo-CcodexBackendId($PID, (Get-Process -Id $PID).StartTime)`,
  `started_at = now('o')`; then call `Invoke-CcodexJobExecution` passing the same
  backend/backend_id/started_at so the terminal status preserves them; return the core's
  `WrapperExitCode`.
- Dispatcher: `worker` case with `--job-id <id>` (required), `--state-root <path>`,
  `--codex-path <path>` (both optional, test-support). Exits with the returned wrapper code.
  Update the default-case "supported commands" message (here or in Task 6 — whichever task
  touches it last keeps it accurate: `run` + implemented 2a commands).

- [ ] **Step 1: failing test** — seed a prepared job dir (temp state root: reservation via
  `Reserve-CcodexJobDir`, index JSON, rendered `prompt.md`, `created` status with mode/access/
  repo) then: (a) in-process `Invoke-CcodexWorker` with `-CodexPath` = fake-codex.cmd +
  `CCODEX_FAKE_RESULT` → wrapper 0; re-read status: `done`, `backend='native'`, `backend_id`
  parseable and matching `Test-CcodexWorkerAlive` for the current process, `started_at`/
  `finished_at` non-null, `result.md` content as set; (b) fake exit 3 → wrapper 10, status
  `failed`; (c) unknown job id → wrapper 3; (d) shell-level:
  `pwsh -NoProfile -File ccodex.ps1 worker --job-id <id> --state-root <root> --codex-path <fixture>`
  → `$LASTEXITCODE` 0 and terminal status `done`.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement.**
- [ ] **Step 4: verify green + full suite.**
- [ ] **Step 5: commit** — `feat: add ccodex internal worker entrypoint`

---

### Task 5: Detached launch and startup sentinel

**Files:** Create `lib/Detach.ps1`, `tests/Detach.tests.ps1`.

**Interfaces:**
- `Start-CcodexDetachedWorker([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][string]$WorkingDirectory, [string]$StateRoot, [string]$CodexPath, [ValidateSet('cim','startprocess')][string]$Mechanism = 'cim') -> int` (child pid)
  - Command line (single string for CIM; argument array for Start-Process):
    `pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<ScriptPath>" worker --job-id <JobId>`
    plus `--state-root "<StateRoot>"` / `--codex-path "<CodexPath>"` only when provided. Quote
    path-bearing values with plain double quotes for the CIM string form.
  - `cim`: `Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ...; CurrentDirectory = $WorkingDirectory }`;
    `ReturnValue -ne 0` → throw `"ccodex: native backend failed to launch the worker (Win32_Process.Create returned <n>)."`
  - `startprocess`: `Start-Process pwsh -ArgumentList ... -WorkingDirectory ... -WindowStyle Hidden -PassThru` → `.Id`.
- `Wait-CcodexWorkerLaunch([Parameter(Mandatory)][string]$JobDir, [int]$TimeoutSec = 20) -> [pscustomobject]` —
  polls `Read-CcodexStatusFile` every 250 ms until `status` is anything other than `created`
  (running or already terminal) and returns that status object; on timeout throws
  `"ccodex: worker did not start within <n>s; job left in 'created' state for diagnosis."`
  Callers map launch/sentinel failures to wrapper exit `23`.

- [ ] **Step 1: failing test** — (a) survival-through-parent-exit: write a temp parent script that
  calls `Start-CcodexDetachedWorker -Mechanism startprocess` pointing at the repo's `ccodex.ps1`,
  a seeded job (as in Task 4), the temp `--state-root`, fake-codex `--codex-path`, then exits;
  run it via `pwsh -NoProfile -File`; after the parent has exited, `Wait-CcodexWorkerLaunch`
  then poll status to terminal `done` and assert `result.md` content — this proves the worker
  outlives the submitting process; (b) sentinel timeout: seeded job, never launch a worker,
  `Wait-CcodexWorkerLaunch -TimeoutSec 1` → `Assert-Throws`; (c) `cim` mechanism smoke without
  env dependence: launch (via `-Mechanism cim`) a worker for a seeded job whose `--state-root`
  and `--codex-path` are passed explicitly (flags, not env) and poll to terminal `done` — this
  exercises the production mechanism end-to-end using only command-line plumbing. If CIM is
  unavailable in the test environment, the test must fail loudly, not skip silently.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement.**
- [ ] **Step 4: verify green + full suite.** (This test involves real 8–20 s process waits; that
  is expected, not a hang.)
- [ ] **Step 5: commit** — `feat: add ccodex detached worker launch with startup sentinel`

---

### Task 6: `submit` command

**Files:** Modify `ccodex.ps1`; create `tests/SubmitCommand.tests.ps1`.

**Interfaces:**
- Extract the shared preparation from `Invoke-CcodexRun` into
  `Initialize-CcodexJob([string]$Mode, [string]$Access, [string]$RepoOverride, [string]$PromptFile, [string]$PositionalTask, [bool]$PipelineExpected, [object[]]$PipelineObjects, [string]$LocalAppDataRoot, [string]$AppDataRoot, [string]$InitialStatus, [string]$Backend) -> [pscustomobject]@{ WrapperExitCode; JobId; JobDir; RepoRoot; ResolvedAccess; WorkerPrompt; CreatedAt; Message }`
  — validation (mode/access, prompt sources), repo resolution, reservation, index write,
  artifact-dir creation for `workspace`, template render, `prompt.md` write, and the initial
  `status.json` (status `$InitialStatus`, backend `$Backend`). Usage errors return code 2 exactly
  as today (same messages/status side effects). `Invoke-CcodexRun` = `Initialize-CcodexJob`
  (`running`… actually keep `run` writing its `running` status inside the core as today —
  `run` passes `-InitialStatus 'created'` is WRONG; preserve current observable behavior:
  the core's `running` write is what `RunCommand.tests.ps1` sees. `run` may pass
  `-InitialStatus 'created'` only if the core still rewrites to `running` before invocation,
  which it does — keep both, behavior-identical) + core call.
- `Invoke-CcodexSubmit(<same prompt/mode/repo params as Invoke-CcodexRun> , [string]$DetachMechanism = 'cim', [string]$CodexPath, [string]$LocalAppDataRoot = $env:LOCALAPPDATA, [string]$AppDataRoot = $env:APPDATA) -> [pscustomobject]@{ WrapperExitCode; Stdout; JobDir; JobId; Message }`
  — `Initialize-CcodexJob -InitialStatus 'created' -Backend 'native'`; write `command.txt`/
  `debug.json` (backend `native`) so the job is fully diagnosable pre-launch; launch
  `Start-CcodexDetachedWorker` with `$PSCommandPath`, repo root as working directory, passing
  `--state-root`/`--codex-path` flags only when the corresponding params were explicitly
  overridden; `Wait-CcodexWorkerLaunch`; success → `Stdout = "<job_id>`n<job_dir>"`, exit 0.
  Launch throw or sentinel timeout → exit 23 with the thrown message plus job id/dir; do NOT
  rewrite `status.json` (a slow worker may still be starting; the job stays diagnosable).
- Dispatcher: `submit` case mirroring `run`'s pipeline/stdin capture; on success print the two
  stdout lines; failures print `Message`; exit accordingly. `--detach-mechanism` accepted as the
  hidden test flag.

- [ ] **Step 1: failing test** — via in-process `Invoke-CcodexSubmit` with temp roots, fixture
  codex path, `-DetachMechanism startprocess`: (a) success returns 0, stdout lines parse to a
  job id matching the Phase 1 job-id regex and an existing job dir; polling status reaches
  `done`; `wait`-style re-read shows `result.md` written by the fixture; `prompt.md`/
  `command.txt`/`debug.json` exist at return time (before terminal); (b) `--mode test` without
  access → 2, no worker launched; (c) unresolvable repo → 2; (d) sentinel failure: pass a
  `-CodexPath` that is fine but a deliberately broken `$ScriptPath`? — not injectable; instead
  simulate by `-DetachMechanism startprocess` with a `--state-root` job whose `prompt.md` was
  deleted post-init? That still stamps running. Simplest deterministic 23: temporarily override
  the sentinel timeout by seeding `Wait-CcodexWorkerLaunch`'s behavior — expose an optional
  `[int]$StartupTimeoutSec = 20` on `Invoke-CcodexSubmit`, pass 0-second timeout with a
  mechanism-valid launch pointed at a script path that exits immediately (e.g. a stub .ps1 that
  does nothing) → expect 23 and status still `created`. (e) shell-level: piped prompt through
  `pwsh -File ccodex.ps1 submit --mode review --repo <tmp> --state-root ... --codex-path ... --detach-mechanism startprocess`
  → exit 0, two stdout lines only (no JSONL, no result content).
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement** (including the dispatcher `--state-root` param for `submit`).
- [ ] **Step 4: verify green + FULL suite** (regression gate for the `Initialize-CcodexJob`
  refactor: `RunCommand.tests.ps1` + `RealInvocation.tests.ps1` unchanged and green).
- [ ] **Step 5: commit** — `feat: add ccodex submit with detached native worker`

---

### Task 7: `status` command

**Files:** Modify `ccodex.ps1`; create `tests/StatusWaitRead.tests.ps1` (status section).

**Interfaces:**
- `Invoke-CcodexStatusCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]@{ WrapperExitCode; Stdout; Message }`
  — `Get-CcodexJobRecord` (catch → 3); `Update-CcodexOrphanStatus`; then compose one line from
  the (possibly reconciled) status: non-terminal `"<job_id> <status>"` with
  `" health=possibly-stale"` appended when flagged; terminal
  `"<job_id> <status> codex_exit_code=<n|null> wrapper_exit_code=<n|null>"`. Exit 0 when the job
  exists (printing status is success), 3 otherwise.
- Dispatcher: `status <job_id>` (positional after the command), `--state-root` hidden flag.

- [ ] **Step 1: failing test** — fixture job dirs (reuse Task 2 helpers): created / running-alive /
  running-dead-with-evidence (line shows reconciled terminal state AND `status.json` was
  rewritten) / running-dead-no-evidence (`health=possibly-stale`, file NOT rewritten) / done /
  failed / unknown id → 3. Shell-level: `pwsh -File ccodex.ps1 status <id> --state-root ...`
  prints exactly the one line, exit 0.
- [ ] **Step 2: verify red.** / **Step 3: implement.** / **Step 4: green + full suite.**
- [ ] **Step 5: commit** — `feat: add ccodex status command`

---

### Task 8: `wait` command

**Files:** Modify `ccodex.ps1`; extend `tests/StatusWaitRead.tests.ps1` (wait section).

**Interfaces:**
- `Invoke-CcodexWaitCommand([Parameter(Mandatory)][string]$JobId, [int]$WaitTimeoutSec = 0, [int]$PollIntervalMs = 1000, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]@{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3. Loop: `Update-CcodexOrphanStatus` + read; terminal `done` → validate
  `result.md` (`Test-CcodexResult` with the recorded codex exit code): non-empty → `Stdout` =
  content, exit 0; missing/empty → 11 concise failure. Terminal `failed` → concise failure line
  (job id, status, codes, job dir, result path), exit = recorded `wrapper_exit_code` if in
  {10,11,12} else 10. `$WaitTimeoutSec -gt 0` and elapsed exceeds it → print current status line
  (Task 7 format) + `Message` hint to re-run `ccodex wait <id>`, exit 20, **no status write**.
  `0` means wait indefinitely.
- Dispatcher: `wait <job_id> [--wait-timeout-sec <n>]`.

- [ ] **Step 1: failing test** — (a) already-done job → result on stdout, 0; (b) failed job
  (wrapper 10 recorded) → 10; (c) done but empty result → 11; (d) slow job: launch a detached
  worker (Task 5 helper, `startprocess`) against a fixture with `CCODEX_FAKE_DELAY_MS`-extended
  fake-codex — extend `tests/fixtures/fake-codex.ps1` with an optional
  `if ($env:CCODEX_FAKE_DELAY_MS) { Start-Sleep -Milliseconds ([int]$env:CCODEX_FAKE_DELAY_MS) }`
  before writing output (keep every existing behavior; full suite must stay green) — then
  `wait --wait-timeout-sec 1` while it sleeps → 20 and job later still completes to `done`;
  then a second `wait` with no timeout → 0 + result; (e) unknown id → 3. Shell-level spot check
  of (a).
- [ ] **Step 2: verify red.** / **Step 3: implement.** / **Step 4: green + full suite.**
- [ ] **Step 5: commit** — `feat: add ccodex wait command`

---

### Task 9: `read` command

**Files:** Modify `ccodex.ps1`; extend `tests/StatusWaitRead.tests.ps1` (read section).

**Interfaces:**
- `Invoke-CcodexReadCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]@{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3. `Update-CcodexOrphanStatus` once. Non-terminal → status line + hint
  (`ccodex wait <job_id>`), exit 4. Terminal with non-empty `result.md` → print it, exit 0
  (read is the result channel regardless of `done`/`failed`). Terminal with missing/empty
  `result.md` → concise failure, exit 11.
- Dispatcher: `read <job_id>`.

- [ ] **Step 1: failing test** — done-with-result → 0; failed-with-result → 0 (content printed);
  running → 4 with hint; created → 4; terminal-no-result → 11; unknown → 3. Shell-level spot
  check: running job returns exit 4 and prints no result content.
- [ ] **Step 2: verify red.** / **Step 3: implement.** / **Step 4: green + full suite.**
- [ ] **Step 5: commit** — `feat: add ccodex read command`

---

### Task 10: Async end-to-end regression (shim-level, npm-shaped PATH)

**Files:** Create `tests/AsyncE2E.tests.ps1`.

Mirrors `tests/RealInvocation.tests.ps1`'s staging (temp bin with fake `codex.cmd` AND decoy
`codex.ps1`, temp LOCALAPPDATA/APPDATA, ccodex.cmd-style shim invoking the repo's `ccodex.ps1`)
but exercises the async loop through real process boundaries with `--detach-mechanism
startprocess` and explicit `--state-root`:

- [ ] **Step 1: failing test (the file, all scenarios)** —
  (a) piped multiline prompt → `submit` via the shim: exit 0, stdout is exactly two lines
  (job id + job dir), no JSONL, no result content;
  (b) the submitting shell exits (submit already returned), then `status` flips from
  running/created to `done` within a poll loop, `wait` → prints fixture result, exit 0, and
  `read` → same content, exit 0;
  (c) `read` against a still-sleeping job (`CCODEX_FAKE_DELAY_MS`) → exit 4; `wait
  --wait-timeout-sec 1` on it → exit 20; final no-timeout `wait` → 0;
  (d) `status`/`wait`/`read` with a bogus id → exit 3;
  (e) submit with `--mode test` (no access) → exit 2 and NO worker/process launched;
  (f) all job state landed under the temp state root; the target repo gained no `.ccodex/jobs`;
  (g) stdout of every success path never contains `fake-codex ran` (JSONL boundary holds
  end-to-end).
- [ ] **Step 2: verify red where applicable** (commands exist by now, so this file should mostly
  pass immediately — treat any failure as a real integration bug to fix in the involved lib,
  keeping earlier tasks' tests green; if everything passes on first run, note that in the report
  instead of manufacturing a red).
- [ ] **Step 3: green + FULL suite.**
- [ ] **Step 4: commit** — `test: add ccodex async end-to-end regression`

---

### Task 11: `/ccodex` Claude command, install update, README, live smoke

**Files:** Create `templates/claude-command-ccodex.md`; modify `install.ps1`, `README.md`.

**Interfaces / content contract:**
- `templates/claude-command-ccodex.md` — the user-level Claude command. Frontmatter with a
  one-line `description`; body instructs Claude to: (1) summarize the task clearly;
  (2) `<task text> | ccodex run --mode review|brainstorm` from the project directory for
  sync second opinions/reviews (`--repo <path>` when acting for another repo); (3) for long or
  parallel tasks `ccodex submit …` then `ccodex wait <job_id>` / `ccodex read <job_id>`;
  (4) read stdout as the worker's final answer; treat nonzero exits per the wrapper exit-code
  table (0/2/3/4/10/11/12/20/23) without parsing prose; (5) merge Codex's findings into its own
  judgment and stay the final decision-maker. Mention `$ARGUMENTS` as the task text when the
  user supplies it inline.
- `install.ps1` — additionally copy the template to
  `%USERPROFILE%\.claude\commands\ccodex.md` (create the directory; overwrite on reinstall;
  print the destination like the existing lines). No PATH edits (unchanged policy).
- `README.md` — per CLAUDE.md's README-maintenance mandate: Phase 2a done (submit/status/wait/
  read + internal worker; native detached backend with survival sentinel), Phase 2b/4 not
  implemented (cancel/tail/debug/doctor/locks/worktrees), Phase 3 command shipped; usage
  examples for the async loop and `/ccodex`; exit-code table extended with 3/4/20/23.

- [ ] **Step 1: write the template + install.ps1 change; run `pwsh -NoProfile -File install.ps1`**
  and verify the three original lines plus the new command-file line; confirm
  `~\.claude\commands\ccodex.md` exists and matches the template.
- [ ] **Step 2: full automated suite green** (all `tests/*.tests.ps1`, `0 failed` each).
- [ ] **Step 3: live smoke (one-time, real codex; evidence in the task report, NOT in tests/)** —
  from any directory:
  `"Reply with exactly the word PONG2A and nothing else." | ccodex submit --mode review --repo D:\Documents\GitHub\ccodex`
  → capture the job id; `ccodex status <id>` until terminal; `ccodex wait <id>` → expect
  stdout `PONG2A`, `$LASTEXITCODE` 0; `ccodex read <id>` → same. Record commands + verbatim
  output + exit codes. If codex auth/network fails, record the evidence and report
  DONE_WITH_CONCERNS — never claim an unobserved success.
- [ ] **Step 4: update README.md** (verify every claim against the actual code/flags before
  writing it).
- [ ] **Step 5: commit** — `feat: add /ccodex claude command, async install, and phase 2a docs`

---

## Self-Review

| Phase 2a amendment requirement | Covered by |
|---|---|
| `submit` returns immediately with job id + path | Task 6 (stdout contract) + Task 10a |
| Worker survives submitter exit (Job-Object risk) | Task 5 test (a) survival-through-parent-exit; CIM as production default; Task 5 test (c) cim smoke |
| Startup sentinel; `23` when worker never starts | Task 5 `Wait-CcodexWorkerLaunch` + Task 6 test (d) |
| Single-writer + atomic status; no locks | Global Constraints; Task 2 reconciliation gate; no `.lock` anywhere |
| Narrow orphan reconciliation (evidence-gated CAS) | Task 2 `Update-CcodexOrphanStatus` + Task 7 tests |
| `status` lifecycle line (+ possibly-stale) | Task 7 |
| `wait` prints result / 20 on timeout without lifecycle change | Task 8 |
| `read` 3/4/11/0 semantics | Task 9 |
| Exit codes 3/4/20/23 added; 21/22/24 absent | Tasks 6–9; nothing implements the latter |
| `status.json` additions append-only (backend/backend_id/started_at/finished_at) | Task 3 |
| Worker reads everything from the global job dir (no task data on the command line) | Task 4/5 (only ids/paths/flags on the command line) |
| Raw JSONL never on stdout across async commands | Task 10 (g) |
| Phase 3 `/ccodex` user-level command | Task 11 |
| README reflects reality before phase is "done" | Task 11 Step 4 (CLAUDE.md mandate) |
| Live real-codex async round-trip observed once | Task 11 Step 3 |

**Deliberate scope boundary:** `cancel`, `tail`, `debug`, `doctor`, per-job locks, heartbeat/
health, retention, tmux, worktrees, and `codex exec resume` integration are Phase 2b+ and appear
nowhere in this plan.
