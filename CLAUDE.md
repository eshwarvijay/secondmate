# secondmate — project instructions

## Audit trail (auto-loaded each session)

@audit/flow.md
@audit/decision.md

## Docs must stay in sync with code

Before every `git push`, update `README.md` and `docs/ARCHITECTURE.md` to reflect any changes to:
- `bin/` scripts (new scripts, changed flags, changed defaults)
- `skills/secondmate/SKILL.md` (new phases, changed patterns, updated commands)
- `.claude-plugin/plugin.json` (version bumps)
- Herdr integration patterns (pane/agent/worktree usage)

Specifically keep current:
- Version badge in README
- "What's inside" component table (add/remove/update rows for bin/ changes)
- "How it works" mermaid diagram (if the flow changes)
- Config vars table (`SM_*` env vars)
- Manual install selfcheck command (add new `--selfcheck` calls)
- ARCHITECTURE roles table, flowchart, stage-by-stage descriptions, component map

**Never push without checking these.** If a bin script changed, the README table must reflect it. If the skill changed, the ARCHITECTURE stages must reflect it.
