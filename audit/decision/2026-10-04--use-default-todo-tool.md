## 2026-10-04 — Generic tool-detection wording, decline partial-availability branching and version bump

## 2026-10-04 — use-default-todo-tool: generic tool-detection wording, decline partial-availability branching and version bump

**What the maker decided:** Reworded the paragraph to name both known tool shapes (`TodoWrite`; the
`TaskCreate`/`TaskGet`/`TaskUpdate`/`TaskList` set) as mutually exclusive options with no priority
ordering between them — resolved from a sourced fact (Anthropic's documented
`CLAUDE_CODE_ENABLE_TASKS` switch) rather than inventing a tie-break rule. Added an explicit
"use the real tool over any ad-hoc scheme" sentence, and demoted the plain-checklist fallback to
"only when no built-in task-tracking tool is available at all." Preserved verbatim: the
self-reported status philosophy, the scope-boundary sentence, and the `progress-ledger.py`
distinction clause (checker confirmed this clause byte-identical to the pre-change version).

**What the checker found:** Nothing — pass, 0 findings. It explicitly probed sessions with only
`TodoWrite`, only the four-tool set, and neither, and confirmed the reworded paragraph reads
correctly in all three. Its one named residual: a session exposing a *malformed partial* Task* set
(e.g. `TaskCreate` present but `TaskGet` missing) isn't described — but the task's own stated contract
treats the four tools as one atomic shape, so this was accepted as in-scope-correct, not a gap.

**Gates:** Plan Committee synthesis resolved 6 planners' probes without escalation — notably declined
glm5/kimi-k3's suggestion to add priority-order wording for simultaneous tool availability (resolved
as moot: the two shapes are documented as mutually exclusive, not coexisting) and declined
mistral-large3's security-sanitization probes (not applicable — prose/Markdown edit, no execution
surface). Decided to sync `docs/ARCHITECTURE.md`'s short restatement in the same commit (mandated by
CLAUDE.md's doc-sync-before-push rule for changed SKILL.md patterns — not a new escalation, enforcing
existing policy) but declined a `plugin.json` version bump (no cache-drift problem being fixed, unlike
the 6abe270 precedent) and declined touching `README.md` (verified no reference existed). Human hold
answered "yes" and independently re-verified against the raw ledger before merge, per SOP ("never take
the coordinator's word for it").

**Process note:** the hold was opened without `--sha` binding — a self-identified gap for next time;
hold.py's documented backward-compat path (no sha required on answer when none was set at hold time)
is why this didn't block the merge, but future holds on this task-id's class of work should pass
`--sha` at creation for the stronger anti-reattach guarantee.
