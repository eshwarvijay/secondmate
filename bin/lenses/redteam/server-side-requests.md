# Red-team sub-lens: server-side requests (SSRF / XXE)

Hunt for the server making a request an attacker controls. A CONFIRMED path to an internal/metadata
target = `fail`. Give the input value and trace it to the fetch/parse call at `file:line`.

**SSRF** — the server fetches a user-supplied URL/host (webhooks, image/PDF fetch, URL preview, OIDC discovery):
- Cloud metadata: `http://169.254.169.254/latest/meta-data/iam/security-credentials/`.
- Internal targets: `http://localhost:6379`, `http://[::1]`, private ranges, `file://`, `gopher://`.
- Widening: does it follow redirects? Is it DNS-rebind-able? Is the "allow-list" actually a blocklist that
  misses `0.0.0.0`, octal/decimal IPs, or IPv6?

**XXE** — an XML parser with external entities / DTDs enabled: name the parser and the entity payload;
check for local-file read and SSRF-via-entity.
