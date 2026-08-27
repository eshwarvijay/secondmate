# Research sub-lens: prior art & alternatives

Did the change build on what already exists, or reinvent/diverge from it? Flag ungrounded design decisions —
a change that works but ignores available prior art is poorly founded.

- **Existing pattern in THIS repo** — does the codebase already solve this class of problem a certain way?
  Grep for sibling call sites, similar features, established conventions. A change that invents a second,
  divergent way to do an already-solved thing is a finding even if it works; point at the established pattern
  at `file:line`.
- **Simpler / standard approach ignored** — was there a stdlib primitive, a native platform feature, or an
  already-vendored dependency that would have done this with less custom code? Flag it when the ignored prior
  art also signals the maker didn't actually check. (Full over-engineering review belongs to the complexity
  lens — you only flag the *groundedness* angle: they reinvented because they didn't look.)
- **Consistency** — does the change follow how the codebase already does similar things (error handling,
  config loading, logging, naming, layering)? Divergence without a stated reason is an ungrounded decision.
