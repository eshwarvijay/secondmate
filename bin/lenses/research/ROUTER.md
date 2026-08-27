# Research lens — router

Groundedness review, layered on the base checker (read-only + `{verdict}` envelope already in force). Judges
whether a change is WELL-FOUNDED — grounded in evidence and prior art — rather than a plausible-looking
guess. Not runtime bugs (base lens), not security (redteam), not tests (qa).

**How the supervisor uses this:** inject what fits a novel/uncertain/design-heavy change:

```
launch-checker.sh --lens research/groundedness --lens research/prior-art -- -p "<review + diff>"
```

| Sub-lens | Hunts | Load when the diff |
|---|---|---|
| [groundedness](groundedness.md) | hallucinated APIs, false version/flag assumptions, unchecked claims | calls a library/API, assumes a version, uses flags/kwargs, asserts facts |
| [prior-art](prior-art.md) | reinvention and divergence from existing patterns | adds net-new code that may duplicate repo/stdlib/dep behavior |
| [assumption-audit](assumption-audit.md) | load-bearing assumptions that were never verified | rests on claims that, if false, break it |
