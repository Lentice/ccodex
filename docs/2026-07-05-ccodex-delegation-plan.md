# ccodex Adapter Phase 2c (Scoped Review + Delegation Policy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox
> steps. Tests run with cwd = repo root: `pwsh -NoProfile -File tests/<name>.tests.ps1`.

**Goal:** implement the design's "Scoped review and delegation policy (2026-07-05)" section
(docs/2026-07-03-ccodex-adapter-design.md): a `ccodex review` subcommand that has Codex review a
path-scoped change range (generating the diff itself inside its read-only sandbox), a project
config reader for the `delegation` policy, a user-level Claude rules file that teaches every
session the delegation checkpoints, and docs.

## Global Constraints

- All Phase 1 / 2a / 2a.1 constraints still bind (full suite green after every task; UTF-8 no
  BOM; plain assertion tests; `ccodex.ps1` plain script with `$args`-based flag parsing; exit
  codes 0/2/3/4/10/11/12/20/23/24 only; single-writer status; no Phase 2b features).
- `ccodex review` is sugar over the existing `run` pipeline (mode `review`, access `read-only`):
  same job artifacts, same exit codes, same failure classification. It must not fork a second
  execution path.
- The delegation config lives at `<repo>/.ccodex/ccodex.json` (location already reserved by the
  design spec; configuration only — never job state). Missing file/section → defaults; malformed
  JSON → usage error (exit 2) naming the file.
- Only Task 3's install step touches user-level locations. Tests never write to the real user
  profile/%APPDATA%/%LOCALAPPDATA%.
- Git: one commit per task, exact message, NEVER any Co-Authored-By or trailer.

---

### Task 1: Project config reader

**Files:** Create `lib/Config.ps1`, `tests/Config.tests.ps1`.

**Interfaces:**
- `Get-CcodexProjectConfig([Parameter(Mandatory)][string]$RepoRoot) -> [pscustomobject]` with a
  `delegation` property carrying exactly:
  `review_after_changes` ('auto'|'ask'|'off', default 'ask'),
  `review_min_changed_lines` (int, default 50),
  `review_default_paths` (string[], default @()),
  `plan_second_opinion` ('auto'|'ask'|'off', default 'ask'),
  `max_codex_calls_per_task` (int, default 2).
- Missing `.ccodex/ccodex.json` or missing `delegation` section → full defaults. Partial section
  → per-key defaults. Invalid enum value or malformed JSON → throw
  `"ccodex: invalid .ccodex/ccodex.json: <detail>"` (callers map to exit 2).

- [ ] **Step 1: failing test** — defaults (no file), full round-trip, partial section, malformed
  JSON → Assert-Throws, invalid enum → Assert-Throws.
- [ ] **Step 2: verify red.** / **Step 3: implement.** / **Step 4: green + FULL suite.**
- [ ] **Step 5: commit** — `feat: add ccodex project config reader`

---

### Task 2: `ccodex review` subcommand

**Files:** Create `lib/ReviewPrompt.ps1`, `tests/ReviewCommand.tests.ps1`; modify `ccodex.ps1`
(dispatcher `review` case).

**Interfaces:**
- `Build-CcodexReviewPrompt([string]$Range, [bool]$Staged, [bool]$Working, [string[]]$Paths, [string]$Intent, [string]$Focus, [bool]$EmbedDiff, [string]$RepoRoot) -> string`
  — composes the review task text:
  - Default (self-diff) form: instructs Codex to run exactly
    `git diff <range> -- <paths>` (or `git diff --staged -- <paths>` / `git diff -- <paths>`)
    inside the repository, then review the resulting change; includes `$Intent` (one-line change
    intent) and `$Focus` when provided; always instructs: lead with severity-ordered findings
    (Critical/Important/Minor) each with file:line and a suggested fix; explicitly hunt for
    omissions/edge cases the author may have missed; end with a one-line verdict.
  - `$EmbedDiff` form: the wrapper runs the same `git diff` itself (from `$RepoRoot`), embeds the
    output capped at 100 KB with a per-file truncation note, plus `git diff --stat`.
  - Validation: exactly one of `$Range`/`$Staged`/`$Working` must be selected → otherwise throw a
    usage error naming the three options (callers map to exit 2). `$Range` must match
    `<a>..<b>` shape.
- Dispatcher `review` case: flags `--range <a>..<b>` | `--staged` | `--working`,
  `--path <p>` (repeatable), `--intent <text>`, `--focus <text>`, `--embed-diff`, plus the
  standard `--repo <path>` and hidden test flags. Builds the prompt, then routes through the
  EXISTING run pipeline exactly as a `run --mode review` with the composed text as the task
  content (positional-task channel internally; piped stdin is not consumed by `review`).
  Success prints only Codex's findings (result.md); failures behave exactly like `run` failures
  (same codes + failure_reason hints).

