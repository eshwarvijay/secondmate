# QA sub-lens: test-reality (is the verification real?)

Your question: was correctness *proven*, or merely asserted? A change isn't "done" because someone said
"tests pass." Run these first; if verification isn't real, that alone = `fail`.

- **Do tests exist for the change?** Diff test files against source files. New/changed behavior with zero
  corresponding test edits is a CONFIRMED gap — name the untested function at `file:line`.
- **Fail-to-pass contract.** A test earns trust only if it would FAIL on the OLD code and PASS on the NEW.
  Mentally revert the change: does the new assertion still pass against pre-change behavior? If yes, the test
  is **vacuous** — it pins nothing. (A bug fix whose test passes even without the fix is the classic tell.)
- **Always-green / vacuous tests.** Flag: no assertion; `assert True`; asserting a literal against itself;
  asserting only "no exception thrown" for a function whose job is to return a value; snapshot tests
  auto-written from current output (they lock in bugs); `expect(mock).toHaveBeenCalled()` when the *result*
  is what matters.
- **Testing the mock, not the behavior.** If every collaborator is stubbed and the assertion only checks the
  stubs were called, the test proves wiring, not correctness. Flag when the computed output/side effect is
  never asserted.
- **Claimed vs. real.** Distinguish narration ("I ran the tests") from evidence (a run summary, CI status, a
  reproducible command). No runnable proof, or a command that wouldn't exercise the new path, = `fail`. Name
  the exact command that WOULD prove it, e.g. `pytest tests/test_billing.py::test_proration -q`.
- **Determinism.** Real `sleep(n)`/arbitrary waits, un-seeded randomness, wall-clock/timezone/order/network
  dependence — flaky, proves nothing reliably.
