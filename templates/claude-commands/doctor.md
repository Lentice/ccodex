---
description: Diagnose the ccodex/Codex environment (auth, sandbox, state root) — run this first when failures look environment-shaped rather than task-specific.
argument-hint: [--no-smoke]
---

Run the ccodex health check and interpret it for the user.

```powershell
ccodex doctor            # full check, includes a live Codex smoke call
ccodex doctor --no-smoke # skip the live call (quota-friendly; use when quota is already suspect)
```

Use it as the FIRST move whenever a ccodex failure looks environment-shaped rather than
task-specific: `failure_reason` of `auth`, `quota_or_rate_limit`, or `permission_or_sandbox`,
or the `CreateProcessWithLogonW failed: 1385` sandbox signature. It isolates whether Codex
itself, the wrapper, or the state root is broken, so you react to the real cause instead of
guessing.

Report each check's verdict plainly. Typical follow-ups: `auth` → the user runs `codex login`;
quota → report the limit and continue without Codex (never retry-loop); sandbox/spawn issues →
prefer `--embed-diff` review forms and narrower scopes. Pass `$ARGUMENTS` through (e.g.
`--no-smoke`) when given.
