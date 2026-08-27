# Red-team sub-lens: secrets, unsafe defaults & supply chain

Hunt for leaked secrets, dangerous defaults, and untrusted dependencies. A CONFIRMED secret exposure or a
malicious/unverifiable dependency = `fail`.

**Secrets exposure:**
- Hardcoded keys/tokens/passwords; secrets in logs/errors/URLs/fixtures; `.env` echoed; a debug endpoint
  dumping env.

**Unsafe defaults:**
- Debug mode on, `verify=False` / TLS check disabled, permissive CORS (`*` with credentials), `0.0.0.0`
  bind, world-writable perms (`0777`), disabled CSRF, default creds, wildcard IAM.

**Supply chain:**
- New/changed dependency: typosquat/lookalike, unpinned, git-URL source, `postinstall` / `setup.py` hooks.
- Hallucinated / non-existent package name ("slopsquat"), lockfile drift, `curl | sh` in CI.
- Verify the package exists, is pinned, and is hash/lockfile-backed; flag if not, and flag any removed
  integrity check.
