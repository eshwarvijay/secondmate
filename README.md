<p align="center">
  <img src="assets/secondmate.jpg" alt="secondmate" width="360" />
</p>

# secondmate

A Claude Code plugin that hardens the **maker/checker loop** for shipping verified code changes: a maker
implements in an isolated worktree, a **different-model, edit-locked checker** reviews the diff and emits a
machine-branchable `{verdict}` envelope, a **verify-gate** re-checks ground truth against the exact reviewed
commit, and every human-gate decision becomes a **durable hold** that survives a restart. Plus loop-safety
guards (stuck-loop abort, timeout + idle watchdog, round/spawn caps) and read-only **reasoning one-shots**.

Harness-neutral: works with any coding-agent CLI that accepts the standard `--provider` / `--model` /
`--exclude-tools` / `--append-system-prompt` flags.

## Quick start

```sh
claude plugin marketplace add eshwarvijay/secondmate
claude plugin install secondmate@secondmate
# restart Claude Code, then let it set itself up — you just approve each step:
/secondmate-doctor
```

Then run any change through the loop with **`/loop-task <goal>`**: secondmate spawns the maker in an
isolated worktree, runs a **different model** as an edit-locked checker, gates on its `{verdict}` plus a
clean `verify-gate`, and asks you before anything merges. Ask a reasoning model anything read-only with
`/secondmate-reason <question>`.

## What it gives you

| Component | What it does |
|---|---|
| `secondmate` skill | The maker/checker SOP the supervisor follows (triage → spawn → check → gate → hold → integrate) |
| SessionStart hook | Surfaces durable open decisions each session so a restart never drops a pending gate |
| `bin/hold.py` | Durable human-gate decisions (`hold` / `answer` / `open`) |
| `bin/verify-gate.sh` | Pre-integration gate: clean tree, non-empty diff, **exact-SHA** match, tests |
| `bin/launch-checker.sh` | Edit-locked (`--exclude-tools edit,write`) cross-model checker + injected verdict-envelope contract |
| `bin/verdict.py` | Parse the checker's `{verdict}` envelope → exit `0` pass / `1` fail / `2` error·refused |
| `bin/loop-guard.sh` | Stuck-loop abort + per-run round cap + global spawn cap |
| `bin/run-round.sh` | Wall-clock timeout + idle watchdog + paired audit record (even on kill) |
| `bin/prune-output.sh` | Model-free head/tail truncation of bulky logs |
| `bin/new-worktree.sh` | Isolated git worktree per maker (never the primary checkout) |
| `bin/reason.sh` | Read-only, tool-free reasoning one-shot on a reasoning model |
| commands | `/secondmate-doctor`, `/secondmate-reason`, `/secondmate-verify`, `/loop-task` |

## Install

```sh
# from a local clone
claude plugin marketplace add /path/to/secondmate
claude plugin install secondmate@secondmate

# or from GitHub once published
claude plugin marketplace add eshwarvijay/secondmate
claude plugin install secondmate@secondmate
```

Restart Claude Code (or `/plugin`) to load it, then run **`/secondmate-doctor`** — it detects and installs
everything below (harness, git/gh/python, and the companions), asking you only to approve each action.
You never have to run manual setup.

## Requirements

- **git** and **gh** (worktrees + PR flow).
- A **checker harness CLI** that accepts `--provider/--model/--thinking/--exclude-tools/--append-system-prompt`
  and a headless `-p` mode. Defaults target [`pi`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent);
  any harness with the same flags works via the env vars below.
- **python3** (for `hold.py` / `verdict.py`).

### Companions (recommended — `/secondmate-doctor` installs these too)

| Companion | What it adds | Install |
|---|---|---|
| **pi** | default checker + reasoning harness (multi-model) | `npm install -g @earendil-works/pi-coding-agent` |
| **herdr** | visible multi-pane maker/checker orchestration | `brew install herdr` |
| **ponytail** | complexity / over-engineering lens | `claude plugin install ponytail@ponytail` |
| **loop-task** | maker/checker loop driver command | **bundled — ships with this plugin** |
| **adhd** | divergent ideation for open-ended triage | `claude plugin marketplace add UditAkhourii/adhd && claude plugin install adhd@adhd` |

`/secondmate-doctor` self-heals: it runs each install for you and you just approve — it never hands you a manual checklist.
Cross-model checking additionally needs a **second model family + credentials** for your harness (only you can supply those).

## Config (env vars — all optional, sane defaults)

| Var | Default | Purpose |
|---|---|---|
| `SM_CHECKER_HARNESS` | `pi` | checker CLI |
| `SM_CHECKER_PROVIDER` | `amazon-bedrock` | checker provider |
| `SM_CHECKER_MODEL` | `global.openai.gpt-5.6-terra` | checker model (a **different family** than the maker) |
| `SM_CHECKER_THINKING` | `high` | checker reasoning effort |
| `SM_CHECKER_PROMPT` | `bin/checker-prompt.md` | base checker discipline (point at your own tuned file to override) |
| `SM_REASON_HARNESS` | `pi` | reasoning CLI |
| `SM_REASON_PROVIDER` | `amazon-bedrock` | reasoning provider |
| `SM_REASON_MODEL` | `r1` | default reasoning model alias (`r1`/`gpt`/`sonnet`/full id) |
| `SM_HOLD_LEDGER` | `./decisions.jsonl` | per-repo decision ledger path |
| `SM_LOOP_STATE` | `./.secondmate` | loop-guard state dir |
| `SM_WT_ROOT` | `~/.fm-worktrees` | where maker worktrees are created |

The default checker/reasoning model IDs are Amazon Bedrock inference-profile IDs — override them for your provider.

## Verify

```sh
bin/verdict.py selfcheck && bin/loop-guard.sh selfcheck && bin/verify-gate.sh --selfcheck \
  && bin/prune-output.sh --selfcheck && bin/run-round.sh selfcheck && bin/reason.sh --selfcheck \
  && bin/doctor.sh --selfcheck && echo ALL_OK
claude plugin validate .
```

## License

MIT
