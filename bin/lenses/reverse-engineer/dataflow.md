# RE sub-lens: data & control flow

Reconstruct how values and control actually move through the changed code. Record what you traced vs. what
you couldn't resolve. Cite `file:line` and quote the triggering code for every finding.

- **Entry points** — every way the code can be invoked: public API, HTTP/RPC route, CLI arg, event/callback,
  decorator/metaclass, constructor, module top-level code that runs on import, deserialization hooks
  (`__reduce__`, `readObject`, pickle, YAML), package lifecycle hooks (`postinstall`, `setup.py`). Import-time
  and install-time code is the highest-priority entry point — it runs before anyone calls anything.
- **Sources → sinks** — trace each new/changed value from where it ENTERS (params, request body, env, file
  reads, DB rows, deserialization, third-party returns) to where it LANDS (`exec`/`eval`/`spawn`/`system`,
  SQL, file paths written/read/deleted, network calls, template render, reflection, auth decisions, logs).
  Flag untrusted value → sink without validation, and any secret → log/network sink.
- **Control flow** — reconstruct the real branch structure. Hunt branches gated on attacker-influenced,
  rarely-true, or magic-value conditions; always-true/false guards; early returns that quietly no-op a check;
  dead/unreachable code.
- **Trust boundaries** — mark every point where untrusted data crosses into trusted context or privilege
  changes: deserialization, subprocess, dynamic import/reflection, auth middleware, tenant isolation.
- **External calls & side effects** — list EVERY network egress (URL/host/IP), file I/O (exact paths),
  process/exec, env read/write, and new-dependency call the diff introduces. For each: is it explained by the
  stated purpose? An unexplained egress or write is a finding.
- **State mutations** — global/module/singleton state, monkeypatching, prototype pollution, config/cache
  mutation — anything with effects outliving the call.
