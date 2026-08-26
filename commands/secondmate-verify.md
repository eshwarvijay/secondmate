---
description: Run the secondmate pre-integration gate on a maker's worktree — clean tree, non-empty diff, exact-SHA match, tests — before merging.
---

Run the secondmate verify-gate and report PASS or the exact REFUSE reasons. Do NOT integrate/merge unless it PASSes.

Arguments (worktree path, base branch, and the SHA the checker reviewed): $ARGUMENTS

Execute (fill the values from the arguments; add `--test "<cmd>"` if a test command applies):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/verify-gate.sh" --worktree <worktree> --base <branch> --checked-sha <sha>
```

Passing `--checked-sha` (the exact commit the checker reviewed) is mandatory — it catches a maker
pushing new commits after the checker approved.
