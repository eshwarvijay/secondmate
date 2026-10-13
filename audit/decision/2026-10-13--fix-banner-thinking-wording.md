## 2026-10-13 — fix-banner-thinking-wording: literal-match selfcheck fix (grep -qF) caught by checker round 1, 2 rounds total

**What the maker decided**: Keep the banner's existing terse-shorthand convention rather than spelling out
literal `--provider`/`--model`/`--thinking` flags — "pi+GLM-5.3 --thinking max (simple)" mirrors the
original "pi+Qwen --thinking medium (simple)" shape and README.md's own established shorthand for the same
routing. Added selfcheck drift-guards (1 assert-present, 2 assert-absent) following the script's existing
grep-based idiom exactly (same shape as the pre-existing "hard-capped at 2" stale-wording pair) rather than
inventing a new assertion style or coupling the selfcheck to re-reading SKILL.md's content directly.

**What the checker found**: Round 1's assert-present check (`grep -q "pi+GLM-5.3 --thinking max (simple)"`)
had a real correctness bug — the undotted `.` in "5.3" is a regex metacharacter under plain `grep`, so it
would also match a corrupted banner like "pi+GLM-5X3 --thinking max (simple)". The checker reproduced this
concretely: mutated only the banner text in a temp copy, ran the real selfcheck, showed it wrongly printed
`ok`/exit 0. This is exactly the kind of silent-drift gap the whole task existed to close, so the finding
was high-value despite the task's small size — tagged `real-bug` in log-round.sh.

**Resolution**: Supervisor read the finding, synthesized a one-line fix plan (`grep -q` → `grep -qF` on that
one assertion only), and routed it to the same task-scoped maker — never fixed inline. Maker's round-2 fix
was a single-character-class change (1 insertion, 1 deletion), re-validated via the same mutation-test
method the checker used, plus a full regression re-run of round 1's own stale-wording mutations. Checker's
round-2 re-review confirmed the fix with its own independent mutation test and explicit confirmation that
no new issue was introduced and scope stayed to the one file across both rounds.

**Gate/hold**: verify-gate PASS auto-evaluated (clean worktree, non-empty diff, checked-sha match, test
green) — no escalation needed. Human hold `d149f7bb` opened per SOP (every merge decision is a genuine
human gate, never self-answered); approved by Eshwar (human) via Hermes dispatcher after ~5 minutes.

**Scope decisions declined**: no version-drift-tolerant pattern matching (would have been speculative
hardening for a problem not asked for); no changes to SKILL.md/README.md/docs/ARCHITECTURE.md (verified
already correct, confirmed via grep both before planning and via the checker's own diff-scope check); no
plugin.json version bump (text-only drift fix, not a feature or behavior change).
