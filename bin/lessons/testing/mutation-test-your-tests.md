---
tags:
  - selfcheck
  - regression
  - testing
  - mutation
evidence: E4
earned-in: seed
---

A selfcheck/regression test must call the actual function or code path it claims to test, not a separate reimplementation of the same logic — before shipping a new test, mutation-test it yourself: temporarily break the real fix, confirm the test then fails, then restore the fix. A test that still passes after the fix it's supposed to guard is removed is not a real test.
