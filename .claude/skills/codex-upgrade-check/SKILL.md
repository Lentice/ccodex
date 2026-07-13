---
name: codex-upgrade-check
description: Use when the installed Codex CLI has been upgraded (codex --version changed, user says "codex upgraded", new models/effort levels appeared), or when previously working ccodex live calls start failing with argument-parse errors, empty results (exit 11), or unclassified failures right after a Codex update.
---

# Codex CLI Upgrade Check

ccodex hard-codes assumptions about the external `codex` CLI. A Codex upgrade can silently break
them: fixture tests stay green (fake-codex accepts ANY argument order), and failures only surface
live. This checklist re-verifies every assumption and updates code, docs, and templates together.

**Worked example:** the "Codex CLI 0.144.1 re-verification amendment (2026-07-13)" in
`docs/2026-07-03-ccodex-adapter-design.md` — a complete instance of this checklist.

**Doc shorthand used below:** dev-notes = `docs/2026-07-07-ccodex-dev-notes.md`,
reference = `docs/2026-07-08-ccodex-reference.md`, handoff = `docs/2026-07-07-ccodex-handoff.md`,
design spec = `docs/2026-07-03-ccodex-adapter-design.md`.

## 1. Snapshot the new interface (free, no quota)

```powershell
codex --version
codex --help                 # top-level options incl. --ask-for-approval values
codex exec --help            # exec-level: --sandbox values, --json, --color, -C, -o, -m, -c
codex exec resume --help     # resume positional + option set
```

