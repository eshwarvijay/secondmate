# RE sub-lens: unknown-code protocol (third-party / generated / copied / vendored)

Trust NOTHING here until you've traced it — provenance is not behavior. State clearly what you could and
couldn't verify.

- **Third-party / vendored** — verify the real name (not a typosquat), a pinned version, and hash/lockfile
  backing. Read what it does at YOUR call sites AND its import/install-time code.
- **Copied / vendored blobs** — diff against the upstream original when reachable; a single altered line
  inside an otherwise-faithful copy is the classic backdoor. If you can't fetch upstream, say so — don't
  paper over it.
- **Generated / LLM-authored code** — confirm it matches the requested spec exactly and adds no extra
  endpoints, exec, secrets, or dependencies. Generated code hallucinates plausible-but-wrong APIs and can
  silently widen scope; an unverifiable claim is SUSPECTED, not a pass.
- **Minified / transpiled bundles** — do not eyeball-trust. If you can't read it, mark SUSPECTED, state it's
  unreadable, and recommend the supervisor require the source form.

Code you were told to trust but can't read, carrying a plausible exfil/exec vector you can't clear, = `fail`.
