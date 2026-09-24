## 2026-09-01 — skill: thinking medium + loop-back contract

- **Decisions:** (1) pi maker `--thinking off` → `medium`; (2) checker fail → supervisor synthesizes plan → task-scoped maker, never inline fix; (3) refused/error → escalate not loop; (4) all maker agent names task-scoped (`sm-<task-id>`); (5) visible recipe: spawn not delegate, guard on mk_pane before prompt; (6) checker recipe: --diff-base required; (7) unique round markers per checker run
- **Bugs caught by checker:** stale global agent name, README not updated, eval grader stale, hardcoded sm-maker in visible recipe, missing --diff-base in checker recipe, delegate returns no pane_id, spawn guard missing
- **Escalations:** none
