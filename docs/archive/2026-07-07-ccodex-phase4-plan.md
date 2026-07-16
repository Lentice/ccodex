# ccodex Adapter Phase 4 (Worktree Isolation: implement mode, diff, apply) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox
> steps; tests via `pwsh -NoProfile -File tests/<name>.tests.ps1` from repo root. Governing design
> sections: "Phase 4 worktree refinements" (2026-07-07 amendment), "Access Modes > worktree", and
> "Future: diff / apply" in `docs/2026-07-03-ccodex-adapter-design.md`. **Prerequisite: Phase 2b
> is complete** (locks + cleanup exist; cleanup's worktree integration lands here as Task 6).

**Goal:** edit-capable Codex workers that can never touch the caller's working tree: jobs with
`--access worktree` run Codex inside a detached git worktree under the global state root, the
worker snapshots all changes into one deterministic commit, and the caller inspects with
`ccodex diff <job_id>` and integrates explicitly with `ccodex apply <job_id>`. `--mode implement`
unlocks with worktree as its default access.

**Architecture:** one new lib (`lib/Worktree.ps1`); `lib/ModeAccess.ps1` unlocks the
mode/access matrix; `Initialize-CcodexJob`/`Invoke-CcodexJobExecution` gain worktree
creation/finalization; two new dispatcher commands (`diff`, `apply`); `lib/Cleanup.ps1` learns to
remove job worktrees.

## Global Constraints

- All prior-phase constraints bind (suite green per task; UTF-8 no BOM; plain tests; `$args`
  parsing; append-only status fields; JSONL never on parent stdout; no `.superpowers/` commits;
  exact commit messages, no trailers).
- Exit codes after this phase add **`25`** = "`apply` failed or conflicted; the main repo was
  left untouched and the job's worktree/artifacts are preserved". No other new codes.
- Worktrees live ONLY under `<stateroot>\ccodex\worktrees\<job_id>\` — never inside any
  repository. `status.json`/`debug.json` record `main_repo`, `worktree_repo`, `base_commit`
  (append-only fields).
- The main repo is NEVER written by job execution. Only `apply` writes to it, only explicitly,
  and only from a clean working tree.
- Mode/access matrix after this phase: `review`/`brainstorm` → `read-only` only (unchanged);
  `test` → `workspace` (existing) or `worktree` (new, recommended); `implement` → `worktree`
  only (default when `--access` omitted). Codex sandbox mapping for worktree access is
  `workspace-write` with `-C <worktree_repo>`.
- Snapshot commits are created with explicit identity flags
  (`-c user.name=ccodex-worker -c user.email=ccodex@local`) so they work on machines with no
  git identity configured; hooks are NOT bypassed.
- All git operations against fixtures use real `git` in temp repos (already a test dependency).

## File Structure (additions)

```text
lib/Worktree.ps1          # create/finalize/remove job worktrees
tests/Worktree.tests.ps1
tests/DiffApply.tests.ps1
tests/ImplementE2E.tests.ps1
```

---

### Task 1: Worktree lifecycle lib

**Files:** create `lib/Worktree.ps1`, `tests/Worktree.tests.ps1`.

**Interfaces:**
- `New-CcodexJobWorktree([Parameter(Mandatory)][string]$MainRepo, [Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WorktreePath; BaseCommit }`
  — `BaseCommit` = `git -C <MainRepo> rev-parse HEAD` (empty repo / unborn HEAD → throw usage
  error "repository has no commits; worktree access needs at least one commit");
  `git -C <MainRepo> worktree add --detach <stateroot>\ccodex\worktrees\<JobId> <BaseCommit>`;
  any git failure → throw with git's stderr included.
- `Complete-CcodexJobWorktree([Parameter(Mandatory)][string]$WorktreePath, [Parameter(Mandatory)][string]$JobId) -> [pscustomobject]{ Committed; HeadCommit }`
  — the snapshot finalization: `git add -A`; if `git status --porcelain` is empty →
  `Committed=$false`, `HeadCommit` = current HEAD; else commit
  `-m "ccodex: worker output <JobId>"` with the fixed identity flags → `Committed=$true`.
- `Remove-CcodexJobWorktree([Parameter(Mandatory)][string]$MainRepo, [Parameter(Mandatory)][string]$WorktreePath) -> bool`
  — `git -C <MainRepo> worktree remove --force <path>` then `git -C <MainRepo> worktree prune`;
  best-effort ($false + no throw when the main repo itself is gone; then just delete the
  directory).

- [ ] Step 1: failing tests — temp main repo with one commit: create (dir exists, detached at
  base, base matches HEAD); finalize with changes (file added in worktree → Committed=true, main
  repo HEAD unchanged, worktree HEAD advanced); finalize without changes (Committed=false);
  remove (gone + pruned, `git worktree list` shrinks); unborn-HEAD repo → Assert-Throws.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex job worktree lifecycle`

---

### Task 2: Mode/access matrix unlock

**Files:** modify `lib/ModeAccess.ps1`; extend `tests/ModeAccess.tests.ps1`.

**Interfaces (behavior deltas only):**
- `Resolve-CcodexAccess`: `implement` no longer throws — default (omitted `--access`) resolves to
  `worktree`; explicit `--access worktree` valid for `implement` and `test`; still invalid for
  `review`/`brainstorm` (clear message). `--access workspace` for `implement` → throw (worktree
  only). All Phase-1 rejections that remain (e.g. `test --access read-only`) unchanged.
- `ConvertTo-CcodexSandboxFlag` accepts `worktree` → `workspace-write`.
- `Build-CcodexCodexArgs` is unchanged in shape — the caller passes the worktree path as
  `-RepoRoot` when access is worktree (asserted in Task 3).

- [ ] Step 1: failing tests — matrix: implement default → worktree; implement+workspace →
  throws; test+worktree → worktree; review+worktree → throws; sandbox mapping worktree →
  workspace-write; every pre-existing assertion stays green (this file is a contract).
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: unlock ccodex implement mode and worktree access`

---

### Task 3: Job pipeline integration (create → execute in worktree → snapshot)

**Files:** modify `ccodex.ps1` (`Initialize-CcodexJob`, `Invoke-CcodexJobExecution`, worker),
`lib/JobStore.ps1` (optional `-MainRepo`/`-WorktreeRepo`/`-BaseCommit`); extend
`tests/JobStore.tests.ps1`, `tests/RunCommand.tests.ps1`, `tests/Worker.tests.ps1`.

**Behavior:**
- `Initialize-CcodexJob`: when resolved access is `worktree`, call `New-CcodexJobWorktree` after
  job-dir reservation; record `main_repo`, `worktree_repo`, `base_commit` in the initial
  status.json and debug.json; the worker-prompt render receives the WORKTREE path as
  `{{REPO_ROOT}}` plus the artifact dir exactly as `workspace` access does today (artifacts stay
  under the job dir, not the worktree). Worktree creation failure after reservation → terminal
  failed/12 with evidence (existing `Complete-CcodexInternalFailure` path).
- `Invoke-CcodexJobExecution`: codex `-C` targets `worktree_repo` when present; after the process
  exits (any exit code, including hard-timeout kill), run `Complete-CcodexJobWorktree`
  (best-effort on failure paths; record `worktree_committed` in the terminal status). Result
  validation and everything else unchanged.
- Worker prompt contract line for implement mode: extend `templates/worker-prompt.md` mode
  guidance with one line for implement tasks ("implement the requested change with focused
  commits or plain edits; the wrapper snapshots your work"). Keep template placeholders
  unchanged.

- [ ] Step 1: failing tests — with the fake-codex fixture extended additively to honor
  `CCODEX_FAKE_WRITE_FILE=<relative-path>` + `CCODEX_FAKE_WRITE_TEXT` (parse `-C <dir>` from its
  argv and write the file under that dir; all existing fixture behavior preserved):
  run `--mode implement` against a temp main repo → exit 0; file exists in the WORKTREE, absent
  in the main repo; status has main/worktree/base fields + `worktree_committed=true`; worktree
  HEAD ahead of base by exactly the snapshot commit. Worker path: same through a seeded submit
  job. No-write run → `worktree_committed=false`. Existing read-only/workspace runs byte-stable
  (regression gates).
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: run ccodex worktree jobs in isolated worktrees with snapshot finalization`

---

### Task 4: `ccodex diff`

**Files:** modify `ccodex.ps1`; create `tests/DiffApply.tests.ps1` (diff section).

**Interfaces:**
- `Invoke-CcodexDiffCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — unknown id → 3; non-terminal → 4 (with the standard hint); job without a worktree (read-only/
  workspace access) → usage error 2 "job has no worktree"; worktree missing on disk (cleaned) →
  3 with "worktree removed; artifacts remain at <job_dir>". Success: print
  `git -C <worktree> diff --stat <base>..HEAD` then the full `git diff <base>..HEAD`; empty
  change set → informational line, exit 0.

- [ ] Step 1: failing tests — done implement job (from Task 3 fixtures): stat + patch present and
  scoped to the written file; empty-change job → exit 0 + message; running job → 4; unknown → 3;
  read-only job → 2; removed-worktree → 3.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add ccodex diff for worktree jobs`

---

### Task 5: `ccodex apply`

**Files:** modify `ccodex.ps1`; extend `tests/DiffApply.tests.ps1` (apply section).

**Interfaces:**
- `Invoke-CcodexApplyCommand([Parameter(Mandatory)][string]$JobId, [string]$StateRoot = $env:LOCALAPPDATA) -> [pscustomobject]{ WrapperExitCode; Stdout; Message }`
  — id/terminality/worktree preconditions exactly as `diff` (3/4/2/3). Additional preconditions:
  job status is `done` (failed/timed_out/cancelled → 2 with "only done jobs can be applied");
  main repo working tree clean per `git status --porcelain` (else 2 naming the dirty state);
  empty change set → no-op message, exit 0.
  Mechanism: `git -C <worktree> format-patch <base>..HEAD --stdout` piped to
  `git -C <main_repo> am --3way`. Success → print applied range (`<base>..<new HEAD>`), exit 0.
  Failure → `git -C <main_repo> am --abort` (best-effort), verify the main repo is back to its
  pre-apply HEAD and clean, exit **25** with a message naming the conflicting files (parsed from
  the am output) and pointing at `ccodex diff <job_id>`.
- Applying the same job twice: ANY nonzero `am` outcome (textual conflict, empty/already-applied
  patch, or other failure) maps to exit 25 with the main repo restored to its pre-apply state;
  test the already-applied case separately from the textual-conflict case (no special-case
  tracking in this phase).

- [ ] Step 1: failing tests — clean apply (main repo gains the snapshot commit content; author
  identity preserved from snapshot); dirty main repo → 2, repo untouched; conflict (pre-edit the
  same file in the main repo post-base) → exit 25, `git -C main status --porcelain` empty and
  HEAD unchanged; failed-status job → 2; empty change → 0 no-op.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: add explicit ccodex apply with conflict fail-fast`

---

### Task 6: Cleanup and dispatcher integration

**Files:** modify `lib/Cleanup.ps1`, `ccodex.ps1` (supported-commands message); extend
`tests/Cleanup.tests.ps1`.

- Cleanup deletes a job's worktree (via `Remove-CcodexJobWorktree`, using the recorded
  `main_repo`) before deleting its job dir; orphaned worktree directories under
  `worktrees\` whose job dir no longer exists are swept too (dangling handling, best-effort +
  reported). `--dry-run` lists worktrees alongside jobs.

- [ ] Step 1: failing tests — old done implement job → job dir, index, AND worktree gone +
  `git worktree list` in the main repo no longer shows it; dangling worktree swept; dry-run
  lists it.
- [ ] Step 2: red. Step 3: implement. Step 4: green + FULL suite.
- [ ] Step 5: commit — `feat: sweep ccodex worktrees during cleanup`

---

### Task 7: E2E, docs, live smoke

**Files:** create `tests/ImplementE2E.tests.ps1`; modify `README.md`,
`templates/claude-command-ccodex.md`, `templates/claude-rule-ccodex-delegation.md`,
`templates/claude-skill-ccodex.md` (verify the worktree/diff/apply claims match implemented
behavior; fix only inaccuracies — the skill is availability-gated); re-run `install.ps1`.

- [ ] Step 1: `tests/ImplementE2E.tests.ps1` — shim-level (RealInvocation-style staging):
  piped implement task → `submit` → `wait` (fixture writes a file via `-C` parsing) →
  `diff` shows it → `apply` lands it in the main repo → main repo file content correct →
  `cleanup --older-than 0d` removes job + worktree. Conflict path once end-to-end (apply → 25).
  JSONL-never-on-stdout assertions on diff/apply outputs.
- [ ] Step 2: README per CLAUDE.md — Phase 4 done: implement/worktree usage + diff/apply
  examples + exit 25 row + Quick-reference rows ("delegate an implementation", "inspect/apply a
  worker's changes"); update the mode/access table; `/ccodex` command + rule gain the
  delegate-implement → review diff → apply-decision flow (Claude reviews the diff BEFORE
  apply; never auto-apply). Verify every claim against the code.
- [ ] Step 3: live smoke (one real codex call, evidence in the report only): implement job
  against a THROWAWAY temp git repo ("create HELLO.md containing exactly 'hello from codex'"),
  then `diff`/`apply`/verify file, then `cleanup` the job. DONE_WITH_CONCERNS with evidence if
  the environment blocks it.
- [ ] Step 4: install.ps1 re-run + byte-match verify; FULL suite green.
- [ ] Step 5: commit — `feat: document and verify ccodex worktree implementation flow`

---

## Self-Review

| Design requirement | Covered by |
|---|---|
| Worktrees under state root, detached at recorded base | Task 1 |
| Snapshot finalization (deterministic diff/apply basis) | Tasks 1/3 |
| implement unlocks, worktree default; test may use worktree; review/brainstorm never | Task 2 |
| Codex runs with `-C <worktree>` + workspace-write; main repo never written by jobs | Task 3 |
| main_repo/worktree_repo/base_commit recorded | Task 3 |
| `diff` exact contract incl. cleaned-worktree case | Task 4 |
| `apply` explicit, clean-tree precondition, `am --3way`, conflict → 25 + untouched repo | Task 5 |
| cleanup removes/sweeps worktrees | Task 6 |
| End-to-end + docs + live evidence + no-auto-apply guidance | Task 7 |
