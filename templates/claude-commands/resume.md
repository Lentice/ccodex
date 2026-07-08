---
description: Continue a finished ccodex job's Codex session with a follow-up, answer, or pushback — instead of starting a fresh memory-less run.
argument-hint: <job_id> [follow-up text]
---

Continue the same Codex session with `ccodex resume`. Use it when Codex's last answer was a
clarifying question, or a finding deserves pushback/refinement with the prior context intact.

1. Take the parent job id from `$ARGUMENTS` (or the most recent relevant ccodex job in this
   conversation). Compose the follow-up from the rest of `$ARGUMENTS` and the context.
2. Pipe the follow-up; the job id is the only positional:

```powershell
"<follow-up, answer, or pushback>" | ccodex resume <job_id>
```

Notes:

- `resume` creates a brand-new job (new id, `parent_job_id` lineage) and inherits the parent's
  mode/access/repo — never pass `--repo`/`--mode`/`--access` (exit `2`). `--model`/`--effort`
  are accepted per call.
- Chain further follow-ups off the NEWEST child job id, not the original parent.
- Exit `2` naming a scrubbed/absent thread id or worktree access, or a failure with
  `failure_reason: thread_expired`, means the session is gone — start a fresh
  `ccodex run` instead of retrying resume.
- Triage the reply like any Codex output: verify, then adopt or reject with reasons.