Compare against the binding invocation contract in the design spec ("The wrapper uses this
command shape..." plus the latest dated amendments, which win over earlier text).

## 2. Check each wrapper assumption

| Assumption | Code (and its tests) | What to check |
| --- | --- | --- |
| Full exec/resume argv shape | `Build-CcodexCodexArgs` (`lib/ModeAccess.ps1`; `tests/ModeAccess.tests.ps1`), `Build-CcodexResumeArgs` (`lib/Resume.ps1`; `tests/Resume.tests.ps1`) | Every flag still exists at the level used: top-level `--ask-for-approval never`; exec-level `--sandbox read-only|workspace-write`, `--json`, `--color never`, `-C`, `--output-last-message`, `-m`, `-c`; prompt as trailing `-` on stdin; `resume <thread_id>` spliced after exec options |
| Effort allowlist mirrors Codex's `ReasoningEffort` enum | `ConvertTo-CcodexEffort` (`ccodex.ps1`; `tests/RunCommand.tests.ps1`) | Re-derive the enum from upstream Codex source (`codex-rs/protocol/src/openai_models.rs` on github.com/openai/codex) — e.g. `npx ctx7@latest docs /openai/codex "model_reasoning_effort allowed values"`. If it changed, update allowlist via TDD (test first, red, green). **Do this BEFORE step 3 if the live call will use a new value.** |
| Thread-id JSONL event | `Get-CcodexCodexThreadId` (`lib/FailureClassify.ps1`; `tests/FailureClassify.tests.ps1`) | `{"type":"thread.started","thread_id":"..."}` still emitted under `--json` — confirm in the live job's `codex-events.jsonl` (step 3) |
| Failure-signature heuristics | `Get-CcodexFailureReason` (`lib/FailureClassify.ps1`) | Best-effort only: read the regex classes and compare against any failure wording you encounter. Do NOT deliberately trigger quota/auth failures — only act if a live failure misclassifies (wrong/absent `failure_reason` in `status.json`) |
| `codex --version` / `codex doctor` probes | `Invoke-CcodexDoctorCommand` (`ccodex.ps1`; `tests/Doctor.tests.ps1`) | Both subcommands still exist and exit 0 when healthy: run `ccodex doctor --no-smoke` (free) |
| Model examples in docs | `~/.codex/config.toml` (`model = ...`) shows the current family | If the family changed, grep the repo for the OLD example model name (see the model example in `README.md` before editing) and refresh every hit — examples only; `--model` is an unvalidated open set, no code change |

## 3. Live verification (MANDATORY, ~2 quota calls)

Fixture tests cannot catch placement/schema changes — a Phase 5 live smoke once caught a resume
arg-placement bug every fixture test missed. Use the REPO script, not the installed copy (it is
stale until step 5):

```powershell
# Pipeline + effort forwarding + thread capture + sandbox spawn probe, all in one call:
"Run 'git log --oneline -1' in this repository and reply with its exact output. If you cannot execute commands, reply SPAWN-FAIL: <error>." |
  pwsh -NoProfile -File .\ccodex.ps1 run --mode brainstorm --repo <this-repo> --effort <effort>
```

For `<effort>`: a newly added enum value if the enum grew (allowlist already updated per step 2);
otherwise any existing value the configured default model supports (`high` is a safe default).

Job artifacts live under `%LOCALAPPDATA%\ccodex\jobs\<repo_key>\<job_id>\`. The job id IS the
job directory name; directories are timestamp-prefixed, so the newest = last when sorted by
name. Inspect the new job dir — ALL of these must hold, else the contract broke:

- exit code `0`, and `result.md` contains the actual `git log` line (spawn works) or a
  `SPAWN-FAIL:` message (sandbox cannot spawn — update the host fact, see below);
- `command.txt` shows the intended argv shape;
- `status.json.codex_thread_id` is non-null and `codex-events.jsonl` has `thread.started`.

```powershell
"Reply with exactly the word RESUMED." | pwsh -NoProfile -File .\ccodex.ps1 resume <job_id>
# Pass: exit 0 and output exactly RESUMED (proves resume splicing still parses).
```

The spawn probe re-tests the `CreateProcessWithLogonW failed: 1385` host fact (dev-notes "Host
and environment facts") — update it in either direction if the outcome changed.

**If a live call fails:** react per the failure table (installed ccodex skill / README) — e.g.
exit 10 + `quota_or_rate_limit` → record the checklist as blocked on quota and stop the live
part; do not retry-loop. An argv-parse failure (codex exit 2 in `stderr.log`) means the
invocation contract itself broke: fix the builder via TDD, append a dated amendment to the
design spec describing the new shape, and call the break out explicitly in your report — never
silently redesign beyond restoring the documented behavior.

## 4. Update everything in the same piece of work

- **Code + tests** (TDD; leave the FULL suite green — `pwsh -NoProfile -File tests/run-tests.ps1 -Suite full`,
  details in dev-notes "Running the tests").
- **Docs:** dev-notes "Host and environment facts" (version line + spawn fact); design spec —
  append a new dated amendment (contracts are append-only; never rewrite the original text);
  reference — flag tables (`--effort` list appears twice); `README.md` — model/effort example;
  handoff — "Current state" entry.
- **Templates** (else future Claude sessions are taught the old interface):
  `templates/claude-skill-ccodex.md`, `templates/claude-command-ccodex.md`,
  `templates/claude-commands/*.md`, `templates/claude-rule-ccodex-delegation.md`,
  `templates/worker-prompt.md` — grep them for the changed flag/value/model names.
- **Reinstall + byte-verify:** re-run `install.ps1`, then `Get-FileHash` each pair:

  | Repo source | Installed copy |
  | --- | --- |
  | `ccodex.ps1`, `lib/*` | `%USERPROFILE%\.local\bin\ccodex\` |
  | `templates/claude-skill-ccodex.md` | `%USERPROFILE%\.claude\skills\ccodex\SKILL.md` |
  | `templates/claude-command-ccodex.md` | `%USERPROFILE%\.claude\commands\ccodex.md` |
  | `templates/claude-commands/<n>.md` | `%USERPROFILE%\.claude\commands\ccodex\<n>.md` |
  | `templates/claude-rule-ccodex-delegation.md` | `%USERPROFILE%\.claude\rules\ccodex-delegation.md` |
  | `templates/worker-prompt.md` | `%APPDATA%\ccodex\templates\worker-prompt.md` |

- **Commit** per repo policy (one commit per task, no co-author trailers).

## Red flags

- "The help text looks the same, skip the live call" — placement/schema bugs only surface live.
- "Tests are green, so it works" — fake-codex proves nothing about the real CLI.
- Updating code but not templates/docs — every future session learns the stale interface.
- Editing the original contract text instead of appending a dated amendment.
- Verifying with the installed `ccodex` before `install.ps1` re-ran — it still has the old code.
