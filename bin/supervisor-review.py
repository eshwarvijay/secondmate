#!/usr/bin/env python3
"""Validate structured, read-only CI supervisor output and render its triage."""
import argparse, json, pathlib, re, sys

FENCE = re.compile(r"```json\s*(\{.*?\})\s*```", re.S)

def envelope(path):
    blocks = FENCE.findall(pathlib.Path(path).read_text(encoding="utf-8"))
    if not blocks: raise ValueError("supervisor response has no fenced JSON envelope")
    return json.loads(blocks[-1])

def strings(data, key):
    value = data.get(key, [])
    if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
        raise ValueError(f"{key} must be a list of non-empty strings")
    return value

def plan(args):
    data = envelope(args.report)
    allowed = set(filter(None, args.allowed.split(",")))
    mandatory = set(filter(None, args.mandatory.split(",")))
    selected = strings(data, "selected_lenses")
    if not set(selected) <= allowed: raise ValueError("supervisor selected a lens outside the allowlist")
    selected = sorted(set(selected) | mandatory)
    if not mandatory <= allowed: raise ValueError("workflow mandatory lens is outside the allowlist")
    output = {"selected_lenses": selected, "focus": strings(data, "focus"),
              "deprioritize": strings(data, "deprioritize"),
              "rationale": data.get("rationale", "")}
    if not isinstance(output["rationale"], str): raise ValueError("rationale must be a string")
    pathlib.Path(args.out).write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")

def triage(args):
    data = envelope(args.report)
    sections = [("Must fix", strings(data, "must_fix")), ("Should fix", strings(data, "should_fix")),
                ("Defer", strings(data, "defer")), ("Skip", strings(data, "skip"))]
    summary = data.get("summary", "")
    if not isinstance(summary, str): raise ValueError("summary must be a string")
    text = "### Supervisor decision — Ponytail\n\n" + (summary.strip() or "Grounded prioritization completed.") + "\n"
    for title, items in sections:
        text += f"\n#### {title}\n" + ("\n".join(f"- {item}" for item in items) if items else "- None.") + "\n"
    pathlib.Path(args.out).write_text(text, encoding="utf-8")

def main():
    p = argparse.ArgumentParser(); sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("plan"); a.add_argument("--report", required=True); a.add_argument("--allowed", required=True); a.add_argument("--mandatory", default=""); a.add_argument("--out", required=True)
    b = sub.add_parser("triage"); b.add_argument("--report", required=True); b.add_argument("--out", required=True)
    args = p.parse_args()
    try: {"plan": plan, "triage": triage}[args.cmd](args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr); return 2
    return 0
if __name__ == "__main__": sys.exit(main())
