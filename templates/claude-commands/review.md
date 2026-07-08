---
description: Scoped Codex code review of a diff (range/staged/working) via ccodex; add --background to run it as a background job.
argument-hint: [--range <base>..<head> | --staged | --working] [--path <p>] [--background] [focus…]
---

Run a scoped Codex review with `ccodex review`. `$ARGUMENTS` may carry explicit selectors/paths,
`--background`, and/or free-text focus; fill in anything missing from the conversation context.

1. Pick exactly one diff selector (from `$ARGUMENTS` if given, else from where the changes live):
   already committed → `--range <base>..HEAD`; staged → `--staged`; unstaged → `--working`.
2. Check the matching `git diff --stat` and pick 1–3 `--path` values covering everything touched.
3. Compose a one-line `--intent` from the change's purpose; put any free-text focus from
   `$ARGUMENTS` into `--focus`. Always pass `--embed-diff` unless this host's Codex sandbox is
   verified to spawn processes.

```powershell
ccodex review --range <base>..HEAD --path <p> --intent "<one line>" [--focus "<angle>"] --embed-diff
```

If `$ARGUMENTS` contains `--background`, compose the same review prompt yourself and submit it
instead, then continue working and collect later:

```powershell
"<composed review prompt with embedded diff context>" | ccodex submit --mode review
ccodex wait <job_id>    # when ready for the result
```

Triage every finding: verify it against the actual code, adopt (and act) or reject with a stated
reason; report adopted vs rejected separately. Never present Codex's raw output as your own
conclusion. On failure, react by exit code + `status.json.failure_reason` per the `ccodex` skill —
a failed review never blocks the task.
