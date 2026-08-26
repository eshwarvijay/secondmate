---
description: Check and auto-fix secondmate's requirements (checker/reason harness, git/gh/python, and companions herdr/ponytail/loop-task/adhd). Installs what's missing — the human only approves each action.
---

Set up secondmate end to end. YOU (the agent) run every fix so the human only approves it via the normal
permission prompt — never make the human hunt for install steps.

1. Detect: `bash "${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh" --json`
2. For each item with `"status":"MISSING"` and a non-empty `"fix"`, RUN that fix command yourself (the human
   approves via the permission prompt). Order: CORE (git/gh/python3) → CHECKER harness → COMPANIONS
   (herdr, ponytail, adhd; `/loop-task` is bundled with this plugin).
3. For a MISSING item with an empty `"fix"` (a companion whose source isn't wired in), tell the human the one
   concrete thing to provide (the marketplace or URL for that skill) and set the matching `FM_*` env var — do
   not block the rest on it.
4. After healing, if the checker harness is present, confirm a reachable model with a dry check:
   `"${CLAUDE_PLUGIN_ROOT}/bin/reason.sh" --dry-run "ping"` — and remind the human that cross-model checking
   needs a 2nd model family + credentials (`FM_CHECKER_*` / `FM_REASON_*`), which only they can supply.
5. Re-run `bash "${CLAUDE_PLUGIN_ROOT}/bin/doctor.sh"` and report: what was already OK, what you fixed, what
   still needs the human.

Rule: propose and run the commands; the human's only job is to approve. Do not hand them a manual checklist.