- [ ] **Step 1: failing tests** — prompt composition: self-diff form contains the exact
  `git diff abc..def -- lib/ src/x/` line, intent/focus included when given, severity
  instruction present; staged/working variants; embed form contains the stat block and cap note
  (use a temp repo with a real small diff); zero/two-of-three selection → Assert-Throws; range
  shape validation. Shim-level E2E against fake-codex (npm-shaped PATH staging like
  RealInvocation): `ccodex review --range <a>..<b> --path lib/ --intent "x"` → exit 0, fixture
  result printed, and the job's `prompt.md` contains the git-diff instruction with the exact
  paths; invalid flag combo → exit 2.
- [ ] **Step 2: verify red.** / **Step 3: implement.** / **Step 4: green + FULL suite.**
- [ ] **Step 5: commit** — `feat: add ccodex review subcommand with path scoping`

---

### Task 3: Delegation rule file, /ccodex update, install

**Files:** Create `templates/claude-rule-ccodex-delegation.md`; modify
`templates/claude-command-ccodex.md`, `install.ps1`; create `tests/Install.tests.ps1`.

**Content contract:**
- `templates/claude-rule-ccodex-delegation.md` (installed to
  `~/.claude/rules/ccodex-delegation.md`): teaches a Claude session — read
  `.ccodex/ccodex.json` `delegation` at the repo root; apply the two fixed checkpoints
  (post-change → `review_after_changes`; post-plan → `plan_second_opinion`) with auto/ask/off
  semantics; compose `ccodex review --range <base>..HEAD --path ... --intent ...` (submodule:
  `--repo <submodule>`); skip when the diff is under `review_min_changed_lines`; respect
  `max_codex_calls_per_task`; triage every Codex finding before acting (verify, then adopt or
  reject with a stated reason); failure reactions per README's failure-class table (quota →
  note and continue, never retry-loop); never auto-delegate generative work.
- `templates/claude-command-ccodex.md`: add the `ccodex review` one-liners (range/staged/working,
  submodule recipe) alongside the existing run/submit guidance.
- `install.ps1`: copy the rule template to `%USERPROFILE%\.claude\rules\ccodex-delegation.md`
  (create dir, overwrite, print destination), keeping all existing install steps.
- `tests/Install.tests.ps1`: run install.ps1 with `-InstallDir`/`-TemplatesDir` overridden to a
  temp root AND the rule/command destinations parameterized (add optional `-ClaudeDir` param to
  install.ps1, default `%USERPROFILE%\.claude`, so the test never touches the real profile);
  assert all copied files exist and byte-match their templates; run twice to prove idempotence.

- [ ] **Step 1: failing test (Install.tests.ps1).** / **Step 2: verify red.**
- [ ] **Step 3: implement templates + install changes.**
- [ ] **Step 4: green + FULL suite; then run the real `pwsh -NoProfile -File install.ps1` once
  and verify `~/.claude/rules/ccodex-delegation.md` and `~/.claude/commands/ccodex.md` exist and
  match the templates.**
- [ ] **Step 5: commit** — `feat: add ccodex delegation rule and scoped-review guidance`

---

### Task 4: README + live scoped-review smoke

**Files:** Modify `README.md`.

- [ ] **Step 1:** README gains: `ccodex review` usage (all three range forms + `--path` +
  submodule recipe), the `.ccodex/ccodex.json` delegation schema with defaults and semantics,
  and a pointer to the installed rule file. Verify every claim against the actual code/flags.
- [ ] **Step 2: live smoke (one-time, real codex; evidence in the task report, NOT tests/):**
  `ccodex review --range d8253f5..HEAD --path lib/ --intent "Phase 2a/2a.1/2c async and review features" --repo D:\Documents\GitHub\ccodex`
  → expect severity-ordered findings on stdout, exit 0; record command + verbatim output + exit
  code. If codex auth/network fails, record evidence and report DONE_WITH_CONCERNS.
- [ ] **Step 3:** full suite green.
- [ ] **Step 4: commit** — `docs: document ccodex scoped review and delegation policy`

---

## Self-Review

| Design requirement | Covered by |
|---|---|
| Path-scoped review, self-diff strategy, embed fallback | Task 2 |
| Submodule scoping via `--repo` | Task 2 tests + Task 4 README recipe |
| review = sugar over run pipeline (same artifacts/codes/classification) | Task 2 (dispatcher routes through run pipeline) |
| `.ccodex/ccodex.json` delegation config + defaults + validation | Task 1 |
| Fixed checkpoints / auto-ask-off semantics taught to every session | Task 3 rule file |
| User never re-prompts the policy | Task 3 (installed user-level rule) |
| Quality guards (triage, no generative auto-delegation, cost caps) | Task 3 rule content + Task 1 config keys |
| Verified live | Task 4 live smoke |
