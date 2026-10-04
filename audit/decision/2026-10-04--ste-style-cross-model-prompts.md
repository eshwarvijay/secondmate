## 2026-10-04 — STE rewrite preserves all rules/guardrails verbatim; checker side-by-side diff confirms, human-approved merge

## Decision

**What the maker decided:** rewrote the "Maker prompt closing boilerplate" fenced block in
`skills/secondmate/SKILL.md` and the full prose of `bin/checker-prompt.md` + `bin/checker-envelope.md`
for STE (Simplified Technical English) sentence discipline — one instruction per sentence, active voice,
no deep noun-stacking, consistent terminology — while leaving the embedded `$(...)` shell-substitution
mechanics, all 8 call sites elsewhere in SKILL.md, the CALIBRATION ❌/✅ example lines, and every
machine-read token byte-identical. It built and kept a 59-item atomic before/after rule inventory (under
the gitignored `.secondmate/tmp/`, not committed) as its own self-check artifact and offered it to the
checker.

**Probes resolved by the supervisor during Plan Committee synthesis (all answered from repo evidence, no
business/product escalation needed):**
- Call-site count: the task said "8 call sites"; an initial grep-only Explore pass found only 7 (missing
  an indirect reference). The committee (kimi-k3) found the real 8th: a non-literal pointer near line 275
  reading "...same fix plan and checklist" — resolved by instructing the maker to grep for "checklist" too,
  not just the literal pointer phrase.
- CALIBRATION ❌ example rewrite: resolved as "leave verbatim" — the deliberately bad, hedged phrasing is
  the pedagogical point of the contrast with the ✅ example; clarifying it would remove the lesson.
- plugin.json version bump: resolved as "no bump" — precedent from a prior editorial-only SKILL.md change
  (the dedupe-maker-prompt task) did not bump version; version bumps are reserved for cache-drift or
  functional changes (per the `6abe270` commit's own stated rationale).
- Whether to also style-pass `docs/ARCHITECTURE.md`'s restatement of the boilerplate: resolved as
  "out of scope, no action" — confirmed by direct read that ARCHITECTURE.md paraphrases rather than quotes
  the boilerplate prose verbatim (aside from the shell snippet and JSON schema, both unchanged), so no
  drift was introduced.
- Whether the maker may *reduce* existing backtick/quote usage in the boilerplate (e.g., de-formatting
  inline code terms) while rewriting: resolved as "no" — the invariant is zero *net-new* characters, not
  "fewer is better"; reducing existing formatting is itself a change outside a sentence-discipline pass's
  scope.

**What the checker found:** nothing. One checker round, `verdict: pass`, 0 findings, after being
explicitly instructed (via the HAMMER section of the checker addendum, bound directly from the Plan
Committee's own risk findings) to do a side-by-side semantic diff against `HEAD~1` and specifically hunt
for a flipped negation/modal, rather than a holistic "does this read well" pass. The checker's own report
confirmed, item by item: the boilerplate's five rule paragraphs' modals and conditions compared equal; the
feature-list.json schema and `verified_by` null-rule preserved; both conduct rules (test-tampering,
git-hygiene) preserved including their synonym/exception clauses; the CALIBRATION example pairs are
byte-identical; every machine-read token across all three files is present verbatim post-edit.

**Gates auto-approved vs. escalated:**
- Auto-approved by the supervisor (no human needed): all Plan Committee probes (see above, all resolvable
  from repo evidence); the maker-routing choice (Claude, per the task's own explicit instruction); the
  checker's lens selection (none — no `bin/lenses/` role fit a pure prose-rewrite task, consistent with the
  explicit out-of-scope note on lens files); the "no doc-sync, no version bump" call.
- Escalated to the human (correctly, per SOP — a merge decision is never self-approved): the final
  hold (`df0e5945`) asking whether to merge `sm/ste-style-cross-model-prompts` into `main`. Answered
  `approve`. The sub-supervisor received this answer relayed by the dispatching top-level supervisor but
  did not treat the relay itself as consent — it independently re-read the raw `decisions.jsonl` ledger
  and confirmed both the original `hold` event (matching its own checked-sha) and a genuine subsequent
  `answer` event were actually present before proceeding to merge.

**Lesson feedback:** two previously-logged lessons were directly exercised and found genuinely helpful on
this task, tagged accordingly: `stay-in-literal-scope` (the maker's diff touched exactly the three
intended files and nothing else — no unrelated "clean-up" drift, which is exactly the failure mode that
lesson warns against) and `maker-must-commit-before-done` (the maker's commit `927c5cc` landed before it
replied DONE, and the supervisor's own independent `git log`/`git status` check in the worktree confirmed
a clean tree with the commit present, rather than trusting the DONE claim at face value).
