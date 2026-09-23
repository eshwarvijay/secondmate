---
tags:
  - debugging
  - one-liner
  - recursion
  - symlinks
  - loops
evidence: E4
earned-in: seed
---

Avoid long ad-hoc debugging one-liners typed directly at an interactive prompt for anything involving loops, symlinks, or recursion — write a small throwaway script file instead and run that. A shell syntax mistake in an inline one-liner can leave a runaway loop that doesn't actually stop, burning time and context without you noticing until it's very deep in.
