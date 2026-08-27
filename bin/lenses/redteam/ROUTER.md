# Red-team lens — router

Adversarial security review, layered on the base checker. The base already enforces read-only, the
CONFIRMED/SUSPECTED labels, and the `{verdict}` envelope — the sub-lenses below do NOT repeat any of that.
Each adds only the specialized hunt for one class of attack.

**How the supervisor uses this:** read the diff, match its signals in the table, and inject ONLY the
sub-lenses that the change can actually reach:

```
launch-checker.sh --lens redteam/injection --lens redteam/llm -- -p "<review request + diff>"
```

Load nothing the diff can't touch — focused context beats a generic dump. If several rows apply, inject
several. If none clearly apply but the change is security-sensitive, inject the closest and note the residual risk.

| Sub-lens | Hunts | Load when the diff touches |
|---|---|---|
| [injection](injection.md) | untrusted data reaching an interpreter | string-built SQL, shell/exec, templates, `eval`, file paths, HTML output |
| [access-control](access-control.md) | authn / authz / business-logic bypass | endpoints, auth/session/JWT, object access by id, role/tenant checks, request-body binding, balances/quotas |
| [server-side-requests](server-side-requests.md) | SSRF / XXE | server fetches a user-supplied URL/host, webhooks, URL preview, XML parsing |
| [deserialization](deserialization.md) | untrusted bytes → objects/code | pickle / yaml / marshal, `readObject`, `unserialize`, prototype merge, `vm` |
| [secrets-supply-chain](secrets-supply-chain.md) | leaked secrets, unsafe defaults, bad deps | config/secret handling, new or changed dependency, install scripts, TLS/CORS/debug flags |
| [llm](llm.md) | attacks on prompt / agent / RAG code (OWASP LLM Top-10) | prompt building, tool/agent loops, RAG retrieval, model output feeding a sink |
