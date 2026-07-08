---
description: Preview and run the ccodex retention sweep (delete aged terminal jobs, optionally scrub stale Codex thread ids).
argument-hint: [--older-than <Nd|Nh>] [--scrub-thread-ids] [--dry-run]
---

Reclaim disk and clear stale ccodex job state. ALWAYS preview first, then delete:

```powershell
ccodex cleanup --dry-run                              # what would be removed (default: terminal jobs >14d)
ccodex cleanup --older-than 7d                        # actually delete aged terminal jobs
ccodex cleanup --older-than 7d --scrub-thread-ids     # also blank old jobs' codex_thread_id
```

Notes:

- Running and young jobs are never touched; worktree jobs get their worktree directory swept
  with the job dir.
- `--scrub-thread-ids` makes old jobs non-resumable on purpose (session hygiene); mention that
  consequence when using it.
- Pass any `$ARGUMENTS` through (e.g. a custom `--older-than`, `--repo` to narrow the sweep).
- This is housekeeping — it needs no delegation-policy checkpoint and doesn't count against the
  per-task Codex call cap.
