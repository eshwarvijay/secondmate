---
description: Run a task through a maker/checker loop until done (triage → implement → verify → gate)
argument-hint: <goal to accomplish>
---

# Loop: $ARGUMENTS

Complete the goal above by running the loop below until an exit condition holds.
This is the "loop-engineering" pattern (design the loop, not the prompt): a
maker/checker split with a human gate before anything risky. Do NOT one-shot the
goal — run the stages.

## The loop

Repeat until **done** or **escalate**:

1. **Triage.** State the goal in one line. Break it into the smallest next
   increment that can be independently verified. If the goal is already met, say
   so and stop. If it's ambiguous or you'd be guessing at intent, **escalate**
   (ask the user) instead of proceeding.

2. **State.** Read any existing state relevant to the goal (repo's
   `.claude/task_state.md` if present, prior loop notes, the files involved).
   After each iteration, jot what changed + what's next so a resumed loop has a
   spine. Keep it to a few lines — not a document.

3. **Implement.** Spawn ONE sub-agent (the *maker*) to make the increment:
   `Agent(subagent_type: "general-purpose")`. If the change touches files that a
   parallel iteration could also touch, pass `isolation: "worktree"`. The maker
   returns a diff/summary, not a merged result you assumed.

4. **Verify.** Spawn a SEPARATE sub-agent (the *checker*) to verify — never the
   same context that made the change. The checker runs the tests/build/lints the
   repo actually has and reads the diff adversarially: does it meet the goal, did
   it break anything, is the verification itself real (tests exist and ran)? It
   returns pass/fail with evidence. On **fail**, feed the reason back to step 1
   and iterate. Verification is the human's responsibility by proxy — a green
   checker that didn't actually run anything is a failure, not a pass.

5. **Gate.** Before any outward-facing or hard-to-reverse action (commit, push,
   PR, deploy, delete, send, external API write):
   - **Safe / explicitly pre-authorized** → do it, log what you did.
   - **Risky / ambiguous / not authorized** → **escalate**: stop and present the
     user the diff, the verifier's evidence, and the specific action you want to
     take. Wait for approval. Do not self-approve.

6. **Loop or exit.** If the goal is fully met and verified → **done**: report
   what shipped + how it was verified. Otherwise return to step 1 with the next
   increment.

## Rules

- **Maker ≠ checker.** They must be different sub-agent invocations. The whole
  point is independent verification.
- **Phased autonomy.** Default to L1 (report + propose, gate every write). Only
  act unattended (L2/L3) on actions the user has explicitly allowlisted for this
  goal. When unsure which level applies, you're at L1.
- **Watch the cost.** Loops amplify judgment and burn tokens. Cap iterations at a
  sane number (say 5) and escalate rather than spinning; if you're not
  converging, the goal or the verification is wrong — surface that.
- **No comprehension debt.** Read what the maker shipped before you gate it.
  Don't commit a diff you haven't looked at.
- **Bound the loop.** Every iteration must end closer to a stated exit condition.
  If you can't name the exit condition, go back to triage.

## When NOT to use this loop

If the goal is a single trivial edit, or read-only (a report, a query, a
one-shot answer), skip the maker/checker apparatus — just do it. This loop earns
its overhead only when work is iterative AND has a verifiable result AND may take
a risky action. For "run X on a cadence," use `/loop <interval> <task>` instead —
that's scheduling, not this.
