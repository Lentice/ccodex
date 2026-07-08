# Repository Guidelines

## What this is

`ccodex` is a standalone, project-agnostic PowerShell CLI tool. It is developed here, in its own
independent git repository, and installed to a user-level `PATH` directory
(`%USERPROFILE%\.local\bin\ccodex\`) so any project can call it. Do not assume this repo lives
inside, or is coupled to, any other project.

All planned phases (1, 2a, 2a.1, 2b, 2c, 3, 4, 5) are implemented and verified; ongoing work is
maintenance, hardening, and incremental features.

## Where to read what (developer docs — use these, not README.md)

`README.md` is **user-facing only** (purpose, features, install, concise usage). Never use it as
a technical source when developing; the documents below are the developer-facing truth:

| When you need... | Read |
|---|---|
| Project state, doc index, verification history — **start here** | `docs/2026-07-07-ccodex-handoff.md` |
| Binding contracts: exit codes, `status.json` schema, worker prompt, backend, encoding; dated amendments are authoritative where they refine earlier text | `docs/2026-07-03-ccodex-adapter-design.md` |
| **Before changing `ccodex.ps1` or `lib/`**: regression-guarded pitfalls, test recipes, fixture env vars, host quirks, post-review hardening notes, accepted minors | `docs/2026-07-07-ccodex-dev-notes.md` |
| Exact current behavior of a command: full per-command/flag reference, exit-code and failure-class tables, `status.json` field notes, repo/module layout | `docs/2026-07-08-ccodex-reference.md` |
| How past work was specified and committed (style/granularity reference; not work items) | executed phase plans under `docs/` (`YYYY-MM-DD-<name>.md`) |

## Documentation maintenance (after every user-visible change)

A change is not done until the docs reflect the new reality, in the same piece of work — never
as a deferred task:

- **`README.md`** (user-facing): update usage examples, features, and the short cheat sheet for
  anything a user can now do or must now do differently.
- **`docs/2026-07-08-ccodex-reference.md`** (developer-facing): update the command/flag
  reference and contract tables for the same change.
- **`templates/`** (the installed Claude integration): when a change adds or alters a command,
  flag, or behavior Claude should know about, update the matching template(s) —
  `claude-skill-ccodex.md`, `claude-command-ccodex.md`, `claude-rule-ccodex-delegation.md`,
  `worker-prompt.md` — in the same piece of work. Stale templates mean every future Claude
  session is taught the old behavior.
- Re-run `install.ps1` after user-facing or template changes, then **verify the installed copies
  byte-match the repo** (e.g. compare `Get-FileHash` per file) — at minimum the CLI under
  `%USERPROFILE%\.local\bin\ccodex\` and the installed skill at
  `%USERPROFILE%\.claude\skills\ccodex\SKILL.md`, which MUST carry the latest template content
  (plus the installed command/rule when their templates changed).

## Testing

No Pester dependency (see the Phase 1 plan's Global Constraints for why). Tests are plain
PowerShell assertion scripts under `tests/`, run directly with `pwsh -NoProfile -File <test>.ps1`
and checked by exit code, not by a test-runner framework. Every change must leave the FULL suite
green (run recipe in dev-notes), not just the new file.

## Coding conventions

- PowerShell 7+ only.
- All wrapper-authored files (`prompt.md`, `command.txt`, `debug.json`, `status.json`, logs) are
  UTF-8 **without BOM**.
- Keep `lib/*.ps1` files single-responsibility and independently testable via dot-sourcing.
- Follow the exact function signatures, exit codes, and file formats defined in the design spec —
  they are a stable contract other tooling (the installed Claude skill/command/rule) depends on.
  Contracts are append-only: never rename or repurpose an existing exit code or status field.

## Git

This repo is committed to normally: one commit per implementation task, following TDD steps
(test, verify red, implement, verify green, commit). No co-author trailers. Never commit
`.superpowers/`. There is no external git policy restricting this repo — that restriction only
applies to the separate project this tool was originally designed inside.
