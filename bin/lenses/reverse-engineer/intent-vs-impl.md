# RE sub-lens: intent vs. implementation

Read the commit/PR description and the comments, then verify the code does that AND ONLY that. A material
mismatch between stated intent and traced behavior = `fail`. A symbol name is a hint, never evidence.

- **Delivers the stated purpose?** And does it do MORE than stated — scope creep into auth, crypto, network,
  CI, or build config that the description never mentioned?
- **Comment / name lies** — a comment says "validate" but the body returns early; a function named
  `sanitize` that passes input through unchanged; a name describing the opposite of the code.
- **Dead code, backdoor stubs, bypassed guards** — unexplained TODO/stub, commented-out checks now skipped.
- **Dependency changes** — is the package real (typosquat/lookalike check), pinned, lockfile/hash-backed,
  from the official source? Does it run install/import-time hooks? Is it actually used, or pulled in to
  justify running its side effects?
- **Unexplained obfuscation / minification / indirection** in ordinary source is itself a finding.
