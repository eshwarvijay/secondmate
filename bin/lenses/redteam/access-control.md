# Red-team sub-lens: access control (authn / authz / business logic)

Hunt for who-can-do-what breaks. A CONFIRMED bypass crossing an identity or ownership boundary = `fail`.
Cite the missing check at `file:line` and give the concrete request.

**Authentication:**
- New endpoint/handler with no auth decorator/middleware.
- JWT: `alg:none`, unverified signature, missing `exp`/`aud`/`iss`, weak or predictable secret.
- Session fixation, predictable tokens, timing-unsafe secret compare (`==` on an HMAC/token).

**Authorization:**
- **IDOR** — an object id from the request used without an ownership/tenant check. Payload:
  `GET /api/orders/1002` while authed as the owner of `1001`; name the missing check.
- **Mass assignment** — request body bound straight to a model: `POST {"role":"admin"}` / `{"price":0}`
  where the field should be server-controlled.
- Missing role/tenant scoping; privilege escalation via a parameter; a new route that bypasses existing
  path/verb-based access.

**Business logic:**
- TOCTOU / races on balance, quota, coupon, inventory; negative or overflowing quantities.
- Replay of "idempotent-looking" requests; workflow-step skipping; price/discount manipulation.

Give the exact request (method, path, body, auth context) and the boundary it crosses.
