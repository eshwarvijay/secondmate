---
description: Ask a read-only reasoning model (via fm-loop) a hard analysis question — root-cause, triage, plan review, pre-mortem — without spending this session's context.
---

Run the fm-loop reasoning one-shot and relay the model's answer verbatim, then add your own one-line take.

Question / task: $ARGUMENTS

Execute:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/reason.sh" "$ARGUMENTS"
```

If the user's request references a file or diff, pass it with `--context <path>` (repeatable). Use
`--model gpt` for GPT-5.6 or `--model r1` (default) for DeepSeek-R1. This is read-only and tool-free.
