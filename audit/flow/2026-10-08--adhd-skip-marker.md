## 2026-10-08 — adhd-skip-marker: aborted after 5 non-converging real-bug checker fails

Dispatched a solo sub-agent-supervisor (`sm-adhd-skip-marker`) to make adhd's completion
distinguishable from "never invoked" via a real lifecycle signal (which became
`adhdCompletedViaDispatch` in the watchdog mod, built separately in-session). Claude maker, 5
fix rounds, each round's checker verdict was `fail` tagged `real-bug` (not the same complaint
repeating by luck). Aborted by the top-level supervisor after the human asked to stop it,
following `nonConvergingRounds`'s own 3-fail threshold being well exceeded with no pass in
sight. Never reached Hold.
