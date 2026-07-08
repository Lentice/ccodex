---
description: Check on, collect, or manage background ccodex jobs (status/wait/read/tail/cancel/debug).
argument-hint: [job_id] [wait|read|tail|cancel|debug]
---

Manage background ccodex jobs. `$ARGUMENTS` may name a job id and/or an action; otherwise act on
the jobs submitted earlier in this conversation.

```powershell
ccodex status <job_id>              # one-line lifecycle check (running jobs show health=ok|stale)
ccodex wait <job_id> --wait-timeout-sec 600   # block for the result; exit 20 = still running, re-wait
ccodex read <job_id>                # non-blocking result read (exit 4 = not finished yet)
ccodex tail <job_id> --lines 80     # raw log tail for a job that looks stuck
ccodex debug <job_id>               # compact diagnosis + suggested next command
ccodex cancel <job_id>              # stop a job that's wrong or no longer needed — don't let it run out
```

Reactions:

- `wait` exit `20` just means still running — re-run `wait`, don't treat it as failure.
- A job that looks wrong gets `debug` FIRST; follow its suggested next command.
- `status … health=stale` or `possibly-stale` → check `tail`/`debug` before assuming it died.
- Terminal failures: react by exit code + `status.json.failure_reason` per the `ccodex` skill
  (quota → report and stop; auth → suggest `codex login`; never retry-loop).
- Cancel the moment a background job is known to be the wrong task — a cancelled job later
  reads back as exit `22`.
