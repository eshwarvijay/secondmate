# RE sub-lens: hidden / conditional / dynamic behavior

Hunt behavior that only fires under certain conditions, or that hides what it really does. A CONFIRMED
hidden, dormant, obfuscated, or backdoored behavior = `fail`.

- **Env / host / date / time gating** — `if os.getenv("CI")`, `if not sys.gettrace()`, hostname or date
  comparisons, debug/feature flags, prod-vs-test sniffing. The source analog of anti-debug/anti-VM: the code
  behaves differently when observed. Report the gate and what changes behind it.
- **Encoded / obfuscated payloads** — base64/hex/char-code arrays/rot13/XOR that decode to a URL, command,
  or key. Decode it and report what it becomes.
- **Dynamic dispatch hiding the real target** — `eval`, `Function`, `exec`, `__import__`,
  `getattr`/reflection by computed string, import aliasing, a URL/command assembled at runtime. The real
  callee isn't the one you read at a glance — resolve it.
- **Logic / time bombs, counters, decoy branches, dormant paths.**
- **Cluster signal** — network egress + encoding + persistence/exec appearing together is far stronger than
  any one alone. Call it out as a cluster.

If a construct is present but you can't fully resolve it (minified, dynamic), mark SUSPECTED and say why.
