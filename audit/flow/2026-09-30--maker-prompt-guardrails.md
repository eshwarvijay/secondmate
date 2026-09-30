## 2026-09-30 — maker-prompt-guardrails: test-tampering + git-hygiene guardrails added to Maker prompt closing boilerplate

Solo dispatch. Ran the full secondmate SOP for a `ship`/`full`-rigor prompt-text change:
add two guardrail rules (test-tampering ban; git-hygiene tightening) to SKILL.md's canonical
"Maker prompt closing boilerplate" block, injected into every future maker invocation.

**Plan Committee:** ran adhd (4 diverge frames — regulator, competitor-trying-to-break-it,
3am-on-call, inversion; converged directly given small scope) plus the 6-model
plan-committee.sh (deepseek-r1, glm5, kimi-k3, mistral-large3, qwen3-80b, qwen3-coder;
first run collided with a stale unmarked planning dir from an earlier task, re-ran with a
task-scoped `--out-dir`). All probes raised by the six planners (placement, test-change
ambiguity threshold, stuck-loop threshold, policy framing, release-version convention,
prompt-injection-resistance suggestions) were resolvable from the task's own text or repo
precedent (`audit/decision/2026-09-30--loop-harness-upgrades.md`'s version-bump-skip
precedent) — no genuine open business decision required escalation before the maker started.
adhd's ideation independently found and closed three loopholes a naive first draft would
have left open (mock/stub/fixture side door on the test rule; `git add -u`/`commit -a` as
unbanned synonyms; `--force-with-lease` as an unbanned force-push variant), plus replaced
the original ask's vague "repeated attempts" with a mechanical "fails twice in a row"
trigger — three independent ideation frames converged on this unprompted.

**Maker:** routed to Claude (step 0d "complex" — blending new prose coherently into an
already-dense block without duplication/contradiction). One round. The maker deviated from
my own consolidated plan's literal drop-in wording on its own initiative: my draft (and the
plan file's) used backtick code-spans and `git add .`-style literal double-quoted strings,
which would have broken the block's double-quoted shell interpolation at all 8 call sites —
the exact failure mode I hit myself while constructing the maker's own launch prompt minutes
earlier (bash's lexer quote-balances even inside a quoted heredoc body). The maker caught
this independently, reworded the two rules as shell-safe continuous prose while preserving
every loophole-closing clause, and verified via grep that zero `"`/backtick/`$(` were
introduced. It also synced `docs/ARCHITECTURE.md`'s existing enumeration of the boilerplate's
guarantees in the same commit (`dc6e40a`), per this repo's own CLAUDE.md doc-sync rule —
confirmed via `git diff --check`/`--stat` that only those two files changed, no README or
plugin.json churn.

**Checker:** cross-model (gpt-5.6-terra via launch-checker.sh), run visibly in a herdr pane
per the strict HERDR_ENV=1 rule. No pre-built lens fit (this is prose, not code with tests),
so relied on a detailed task-specific `--addendum` file (avoided `--addendum-text` after
hitting the same quoting trap a second time — switched to the file-based flag). Verdict:
pass, zero findings, one round. Confirmed no duplication/contradiction with the round-state.md
format paragraph or the lesson-lookup.py line, maker-facing/path-generic wording, shell-safety,
and all 8 call-site pointers (including the one indirect "same fix plan and checklist"
pointer) still accurate.

**Gate:** PASS at `dc6e40a74544e40f3252cf53f3ded0cdf55f6d33`, re-verified with no drift
immediately before merge.

**Hold:** opened `6dfd1cdf` (no `--sha` binding used — checked_sha embedded in the `--q`
text instead); genuinely answered by a human via the coordinator as `merge`. Independently
re-verified the answer against the raw `decisions.jsonl` ledger (not just the coordinator's
say-so) before proceeding — confirmed the hold no longer open, the answer record present with
`"a":"merge"`, and the hold's own question text naming the exact checked sha.

**Integrate:** `merge-sequencer.sh` merged `sm/maker-prompt-guardrails` -> `main` as
`7aa3546bc78e3af14eb3c5c7abda75cc31c74644`, pushed to origin.

**Teardown:** checker pane closed, worktree removed, local branch deleted, claim released,
`teardown-check.sh` reports clean. `caffeinate-guard.sh stop` run once (solo dispatch, sole
task in this session).

Round count: 1 maker round, 1 checker round, 0 fix rounds.
