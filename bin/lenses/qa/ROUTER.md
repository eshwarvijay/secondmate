# QA lens — router

Test-quality and verification review, layered on the base checker (read-only + `{verdict}` envelope already
in force). Each sub-lens adds only its specialized hunt. Not generic bug-finding — that's the base lens.

**How the supervisor uses this:** match the diff to the rows and inject only what applies:

```
launch-checker.sh --lens qa/test-reality --lens qa/coverage -- -p "<review + diff>"
```

| Sub-lens | Hunts | Load when |
|---|---|---|
| [test-reality](test-reality.md) | is the verification real, or just claimed? | the change ships tests, or asserts "tests pass" |
| [coverage](coverage.md) | which behavior paths are untested | any new/changed behavior |
| [risk-flagging](risk-flagging.md) | high-blast-radius changes with thin tests | auth, migrations, money, public API, PII, destructive ops |
| [behavioral-contracts](behavioral-contracts.md) | would a silent regression be caught? | transforms, parsers, formatters, LLM/agent steps, eval oracles |
