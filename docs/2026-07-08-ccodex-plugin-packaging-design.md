# ccodex plugin packaging — design

Date: 2026-07-08
Status: validated design (user-approved in brainstorming), pre-implementation.
Scope: repackage ccodex as a Claude Code plugin and make the plugin the only distribution
channel. No changes to the CLI's runtime contracts (exit codes, `status.json`, worker prompt,
backend, encoding) — those remain governed by `2026-07-03-ccodex-adapter-design.md`.

## Context and goal

Installation today requires cloning the repo, running `install.ps1`, and ensuring
`%USERPROFILE%\.local\bin` is on PATH. Claude Code's plugin system reduces this to two slash
commands and adds automatic updates (checked at session start via `plugin.json` version / git
commit SHA). The repo doubles as its own marketplace, so no separate marketplace repo is needed:

```
/plugin marketplace add Lentice/ccodex
/plugin install ccodex@ccodex
```

Local development install: `/plugin marketplace add D:\path\to\ccodex` (local path), then the
same `/plugin install`.

## Decision log

| # | Decision | Rationale |
|---|---|---|
| 1 | The CLI is available **only inside Claude Code sessions**, invoked by full path under `${CLAUDE_PLUGIN_ROOT}`. No PATH install, no files written outside the plugin's own mechanisms. | Cleanest fit for the plugin contract; ccodex is designed to be called by an AI assistant, not by humans in a terminal. Auto-update leaves zero residue. |
| 2 | The plugin is the **only** distribution channel: `install.ps1` and the `templates/claude-*` install sources are deleted; Claude integration content moves to native `skills/`, `commands/`, `hooks/` directories. | Single source of truth; no dual-path skill text; local testing works via local-path marketplace add. The author is the only current user (no external installs to migrate — see rollout). |
| 3 | **Windows-only** stays the supported platform. The SessionStart hook silently no-ops on non-Windows (and when pwsh is missing). | Cross-platform would touch the path layer, worker detach, and every test, with no machine to verify on. Deferred as future work. |
| 4 | **Repo root is the plugin** (`.claude-plugin/` at root, `marketplace.json` source `"./"`). `docs/` and `tests/` ship in the plugin cache copy — harmless (plain text, a few hundred KB). | Avoids a large restructure (test paths, doc references). Claude Code copies the whole plugin root; there is no exclude mechanism. |
| 5 | The SessionStart hook injects a **slim pointer** (~10 lines: presence, resolved CLI path, checkpoint trigger, "see the ccodex skill"); the full delegation policy folds into `SKILL.md`. | Saves per-session tokens across all projects. Trade-off accepted: checkpoint details (cost guards, triage, failure table) require the model to consult the skill. |
| 6 | One-time migration of the author's machine (remove all `install.ps1`-installed copies, switch to plugin) is **in scope** as a rollout step. Migration documentation for third parties is **out of scope** (no external users exist). | User request. |

## Target repo layout

```
ccodex/                          (= plugin root = marketplace root)
├── .claude-plugin/
│   ├── plugin.json              name, description, version (manual semver), author
│   └── marketplace.json         name "ccodex", owner, plugins: [{ name "ccodex", source "./" }]
├── skills/
│   └── ccodex/SKILL.md          main skill (absorbs the delegation rule; plugin-root invocation)
├── commands/                    ask.md, cleanup.md, doctor.md, implement.md, jobs.md,
│                                resume.md, review.md   → /ccodex:ask … /ccodex:review
├── hooks/
│   ├── hooks.json               SessionStart (matcher: startup|clear|compact) → run-hook.cmd
│   ├── run-hook.cmd             cmd/sh polyglot: Windows → pwsh session-start.ps1; else exit 0
│   └── session-start.ps1        emits additionalContext JSON (slim pointer)
├── ccodex.ps1                   unchanged entry point
├── ccodex.cmd                   kept: self-relative dev shim (%~dp0ccodex.ps1) for dev terminals
├── lib/                         unchanged except WorkerPrompt.ps1 (new fallback tier)
├── templates/worker-prompt.md   kept: runtime worker-prompt template (now also the built-in default)
├── docs/  tests/                unchanged locations; ship in cache copy (accepted)
└── install.ps1                  DELETED (with tests/Install.tests.ps1)
```

Naming note: as a plugin skill, the main skill surfaces namespaced as `ccodex:ccodex`
(cf. `superpowers:brainstorming`); the per-function commands keep their exact current names
(`/ccodex:ask`, `/ccodex:review`, …).

