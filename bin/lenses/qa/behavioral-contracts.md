# QA sub-lens: behavioral contracts / eval

Think in pinned inputs → pinned expected outputs. Ask, concretely: "if someone changed the output tomorrow,
which test turns red?" If the answer is "none," the behavior is unprotected — CONFIRMED gap.

- **Pinned inputs/outputs.** A test that asserts a type or a non-empty result but not the *value* lets
  behavior drift silently. Require an assertion on the actual expected output for representative inputs.
- **Ground truth.** For transformations, formatters, parsers, and LLM/agent steps: is the expected output
  written down and compared, or is the test just "didn't crash"? No expectation = no eval = silent
  regressions pass.
- **Judge / oracle calibration.** If the change introduces or relies on an LLM-as-judge, fuzzy matcher,
  tolerance, or "close enough" comparator as the oracle, was it calibrated against known-good and known-bad
  examples? An over-lenient oracle passes broken output; an over-strict one is flaky. An uncalibrated judge
  gating a release is a finding.
- **Silent-regression test.** For each key behavior, name the input that would slip through if no test
  guards it.
- **Adversarial framing.** For guardrails/safety/validation changes, the meaningful test is the abuse case
  ("goal achieved = FAIL"). A guardrail tested only on well-behaved input is untested against its purpose.
