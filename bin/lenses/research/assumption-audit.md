# Research sub-lens: assumption audit

Enumerate the change's load-bearing assumptions — the claims that, if false, break it — and classify each.
An ASSERTED assumption the whole change hinges on is your headline finding; an unverified critical assumption
= `fail`.

For each load-bearing assumption, classify:

- **VERIFIED** — evidence for it is present in the diff/repo/deps (cite `file:line` or the source you checked).
- **VERIFIABLE-BUT-UNCHECKED** — you could confirm it from available evidence, but the maker gave no sign
  they did and you couldn't conclusively confirm it read-only within reach.
- **ASSERTED** — relied upon with no traceable evidence; rests on model memory or intuition.

Prioritize by consequence: an assumption whose failure is catastrophic and is only ASSERTED outranks a dozen
minor unchecked ones. State each assumption in one line, its classification, and (for the critical ones) what
concrete evidence would move it to VERIFIED.

Be honest about your own coverage limits — an assumption you couldn't reach is SUSPECTED, and a change resting
on it isn't a clean pass.
