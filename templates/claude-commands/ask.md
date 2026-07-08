---
description: Ask Codex for a second opinion / brainstorm (plans, designs, debugging hypotheses — also when stuck and needing a fresh brain); add --background to run as a background job.
argument-hint: [--background] <question or topic>
---

Get a cross-model second opinion from Codex with `ccodex run --mode brainstorm`. Use it for plan
and design reviews, competing-approach trade-offs, or when you are stuck on a bug and want an
independent diagnosis pass.

1. Write a short, self-contained brief — Codex sees none of this conversation. Include the
   question from `$ARGUMENTS`, the relevant constraints, and (for debugging) the observed
   symptom, what you ruled out, and the suspect code paths. Codex can open repo files itself, so
   name paths instead of pasting file contents.
2. Run it from (or `--repo`-pointed at) the relevant repository:

```powershell
"<brief>" | ccodex run --mode brainstorm --repo <repo>
```

If `$ARGUMENTS` contains `--background`, use `ccodex submit --mode brainstorm` instead and
collect with `ccodex wait <job_id>` when ready.

If Codex answers with a clarifying question, continue the same session:
`"<answer>" | ccodex resume <job_id>` (see `/ccodex:resume`).

Weigh the reply as input from a capable peer, not ground truth: verify claims against the code
before acting on them, and say in your report which suggestions you adopted vs rejected and why.
