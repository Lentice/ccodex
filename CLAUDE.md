# Repository Guidelines

## What this is

`ccodex` is a standalone, project-agnostic PowerShell CLI tool. It is developed here, in its own
independent git repository, and installed to a user-level `PATH` directory
(`%USERPROFILE%\.local\bin\ccodex\`) so any project can call it. Do not assume this repo lives
inside, or is coupled to, any other project.

## Source of truth

- `docs/2026-07-07-ccodex-handoff.md` — **start here**: current state, remaining work, and the
  index of every other document.
- `docs/2026-07-03-ccodex-adapter-design.md` — the full design spec across all phases; its dated
  amendment sections are authoritative where they refine earlier text.
- `docs/2026-07-07-ccodex-dev-notes.md` — conventions, regression-guarded pitfalls, and test
  recipes; read before changing `ccodex.ps1` or `lib/`.
- `docs/2026-07-07-ccodex-phase2b-plan.md` — the current (next unimplemented) phase's
  task-by-task plan. Phases 4 and 5 have their own plan files under `docs/` following the same
  `YYYY-MM-DD-<name>.md` naming; executed phase plans remain as historical record.

## README maintenance

**After completing each phase (Phase 1, Phase 2, Phase 3, Phase 4, ...), update `README.md`
before considering the phase done.** Specifically:

- Move the phase from "in progress" to done in the Status and Roadmap sections.
- Update the "Implemented so far" / "Not yet implemented" lists to match reality.
- Update or remove the "target shape, not current behavior" caveat once the described commands
  actually work.
- Add or correct usage examples for anything the phase newly makes callable.

Do this as part of the phase's own work, not as a separate deferred task — a phase is not
finished until README.md reflects what the tool can actually do.

## Testing

No Pester dependency (see the Phase 1 plan's Global Constraints for why). Tests are plain
PowerShell assertion scripts under `tests/`, run directly with `pwsh -NoProfile -File <test>.ps1`
and checked by exit code, not by a test-runner framework.

## Coding conventions

- PowerShell 7+ only.
- All wrapper-authored files (`prompt.md`, `command.txt`, `debug.json`, `status.json`, logs) are
  UTF-8 **without BOM**.
- Keep `lib/*.ps1` files single-responsibility and independently testable via dot-sourcing.
- Follow the exact function signatures, exit codes, and file formats defined in the design spec —
  they are a stable contract other tooling (e.g. a future Claude slash command) will depend on.

## Git

This repo is committed to normally: one commit per implementation task, following the plan's TDD
steps (test, verify red, implement, verify green, commit). There is no external git policy
restricting this repo — that restriction only applies to the separate project this tool was
originally designed inside.
