# ccodex Adapter Phase 2a.1 (Failure-Mode Hardening) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox
> steps. Tests run with cwd = repo root: `pwsh -NoProfile -File tests/<name>.tests.ps1`.

**Goal:** implement the design's "Failure-mode handling amendment (2026-07-05)"
(docs/2026-07-03-ccodex-adapter-design.md): conservative failure classification
(`failure_reason`), codex thread-id capture, terminal failure evidence for `submit`'s pre-launch
failures, job-level hard timeout with process-tree kill (`timed_out`/exit 24), reconciliation and
detach-quoting hardening from the 2026-07-05 dogfood review, fixture/E2E coverage, and docs so
Claude can react to each failure class without reading logs.

## Global Constraints

- All Phase 1 + Phase 2a constraints still bind: full suite green after every task (every
  `tests/*.tests.ps1` prints `0 failed`); UTF-8 without BOM; raw Codex JSONL never on parent
  stdout; single-writer + atomic status writes; append-only status fields; plain assertion tests
  (no Pester); `ccodex.ps1` stays a plain script; follow its existing `$args`-based flag parsing
  (`Get-CcodexArgValue`).
- Wrapper exit codes now: 0/2/3/4/10/11/12/20/23/**24**. Never 21/22.
- New status.json fields (append-only, may be absent/null): `failure_reason`, `codex_thread_id`,
  `hard_timeout_sec`, `timeout_reason`, `terminated_at`.
- `failure_reason` values: `quota_or_rate_limit` | `auth` | `permission_or_sandbox` | `network`
  (or absent). It is a HINT; exit codes stay authoritative. Never classify a successful run.
- Still out of scope: cancel/tail/debug/doctor/locks/heartbeat/tmux/worktrees.
- Git: one commit per task, exact message, NEVER any Co-Authored-By or trailer.
- Live real-codex calls: none in this phase's automated tests (fixtures only).

---

### Task 1: Failure classification, thread-id capture, and submit failure evidence

**Files:** Create `lib/FailureClassify.ps1`, `tests/FailureClassify.tests.ps1`; modify
`ccodex.ps1` (execution core failure path + submit pre-launch failure path), `lib/JobStore.ps1`
(optional `-FailureReason`, `-CodexThreadId` on `New-CcodexStatusObject`, append-only), extend
`tests/JobStore.tests.ps1`, extend `tests/SubmitCommand.tests.ps1`.

**Interfaces:**
- `Get-CcodexCodexThreadId([string]$EventsPath) -> string|$null` — the `thread_id` of the first
  `thread.started` event; `$null` on missing/unreadable/unparseable file or absent event.
- `Get-CcodexFailureReason([Nullable[int]]$CodexExitCode, [string]$StderrPath, [string]$EventsPath) -> string|$null`
  — `$null` when `$CodexExitCode` is 0 or the paths are absent/empty of signals. Otherwise match
  case-insensitively over the LAST 8 KB of `stderr.log` plus any event lines containing
  `"error"`: precedence quota (`usage limit|rate limit|quota|429`) > auth
  (`login|auth|401|unauthorized|credential`) > permission (`sandbox|denied|approval|permission`)
  > network (`network|connection|dns|502|503`).
- Execution core: on any failure terminal status, stamp `failure_reason` (when non-null); stamp
  `codex_thread_id` on BOTH success and failure whenever present. Failure `Message` gains one
  hint line per reason: quota → `Codex usage/rate limit reached - report to the user; do not
  auto-retry.`; auth → `Codex auth problem - run: codex login`; permission →
  `Sandbox/permission denial - consider --access workspace or narrow the task.`; network →
  `Transient network failure - one retry is safe.`.
- `submit` fix (dogfood finding #1): when codex-path resolution (or any pre-launch internal
  failure after job reservation) fails inside `Invoke-CcodexSubmit`, write a terminal `failed`
  status.json (wrapper_exit_code 12, error message) AND a `worker-complete.json` evidence file
  (reuse the `Complete-CcodexInternalFailure` pattern; submit is the only writer pre-launch, so
  this is single-writer-safe), then return exit 12. A job must never remain at `created` after a
  known-fatal internal failure.

- [ ] **Step 1: failing tests** — FailureClassify: synthetic stderr/events fixtures per signature
  class + precedence case (quota beats auth when both present) + exit-0 never classified + absent
  files → null; thread-id: real-shaped events line
  (`{"type":"thread.started","thread_id":"..."}`), absent event → null. JobStore: new params
  round-trip and default-absent behavior. Submit: with `-CodexPath` pointing at a nonexistent
  file / no codex resolvable, expect exit 12, status.json `failed` + wrapper_exit_code 12,
  worker-complete.json present; then `status` prints failed (not created) and `read` exits 11.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement.**
- [ ] **Step 4: verify green + FULL suite.**
- [ ] **Step 5: commit** — `feat: add ccodex failure classification, thread-id capture, and submit failure evidence`

---

### Task 2: Job-level hard timeout with process-tree termination

**Files:** Modify `lib/CodexInvoke.ps1` (`Invoke-CcodexCodexProcess` gains `[int]$HardTimeoutMs = 0`),
`ccodex.ps1` (`run`/`submit` accept `--hard-timeout-sec <n>`; worker reads it from status.json;
timeout branch in the execution core), `lib/JobStore.ps1` (optional `-HardTimeoutSec`,
`-TimeoutReason`, `-TerminatedAt`); extend `tests/CodexInvoke.tests.ps1`,
`tests/RunCommand.tests.ps1`, `tests/Worker.tests.ps1`.

**Behavior:**
- `Invoke-CcodexCodexProcess` with `$HardTimeoutMs -gt 0`: `WaitForExit($HardTimeoutMs)`; on
  expiry kill the whole tree — `taskkill /PID <pid> /T /F` (covers the cmd.exe shim's children) —
  then drain/close streams safely and return the sentinel `$null` exit code (signature widens to
  `[Nullable[int]]` return; existing callers treat non-null as before). Do NOT write
  `exit_code.txt` on timeout (Codex never exited; `codex_exit_code` stays null).
- Execution core timeout branch: worker-complete with status_candidate `timed_out`, final status
  `timed_out` + `timeout_reason = "hard_timeout_sec=<n> exceeded"` + `terminated_at` +
  wrapper_exit_code 24; wrapper exit 24. Artifacts kept.
- `run --hard-timeout-sec <n>` plumbs directly; `submit --hard-timeout-sec <n>` stores
  `hard_timeout_sec` in the created status.json and the worker picks it up from there (no extra
  command-line data). `status` line shows `timed_out`; `wait` returns recorded code 24 on a
  `timed_out` terminal; `read` semantics unchanged (result missing → 11).
- Default 0 = never kill (design philosophy: quiet does not mean dead).

- [ ] **Step 1: failing tests** — CodexInvoke: fixture with `CCODEX_FAKE_DELAY_MS=8000` +
  `HardTimeoutMs=1500` → returns null within ~3 s, and the fake-codex pwsh process tree is dead
  (poll `Get-Process` for the child pid recorded via a pid-file the fixture writes — extend the
  fixture with optional `CCODEX_FAKE_PIDFILE` support, keeping all existing behavior); no
  exit_code.txt. RunCommand: `run --hard-timeout-sec 1` against the sleeping fixture → wrapper
  24, status.json `timed_out` with timeout_reason/terminated_at set and codex_exit_code null.
  Worker: seeded job whose status.json has hard_timeout_sec 1 → worker exits 24, status
  `timed_out`.
- [ ] **Step 2: verify red.**
- [ ] **Step 3: implement.**
- [ ] **Step 4: verify green + FULL suite** (timing-sensitive: allow generous poll windows).
- [ ] **Step 5: commit** — `feat: add ccodex job-level hard timeout with process-tree termination`

---

### Task 3: Robustness hardening batch (dogfood findings + review minors)

**Files:** Modify `lib/JobStatus.ps1`, `lib/Detach.ps1`, `ccodex.ps1`; extend
`tests/JobStatus.tests.ps1`, `tests/Detach.tests.ps1`; possibly `tests/SubmitCommand.tests.ps1`.

**Changes (each with a covering test):**
1. **Corrupt-evidence guard** (dogfood #2): `Update-CcodexOrphanStatus` must not throw on an
   empty/partial/corrupt `exit_code.txt` — use `[int]::TryParse`; on failure treat as
   no-usable-evidence → `PossiblyStale = $true`, no write, no exception.
2. **CIM quote guard** (dogfood #4): `Start-CcodexDetachedWorker` throws a clear error if
   `$ScriptPath`/`$StateRoot`/`$CodexPath` contains a double-quote (illegal in Windows paths;
   fail loudly instead of building a corrupt command line).
3. **Stream-isolation documentation** (dogfood #3, triaged false positive): comment on the
   Start-Process call documenting that `-WindowStyle Hidden` allocates a separate hidden console
   so worker output cannot interleave with `submit`'s stdout; ensure `tests/AsyncE2E.tests.ps1`
   asserts submit stdout is EXACTLY the two lines (add the assertion if not already exact).
4. **Duplicate running-write removal** (2a review minor): `Invoke-CcodexJobExecution` gains a
   `[switch]$SkipRunningWrite` used by the worker (which already stamped `running` itself);
   `run` behavior unchanged.
5. **`read` reuse cleanup** (2a review minor): `Invoke-CcodexReadCommand` uses
   `Test-CcodexResult` instead of duplicating exists/non-empty logic; observable behavior
   unchanged.
6. **Flake headroom**: widen `tests/SubmitCommand.tests.ps1`'s first-scenario terminal-poll
   window (the CIM worker occasionally needs longer than the current window; one transient flake
   observed 2026-07-05).

- [ ] **Step 1: failing tests where applicable** (1: corrupt/empty exit_code.txt fixtures; 2:
  quote-bearing path → Assert-Throws; 4: worker path produces exactly one `running` write —
  assert via a status.json snapshot taken between stamps is impractical, so assert instead that
  worker flow still ends `done` and `run` flow unchanged; treat 3/5/6 as
  refactor-with-regression-gate).
- [ ] **Step 2: verify red for 1-2.**
- [ ] **Step 3: implement all six.**
- [ ] **Step 4: verify green + FULL suite.**
- [ ] **Step 5: commit** — `fix: harden ccodex reconciliation, detach quoting, and status writes`

---

### Task 4: Fixture and E2E coverage for failure classes

**Files:** Modify `tests/fixtures/fake-codex.ps1` (add optional `CCODEX_FAKE_STDERR` — when set,
write its value to stderr before exiting; keep every existing behavior); extend
`tests/AsyncE2E.tests.ps1`.

- [ ] **Step 1: scenarios** — (a) submit a job whose fixture emits
  `Rate limit exceeded (429)` on stderr + exit 1 → `wait` exits 10 AND status.json carries
  `failure_reason = "quota_or_rate_limit"`; (b) submit a sleeping job with `--hard-timeout-sec 1`
  → worker marks `timed_out`, `wait` exits 24, worker's codex child process is dead, artifacts
  (prompt.md, codex-events.jsonl, status.json) preserved; (c) shim-level `run` with an
  auth-signature stderr + exit 1 → failure message contains the `codex login` hint; (d) full
  suite green.
- [ ] **Step 2: verify red where the features are asserted end-to-end for the first time; fix
  integration bugs in the responsible lib if any (keeping earlier tasks green).**
- [ ] **Step 3: green + FULL suite.**
- [ ] **Step 4: commit** — `test: cover ccodex failure classification and hard timeout end-to-end`

---

### Task 5: Failure-class docs

**Files:** Modify `README.md`, `templates/claude-command-ccodex.md`; re-run
`pwsh -NoProfile -File install.ps1`.

- [ ] **Step 1:** README: exit-code table gains 24; new "Failure classes" table
  (failure_reason values → meaning → recommended reaction); `--hard-timeout-sec` usage on
  run/submit. `/ccodex` command template gains the reaction guidance: `10 + quota` → report to
  user, no retry; `10 + auth` → suggest `codex login`; `10 + network` → one retry; `24` → raise
  timeout or split the task; `20` → job still running, re-`wait`; `23` → backend/environment
  issue, inspect job dir. Verify every claim against the actual code before writing.
- [ ] **Step 2:** run install.ps1; verify installed copies match the repo (`ccodex.ps1`, `lib/*`,
  command template).
- [ ] **Step 3:** full suite green (docs must not break anything).
- [ ] **Step 4: commit** — `docs: document ccodex failure classes and hard timeout`

---

## Self-Review

| Amendment requirement | Covered by |
|---|---|
| quota/auth/permission/network classification + hints | Task 1 + Task 4 (a)(c) |
| `codex_thread_id` captured (success + failure) | Task 1 |
| submit never leaves a job at `created` after fatal internal failure | Task 1 (dogfood #1) |
| hard timeout → tree kill, `timed_out`, exit 24, artifacts kept | Task 2 + Task 4 (b) |
| corrupt evidence degrades to possibly-stale, never throws | Task 3.1 (dogfood #2) |
| CIM quote guard | Task 3.2 (dogfood #4) |
| Start-Process stream triage documented + asserted | Task 3.3 (dogfood #3) |
| interactive-input stall: impossible by construction | design doc only (no code) |
| exit codes 24 added; 21/22 absent | Tasks 2; nothing implements 21/22 |
| README/`/ccodex` reaction guidance | Task 5 |
