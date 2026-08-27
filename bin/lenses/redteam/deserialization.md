# Red-team sub-lens: deserialization

Hunt for untrusted bytes turned into objects or code. A CONFIRMED attacker-controlled input reaching a
deserialization sink = `fail`.

**Sinks:** `pickle.loads`, `yaml.load` (non-safe loader), `marshal`, Java `readObject`, PHP `unserialize`,
.NET `BinaryFormatter`, Node `vm` without isolation, and JS prototype-pollution merges
(`Object.assign` / deep-merge into `__proto__`).

Show that attacker bytes reach the sink and describe the gadget — e.g. a pickle/YAML payload whose
`__reduce__`/tag runs `os.system`, or a merge that pollutes `__proto__.isAdmin`. You need the sink plus the
attacker-controlled input path, not the full gadget chain. Flag any deserializer swapped from a safe to an
unsafe variant (`safe_load` → `load`, adding `pickle` on a network path).
