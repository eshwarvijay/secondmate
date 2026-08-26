<p align="center">
  <img src="assets/secondmate.jpg" alt="secondmate" width="240" />
</p>

<h1 align="center">secondmate</h1>

<p align="center">
  <em>Your agent writes the code. A different model tries to break it.<br/>Only what survives ships, and only when you say go.</em> 🐾
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-plugin-6E56CF?style=flat-square" alt="Claude Code plugin" />
  <img src="https://img.shields.io/badge/version-0.1.0-4C8BF5?style=flat-square" alt="version 0.1.0" />
  <img src="https://img.shields.io/badge/bash_+_python-informational?style=flat-square" alt="bash + python" />
  <img src="https://img.shields.io/badge/license-MIT-3FB950?style=flat-square" alt="MIT" />
</p>

---

**secondmate** hardens the maker/checker loop for shipping code with an agent. A maker implements in an
isolated worktree, a **different-model, edit-locked checker** reviews the diff and returns a machine-readable
`{verdict}`, a **verify-gate** re-checks ground truth against the exact reviewed commit, and every risky
decision becomes a **durable hold** that survives a restart. Plus stuck-loop + timeout guards and read-only
reasoning one-shots. Harness-neutral, works with any coding-agent CLI that speaks `--provider` / `--model` /
`--exclude-tools` / `--append-system-prompt`.

## ⚡ Quick start

```sh
claude plugin marketplace add eshwarvijay/secondmate
claude plugin install secondmate@secondmate
# restart Claude Code, then let it set itself up — you just approve each step:
/secondmate-doctor
```

Then run any change through the loop:

```sh
/loop-task add a rate limiter to the API and prove it works
```

secondmate spawns the maker in an isolated worktree, runs a **different model** as an edit-locked checker,
gates on its `{verdict}` plus a clean `verify-gate`, and asks you before anything merges. Need a quick
read-only analysis? `/secondmate-reason why does this test flake only in CI?`

## 🔁 How it works

```mermaid
flowchart LR
    A[loop-task: goal] --> M[maker<br/>isolated worktree]
    M --> C[checker<br/>different model, read-only]
    C --> V{verdict}
    V -- fail --> M
    V -- pass --> G{verify-gate}
    G -- refuse --> M
    G -- pass --> H{{your approval}}
    H -- merge --> D[ship]
```

> Deeper dive: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — roles, the guarantee behind every stage, and the full component map.

> 💡 **Best with herdr.** Run secondmate inside herdr (a tmux-backed terminal multiplexer for coding agents) and the maker and the cross-model checker each get their own live pane you can watch and jump into: the whole loop, visible. It's how I run it, on herdr + tmux. Anywhere else it falls back to in-process sub-agents, same guards and all.

## 🧰 What's inside

| Component | What it does |
|---|---|
| `secondmate` skill | The maker/checker SOP: triage → spawn → check → gate → hold → integrate |
| SessionStart hook | Surfaces durable open decisions each session so a restart never drops a pending gate |
| `bin/hold.py` | Durable human-gate decisions (`hold` / `answer` / `open`) |
| `bin/verify-gate.sh` | Pre-integration gate: clean tree, non-empty diff, **exact-SHA** match, tests |
| `bin/launch-checker.sh` | Edit-locked (`--exclude-tools edit,write`) cross-model checker + verdict-envelope contract |
| `bin/verdict.py` | Parse the checker's `{verdict}` → exit `0` pass / `1` fail / `2` error·refused |
| `bin/loop-guard.sh` | Stuck-loop abort + per-run round cap + global spawn cap |
| `bin/run-round.sh` | Wall-clock timeout + idle watchdog + paired audit record (even on kill) |
| `bin/prune-output.sh` | Model-free head/tail truncation of bulky logs |
| `bin/new-worktree.sh` | Isolated git worktree per maker (never the primary checkout) |
| `bin/reason.sh` | Read-only, tool-free reasoning one-shot on a reasoning model |

**Commands:** `/secondmate-doctor` · `/secondmate-reason` · `/secondmate-verify` · `/loop-task`

## 📦 Requirements

`git`, `gh`, `python3`, and a **checker harness CLI** (defaults to [`pi`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)).
Just run **`/secondmate-doctor`** — it detects and installs everything, asking only for your approval; it never
hands you a manual checklist. Cross-model checking additionally needs a **second model family + credentials**
for your harness (only you can supply those).

<details>
<summary><b>Companions</b> — installed by <code>/secondmate-doctor</code></summary>

<br/>

| Companion | What it adds | Install |
|---|---|---|
| **pi** | default checker + reasoning harness (multi-model) | `npm install -g @earendil-works/pi-coding-agent` |
| **herdr** | visible multi-pane maker/checker orchestration | `brew install herdr` |
| **ponytail** | complexity / over-engineering lens | `claude plugin install ponytail@ponytail` |
| **loop-task** | maker/checker loop driver command | **bundled — ships with secondmate** |
| **adhd** | divergent ideation for open-ended triage | `claude plugin marketplace add UditAkhourii/adhd && claude plugin install adhd@adhd` |

</details>

<details>
<summary><b>Configuration</b> — env vars, all optional (sane defaults)</summary>

<br/>

| Var | Default | Purpose |
|---|---|---|
| `SM_CHECKER_HARNESS` | `pi` | checker CLI |
| `SM_CHECKER_PROVIDER` | `amazon-bedrock` | checker provider |
| `SM_CHECKER_MODEL` | `global.openai.gpt-5.6-terra` | checker model (a **different family** than the maker) |
| `SM_CHECKER_THINKING` | `high` | checker reasoning effort |
| `SM_CHECKER_PROMPT` | `bin/checker-prompt.md` | base checker discipline (point at your own to override) |
| `SM_REASON_HARNESS` | `pi` | reasoning CLI |
| `SM_REASON_PROVIDER` | `amazon-bedrock` | reasoning provider |
| `SM_REASON_MODEL` | `r1` | default reasoning model alias (`r1` / `gpt` / `sonnet` / full id) |
| `SM_HOLD_LEDGER` | `./decisions.jsonl` | per-repo decision ledger |
| `SM_LOOP_STATE` | `./.secondmate` | loop-guard state dir |
| `SM_WT_ROOT` | `~/.secondmate-worktrees` | where maker worktrees are created |

The default model IDs are Amazon Bedrock inference-profile IDs — override them for your provider.

</details>

<details>
<summary><b>Manual install &amp; verify</b></summary>

<br/>

```sh
# install from a local clone instead of GitHub
claude plugin marketplace add /path/to/secondmate
claude plugin install secondmate@secondmate

# verify everything
bin/verdict.py selfcheck && bin/loop-guard.sh selfcheck && bin/verify-gate.sh --selfcheck \
  && bin/prune-output.sh --selfcheck && bin/run-round.sh selfcheck && bin/reason.sh --selfcheck \
  && bin/doctor.sh --selfcheck && echo ALL_OK
claude plugin validate .
```

</details>

## License

[MIT](LICENSE) © Eshwar Vijay
