# Reverse-engineer lens — router

Comprehension and intent-vs-reality review, layered on the base checker (read-only + `{verdict}` envelope
already in force). For code you can't take at face value: reconstruct what it ACTUALLY does. Not generic
bug-finding (base lens) and not generic vuln scanning (redteam lens).

**How the supervisor uses this:** inject the sub-lenses the change calls for:

```
launch-checker.sh --lens reverse-engineer/dataflow --lens reverse-engineer/unknown-code -- -p "<review + diff>"
```

| Sub-lens | Hunts | Load when the diff touches |
|---|---|---|
| [dataflow](dataflow.md) | how data/control actually moves | any non-trivial logic; where inputs reach effects |
| [hidden-behavior](hidden-behavior.md) | env/time-gated, encoded, or dynamically-dispatched behavior | obfuscated/minified/generated code, or effects that look bigger than the stated change |
| [intent-vs-impl](intent-vs-impl.md) | does it do what it claims, and only that? | comments/names/commit message make claims; scope looks wider than described |
| [unknown-code](unknown-code.md) | trust protocol for code you didn't write | third-party, vendored, copied, generated, or minified code |
