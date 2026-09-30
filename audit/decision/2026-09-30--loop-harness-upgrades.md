## 2026-09-30 — Reuse round-state.md's write idiom for feature-list.json, decline new bin/script; independently re-verify hold answer before merging

## Decision — loop-harness-upgrades

**What the maker decided:**
- No new `bin/` script for `feature-list.json` — reused round-state.md's existing atomic temp-file+mv
  write idiom, per unanimous convergence across adhd + all 5 completed planner outputs.
- `loop-guard.sh` left byte-for-byte unmodified — verified it only manages flat counters
  (`action.key`/`action.count`/`rounds`/`spawns`) and never parses either handoff file; the "feed into the
  restart path" requirement is satisfied entirely by extending the existing `$([ -f <path> ] && cat <path>)`
  command-substitution block that already runs on every maker invocation, including restarts.
- `feature-list.json` schema: flat current-state array of `{id, description, status: pending|pass|fail,
  verified_by, round}`, with `verified_by` required non-null whenever status is pass/fail (this doubles as
  the premature-victory evidence gate) and null only valid for pending.
- No `.claude-plugin/plugin.json` version bump — treated as a prompt/doc content change with no new
  script/flag/command, matching the 2026-09-30 boilerplate-dedupe precedent that also skipped a bump for a
  non-mechanical change. `merge-sequencer.sh`'s pre-merge reminder about this was already satisfied (docs
  were synced; version bump was a deliberate, reasoned skip, not an oversight).

**What the checker found:**
- Round 1 `fail`, 2 confirmed findings: an ambiguous ARCHITECTURE.md sentence contradicting the
  optionality contract it was meant to document, and a DONE-evidence citation (`claude plugin validate .`)
  that never actually exercised the changed behavior — the checker caught the maker committing exactly the
  premature-victory failure mode this task exists to guard against, in its own verification of that guard.
- Round 2 `pass`, 0 findings — both fixes independently reproduced by the checker (it re-ran the same
  conditional-cat probes itself rather than trusting the maker's report).

**Gates auto-approved vs. escalated:**
- Plan Committee probes: all resolved by the supervisor from repo evidence / task constraints (new-script
  question, JSON schema, loop-guard integration mechanism, startup-checklist reconciliation behavior,
  version-bump policy, prompt-size cap, tier-conditional verification cost) — none required human escalation
  as none were genuine business/product/legal decisions outside the repo's own evidence.
- The merge itself was NOT auto-approved — a durable hold (`caca1d1d`) was opened and the supervisor waited
  for a genuine human answer. When a coordinator later reported the human had answered, the supervisor did
  not take that report at face value: it independently read the raw `decisions.jsonl` ledger, confirmed the
  hold's recorded sha (`0b680cf7dac36839d91d7f810e9fc349be409356`) matched the checked sha exactly, and
  confirmed a real `answer` event (`a: "yes"`) existed, before merging. This is the correct pattern per the
  SOP's "never self-answer, never assume approval, verify independently" instruction — a duplicate agent
  spawned alongside this task under the same name was told to stand down and took no conflicting action.

**Tags logged:** round 1 — `doc-inaccuracy`, `unverified-claim` (lesson `mutation-test-your-tests` cited);
round 2 — `pass`, no tags needed.
