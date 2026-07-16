---
description: Delegate a code edit to Codex in an isolated git worktree (ccodex run --mode implement), then review the diff before applying; add --background to submit it.
argument-hint: [--background] <implementation task>
---

Delegate an actual code edit to Codex with worktree isolation — the main working tree is never
touched by the job itself. Only use this when the user (or the delegation policy) explicitly
wants Codex to make the edit, not just advise on one.

1. Write a self-contained implementation brief from `$ARGUMENTS` + conversation context:
   what to build/change, acceptance criteria, constraints, and how to verify (tests to run).
2. Run it (blocking), or with `--background` in `$ARGUMENTS` submit it and keep working:

```powershell
"<brief>" | ccodex run --mode implement --repo <repo>
"<brief>" | ccodex submit --mode implement --repo <repo>   # background variant; ccodex wait <job_id> later
```

3. **Always inspect before landing — never auto-apply:**

```powershell
ccodex diff <job_id>     # read every change like a PR you're about to merge
ccodex apply <job_id>    # only after you've reviewed and decided to land it
```

`apply` needs a clean main-repo tree by default and a `done` job. When the only dirt is unrelated
untracked files, `apply --allow-untracked <job_id>` opts in safely; tracked dirt or a patch-path
overlap still exits `2`. Exit `25` means conflict — the main repo and its pre-existing untracked
files are untouched, so report it and resolve by hand rather than retrying. After applying, run the
project's tests yourself; Codex's own test claims don't count as verification.

If review finds something to revise, continue the same thread before applying:

```powershell
"<review feedback>" | ccodex resume <job_id>
ccodex diff <child_job_id>     # cumulative parent + child changes
ccodex apply <child_job_id>    # only the newest accepted descendant
```

The child uses a new snapshot-seeded worktree. Never apply the parent and then the cumulative child.