## Manifests

`.claude-plugin/plugin.json`:

```json
{
  "name": "ccodex",
  "description": "Delegate scoped reviews, second opinions, and background jobs to Codex CLI (Windows, pwsh 7+).",
  "version": "1.0.0",
  "author": { "name": "Lentice" }
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "ccodex",
  "owner": { "name": "Lentice" },
  "plugins": [
    {
      "name": "ccodex",
      "source": "./",
      "description": "Codex CLI delegation wrapper + Claude integration (skill, commands, hook)."
    }
  ]
}
```

Versioning rule (goes into `CLAUDE.md`): bump `plugin.json` `version` in the same commit as any
user-visible change; auto-update picks it up at the user's next session start.

## Invocation contract

Canonical invocation forms, used verbatim in `SKILL.md`, every `commands/*.md`, and the hook
pointer (Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` when loading plugin skill/command
content; the hook script reads the real path from its `CLAUDE_PLUGIN_ROOT` environment variable,
so the pointer always carries a resolved path even if substitution is unavailable somewhere):

- PowerShell tool: `& "${CLAUDE_PLUGIN_ROOT}\ccodex.ps1" <command> [args]` — check `$LASTEXITCODE`.
- Bash tool: `pwsh -NoLogo -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/ccodex.ps1" <command> [args]`.

Always quoted (user profile paths may contain spaces). State root stays `LOCALAPPDATA` — the
plugin cache directory is version-swapped on update and must never hold state. A background
worker launched from an old version directory finishes normally (old cache versions persist ~7
days); no handling needed.

## Worker-prompt resolution (lib/WorkerPrompt.ps1)

Three tiers, first hit wins; error only when all three are missing:

1. `<repo_root>/.ccodex/worker-prompt.md` (project-local override — unchanged)
2. `%APPDATA%\ccodex\templates\worker-prompt.md` (user-level override — kept, but no longer
   installed by anything; now optional)
3. **new:** `$PSScriptRoot\..\templates\worker-prompt.md` (script-relative built-in default —
   always present in the repo/plugin copy)

`doctor` Check 3b updates to accept the script-relative default as "template present". The
error message drops its "Run install.ps1" hint.

## Content migration

| Today (`templates/`) | After |
|---|---|
| `claude-skill-ccodex.md` | `skills/ccodex/SKILL.md`. Rewrite availability section: remove PATH/`install.ps1` instructions; state plugin-root invocation + requirements (Windows, pwsh 7+, authenticated Codex CLI). Absorb the full delegation-rule content (checkpoints, auto/ask/off, cost guards, triage, failure-class table, resume semantics, apply gating, lifecycle hygiene), deduplicated against the skill's existing hard-rules/failure sections. |
| `claude-commands/*.md` (7) | `commands/*.md`, same basenames. Replace bare `ccodex` invocations with the canonical forms above. |
| `claude-command-ccodex.md` (umbrella `/ccodex`) | Deleted. Redundant with `SKILL.md`; under a plugin it could only be `/ccodex:ccodex`, colliding with the skill name. |
| `claude-rule-ccodex-delegation.md` | Deleted. Policy content merges into `SKILL.md`; session presence comes from the hook pointer. |
| `worker-prompt.md` | Stays in `templates/` (runtime file, now also the tier-3 default). |

## SessionStart hook

`hooks/hooks.json` registers `run-hook.cmd session-start` for `SessionStart`
(matcher `startup|clear|compact`), the polyglot pattern proven by superpowers:

- **Windows branch (cmd):** locate `pwsh` (PATH); if found, run
  `pwsh -NoLogo -NoProfile -File "<hook dir>\session-start.ps1"`; if not found, `exit /b 0`
  silently (ccodex cannot work without pwsh anyway; the skill's availability check reports it
  when actually used — a per-session hook error would be noise).
- **Unix branch (sh):** `exit 0` silently — graceful Windows-only degradation for mac/Linux
  users who install anyway.

`session-start.ps1` prints a JSON object with `hookSpecificOutput.additionalContext` containing
the slim pointer, and exits 0 even on internal failure (never pollutes the session). Pointer
content (final wording tuned during implementation, semantics fixed here):

```
<ccodex-plugin>
ccodex is installed (Codex CLI delegation wrapper; Windows + pwsh 7).
Invoke (PowerShell): & "<resolved plugin root>\ccodex.ps1" <command> [args]   — read $LASTEXITCODE
Invoke (Bash): pwsh -NoLogo -NoProfile -File "<resolved plugin root>/ccodex.ps1" <command> [args]
Delegation checkpoints: after finishing a feature/fix (post-change) and after writing or
updating a plan/spec (post-plan), read the repo's .ccodex/ccodex.json `delegation` section and
apply it as the ccodex skill specifies (auto/ask/off, cost guards, finding triage). An explicit
user request for a Codex review/opinion is always honored.
For commands, flags, failure handling, and the full policy: invoke the ccodex skill.
</ccodex-plugin>
```

## Deletions and documentation updates

Delete: `install.ps1`, `tests/Install.tests.ps1`, `templates/claude-skill-ccodex.md`,
`templates/claude-command-ccodex.md`, `templates/claude-commands/` (entire directory),
`templates/claude-rule-ccodex-delegation.md`.

Update in the same piece of work (per the repo's documentation-maintenance rule):

- `README.md` — install section becomes the two slash commands + requirements; local-dev
  install via local-path marketplace add; drop `install.ps1`/PATH instructions.
- `CLAUDE.md` — replace the "re-run install.ps1 + verify installed copies byte-match" rule with:
  templates for Claude integration now live in `skills/`, `commands/`, `hooks/`; bump
  `plugin.json` version on user-visible changes; verify via local marketplace add + reinstall.
- `docs/2026-07-08-ccodex-reference.md` — installation and repo/module layout sections.
- `docs/2026-07-07-ccodex-handoff.md` and `docs/2026-07-07-ccodex-dev-notes.md` — record this
  change per repo convention (dated entry; any new pitfalls, e.g. hook JSON output rules).

## Error handling summary

- Hook: silent exit 0 on non-Windows, on missing pwsh, and on internal script failure.
- CLI: no contract changes at all — exit codes, `status.json` fields, and `failure_reason`
  classes are untouched (append-only contract preserved).
- Plugin update mid-job: old version directory persists ~7 days; running workers finish
  normally; state lives in `LOCALAPPDATA`.

## Testing

Plain PowerShell assertion scripts (no Pester), TDD order, full suite green per dev-notes:

- **New `tests/Plugin.tests.ps1`:** both manifests parse as JSON with required fields
  (`plugin.json`: name; `marketplace.json`: name, owner.name, plugins[0].name/source); every
  file/dir the plugin references exists (`skills/ccodex/SKILL.md`, all `commands/*.md`,
  `hooks/hooks.json` + the two hook files); skill/command bodies contain the canonical
  `${CLAUDE_PLUGIN_ROOT}` invocation and no stale PATH-install references (`install.ps1`,
  `%USERPROFILE%\.local\bin`); `session-start.ps1` run with an injected "Windows" switch and a
  fake `CLAUDE_PLUGIN_ROOT` emits valid JSON whose `additionalContext` contains the resolved
  path, and with the "non-Windows" switch emits nothing and exits 0 (platform is a parameter
  for testability, defaulting to the real environment).
- **`tests/WorkerPrompt.tests.ps1`:** add tier-3 script-relative fallback cases and the full
  three-tier precedence.
- **Doctor tests:** Check 3b passes with only the script-relative template present.
- **Removed:** `tests/Install.tests.ps1` (with `install.ps1`).
- **Manual E2E (verification, not scripted):** `/plugin marketplace add <local path>` →
  `/plugin install ccodex@ccodex` → confirm `/ccodex:review` etc. appear and the hook pointer is
  injected → run one real scoped review through the plugin path.

## Rollout (author's machine, after implementation verified)

1. Local marketplace add + install; verify skill/commands/hook all work.
2. Remove the old `install.ps1` artifacts: `%USERPROFILE%\.local\bin\ccodex\` and the
   `ccodex.cmd` shim next to it, `~/.claude/commands/ccodex.md`, `~/.claude/commands/ccodex/`,
   `~/.claude/rules/ccodex-delegation.md`, `~/.claude/skills/ccodex/`, and
   `%APPDATA%\ccodex\templates\worker-prompt.md` (stock copy, not customized). The
   `~/.local/bin` PATH entry itself stays (harmless, may serve other tools).
3. After pushing to GitHub, replace the local marketplace with the real source
   (`/plugin marketplace add Lentice/ccodex`).

## Out of scope

- Cross-platform (macOS/Linux) support — future, separate piece of work.
- Migration documentation for external users — none exist.
- Any change to the CLI's runtime behavior or contracts.
