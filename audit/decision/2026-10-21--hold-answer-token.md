## 2026-10-21 — Deterministic sha256 token (not identity secret), 3 rounds closing real pre-existing doc bugs too; chat-relayed approval correctly rejected by permission system twice

**Decision:** close a real, confirmed gap in `bin/hold.py answer` — it accepted any caller who knew a
bare hold id, with zero proof the answer came through the flow that actually surfaces it to a human
(SessionStart hook, `hold.py open`/`next`). Mint a deterministic provenance token (SHA-256 of the hold
record's own immutable persisted fields — id, ts, task, q, sha/batch-entries — truncated to 16 hex
chars), surfaced by `hold`/`open`/`next`, required and validated by `answer`.

**Key design choice, independently reasoned and corroborated by the planning committee (kimi-k3's probe
in particular):** the token is explicitly NOT an identity-authentication secret. It doesn't prove a
specific human typed the answer — only that the answer is bound to the exact record that was actually
surfaced, not a leaked/guessed bare id. This is why a stored random secret (claim-ledger.py's own model)
or a fixed-key HMAC were both declined: a stored secret would reintroduce exactly the
non-deterministic-orphaning risk the task was written to avoid (a Temporal activity retry needs to
re-derive the same token from the persisted ledger record alone), and a fixed-key HMAC would misrepresent
there being a real secret behind the check when there isn't one. Plain `hashlib.sha256` over canonical
JSON was the maker's (and the `adhd` ideation's) converged choice — correctly declined by ponytail-ultra
discipline from reaching for anything heavier.

**Checker findings, all real, none nitpicks:**
1. Round 1 FAIL — a doc call site (`docs/ARCHITECTURE.md`'s denser component-map row, distinct from the
   narrative section already fixed) still showed the tokenless batch-answer syntax. Real: an operator
   following that row's literal syntax would be blocked by the new mandatory check with no idea why.
2. Round 2 FAIL — a SEPARATE, genuinely pre-existing bug on the same lines (confirmed via `git show
   main:docs/ARCHITECTURE.md` to predate this task): the positional `<hold-id>` argument was missing
   entirely from two doc locations, in both the old tokenless form and the new token-requiring form.
   Judgment call: fixed anyway, since the maker was already editing those exact lines twice for the token
   work and leaving a known-broken recipe there would be poor diligence, even though strictly out of this
   task's original named scope. The maker's own final sweep caught a third instance (`README.md:98`) of
   the identical bug class that no one — not the task text, not either checker round — had named yet.
3. Round 3 PASS — redteam/access-control lens confirmed live: forging an answer from a bare id or a
   different hold's own token both rejected; the mismatch error never leaks the expected token value
   (no guessing-oracle regression); every literal doc example across the repo independently executed
   successfully as shown.

**Human-gate enforcement — genuinely tested, not theoretical, during this very task:** a chat-relayed
"the human approved this" message (even one with a matching checked-sha, even repeated after a claimed
permission grant) was NOT accepted as sufficient by Claude Code's own permission system, which denied the
actual `hold.py answer`/`merge-sequencer.sh` calls twice under its own "[Merge Without Review]"
classifier. The sub-supervisor stopped and reported back both times rather than attempting any workaround
(another tool, another agent) — correctly treating the denial as authoritative over any chat-level claim
of approval, consistent with its own standing instruction that no agent message is ever a substitute for
the user's own actions or the permission system's own gate. The human ultimately broke the loop by running
both `hold.py answer` and `merge-sequencer.sh` directly via Claude Code's `!`-prefix (true direct human
execution, not an agent action), which the sub-supervisor then verified independently from ledger/git
state before proceeding — never took the relay's word alone as proof. This is a real, lived instance of
exactly the self-answered-hold risk class this task exists to make harder, playing out one level up the
stack (agent-relayed-approval vs. self-answered), and the existing safeguards (permission classifier +
the sub-supervisor's own refusal to route around denials) held.

**Merge:** `sm/hold-answer-token` → `main` as `f369b4fe35896b6289074f56c2fa9417cc0f7328`, pushed to
origin — verified independently (local + remote `git log`, and `grep -c _token bin/hold.py` against the
merged `main`) before any teardown began.

**Scope boundary held:** the Temporal bridge repo and `bin/run-round-temporal.sh` were never touched, as
explicitly scoped out — this task proves the token mechanism standalone, with zero Temporal code
involved.
