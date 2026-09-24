## 2026-09-01 — plan-committee: checker-lens-quality planner prompts

- **Decisions:** (1) Replaced single generic SCHEMA with 6 per-planner functions; (2) each prompt uses outcome block (directional-prompting) + named probe categories + classification scales + Probes-for-Supervisor (STORM); (3) selfcheck uses dimension-specific markers per planner; (4) deepseek-r1 table schema marker must be table-header substring not bare word; (5) SKILL.md step 0c now requires answering all probes or escalating unanswerable ones to human
- **Bugs caught by checker:** generic selfcheck markers passed on swapped bodies → dimension-specific markers; bare-word Justification matched prose → table-header substring; SKILL.md had no escalation path for non-repo probes
- **Escalations:** none
