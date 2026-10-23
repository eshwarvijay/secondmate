---
name: drift-report
description: >
  Check secondmate's own docs (README.md, docs/ARCHITECTURE.md,
  skills/secondmate/SKILL.md) against its own bin/ scripts for drift — a
  documented flag/subcommand/default/selfcheck form that no longer matches
  the real script, or a documented script that was renamed/removed. Use
  before `git push` per this repo's own CLAUDE.md doc-sync rule, or whenever
  asked to "check doc drift" / "run drift-report". Read-only, reports only;
  never edits anything.
---

# drift-report

Finds drift between secondmate's own documentation and its own `bin/` scripts, so you don't
have to catch it purely from memory before `git push` (the gap CLAUDE.md's doc-sync rule leaves
open today).

## Scope — exactly these four surfaces

1. **README.md's "What's inside" component table** — for each `bin/*.sh`/`bin/*.py` row: the file
   exists, and any flag name/default/subcommand the row describes is real.
2. **README.md's env var table** — each `SM_*` var is actually read somewhere under `bin/` (a var
   documented as read only by a skill/prompt file, not a `bin/` script, is not drift — check where
   the table itself says it's read).
3. **README.md's manual-install selfcheck block** (`bin/verdict.py selfcheck && bin/loop-guard.sh
   selfcheck && ...`) — each listed invocation is the script's real current form. Subcommand vs
   `--flag` is exactly the kind of mismatch to catch (e.g. `verdict.py selfcheck` vs `verdict.py
   --selfcheck` — check the script's own arg handling, don't guess from the name).
4. **docs/ARCHITECTURE.md's component map / stage descriptions** and **skills/secondmate/SKILL.md's**
   own described behavior — same kind of check against the real scripts.

A `bin/` script with zero mention in any of these docs is out of scope — don't flag it as a required
finding. If you notice one in passing, you may add it as a clearly labeled "secondary/informational"
note at the end, never mixed into the required findings.

## How to check — read, run, compare (no new tooling)

For each surface above:
- Read the doc section verbatim.
- For a claimed flag/subcommand/default: `grep -n` the real script's arg-parsing (its `case`/
  `argparse`/`if [ "$1" = ...]` block), or run the script with `--help`/`-h`, or run the exact
  invocation the doc names and read its own usage/selfcheck output.
- For an env var: `grep -rl SM_VARNAME bin/` and read the hit, or confirm the doc itself says it's
  read elsewhere (e.g. a skill file) instead of `bin/`.
- Compare the doc's claim to what you just read/ran. Nothing fancier than that — no AST parsing, no
  new bin/ helper. If a prompt-driven read+compare genuinely can't settle a claim, say so in the
  report rather than inventing a helper for it.

## Reporting rule — every claimed divergence needs both sides, verbatim

Report a divergence only if you can cite:
- the exact doc sentence/row making the claim, **and**
- the exact script evidence that contradicts it (a grep line with line number, a `--help`/usage
  line, or the selfcheck branch) you actually read or ran.

No evidence on both sides → don't report it as a finding, even if something feels off.

## Output format (markdown, divergences only)

```
# Drift report — <git rev-parse HEAD short SHA>, <date>

Checked: README.md ("What's inside" table, env var table, selfcheck block), docs/ARCHITECTURE.md
(component map + stage descriptions), skills/secondmate/SKILL.md, against bin/ at <SHA>.

## Divergences

### 1. <one-line summary>
- Doc says (<file>:<line>): "<verbatim quote>"
- Script actually does (<file>:<line>): "<verbatim grep/help/selfcheck output>"

(repeat per divergence; omit the whole "## Divergences" section if none found)

## Secondary / informational (not graded, not required)
- <bin/ script mentioned nowhere in the four surfaces, noticed in passing — optional, may be omitted>
```

If nothing is wrong, skip straight to the sentinel — still with full provenance:

```
# Drift report — <SHA>, <date>

Checked: README.md ("What's inside" table, env var table, selfcheck block), docs/ARCHITECTURE.md
(component map + stage descriptions), skills/secondmate/SKILL.md, against bin/ at <SHA>.

NO DRIFT FOUND.
```

## Out of scope — don't do these

- Don't build a parser/AST tool or a new `bin/` script for this. Read+grep+run directly.
- Don't wire this into the maker/checker SOP, merge-sequencer, or any enforced gate. Standalone,
  on-demand only.
- Don't take user-supplied paths. This skill always checks this repo's own README.md,
  docs/ARCHITECTURE.md, skills/secondmate/SKILL.md, and bin/ — nothing else.
- Any shell command you run as part of this check must be the exact, literal, repo-local command
  (e.g. the script's own documented selfcheck invocation) — never built by concatenating anything
  from outside this repo.
- Don't propose or apply fixes. Report only; a human decides what to do with a finding.
