#!/usr/bin/env python3
"""Create and validate the small, versioned record that proves a Secondmate review.

  review-attestation.py create --task ID --jira-key KEY --base-sha SHA --checked-sha SHA \
    --checker-harness HARNESS --checker-provider PROVIDER --checker-model MODEL \
    --round-output N:FILE [--round-output N:FILE ...] \
    [--test CMD ...] [--flow PATH] [--decision PATH] [--out PATH]
  review-attestation.py validate FILE
  review-attestation.py selfcheck

The attestation deliberately stores checker conclusions, not raw model transcripts.  It is small
and safe to commit at audit/reviews/<jira-key>--<task>.json; raw outputs stay local or as CI artifacts.
"""
import argparse, datetime as dt, json, pathlib, re, sys, tempfile

SHA = re.compile(r"^[0-9a-f]{7,64}$")
KEY = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
VALID = {"pass", "fail", "error", "refused"}
FENCED = re.compile(r"```json\s*(\{.*?\})\s*```", re.S)


def envelope(path):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    matches = FENCED.findall(text)
    if not matches:
        raise ValueError(f"{path}: no fenced JSON verdict envelope")
    try:
        value = json.loads(matches[-1])
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: malformed final verdict envelope: {exc.msg}") from exc
    if not isinstance(value, dict) or value.get("verdict") not in VALID:
        raise ValueError(f"{path}: envelope has no valid verdict")
    findings = value.get("findings", [])
    if not isinstance(findings, list) or not all(isinstance(x, str) for x in findings):
        raise ValueError(f"{path}: findings must be a list of strings")
    lenses = value.get("lens_coverage", {})
    if not isinstance(lenses, dict) or not all(isinstance(k, str) and v is True for k, v in lenses.items()):
        raise ValueError(f"{path}: lens_coverage must map lens names to true")
    return {"verdict": value["verdict"], "findings": findings,
            "diagnostic": value.get("diagnostic", ""), "lens_coverage": lenses}


def validate(value):
    errors = []
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    for name in ("task_id", "jira_key"):
        if not isinstance(value.get(name), str) or not value[name]: errors.append(f"{name} is required")
    if isinstance(value.get("jira_key"), str) and not KEY.fullmatch(value["jira_key"]): errors.append("jira_key has invalid format")
    for name in ("base_sha", "checked_sha"):
        if not isinstance(value.get(name), str) or not SHA.fullmatch(value[name]): errors.append(f"{name} must be a git SHA")
    checker = value.get("checker")
    if not isinstance(checker, dict) or not all(isinstance(checker.get(k), str) and checker[k] for k in ("harness", "provider", "model")):
        errors.append("checker.harness, checker.provider, and checker.model are required")
    rounds = value.get("review_rounds")
    if not isinstance(rounds, list) or not rounds: errors.append("review_rounds must be a non-empty list")
    else:
        for expected, row in enumerate(rounds, 1):
            if not isinstance(row, dict) or row.get("number") != expected or row.get("verdict") not in VALID:
                errors.append("review_rounds must be consecutively numbered with valid verdicts"); break
            if not isinstance(row.get("findings"), list): errors.append("every round needs findings"); break
        if rounds[-1].get("verdict") != "pass": errors.append("final review round must pass")
    if value.get("verdict") != "pass": errors.append("attestation verdict must pass")
    if not isinstance(value.get("tests"), list) or not all(isinstance(x, str) for x in value["tests"]): errors.append("tests must be a string list")
    if not isinstance(value.get("reviewed_at"), str): errors.append("reviewed_at is required")
    return errors


def create(args):
    parsed = []
    for item in args.round_output:
        try: number, path = item.split(":", 1); number = int(number)
        except ValueError: raise ValueError(f"invalid --round-output {item!r}; use N:FILE")
        row = envelope(path); row["number"] = number; parsed.append(row)
    parsed.sort(key=lambda r: r["number"])
    attestation = {
        "schema_version": 1, "task_id": args.task, "jira_key": args.jira_key,
        "base_sha": args.base_sha, "checked_sha": args.checked_sha, "verdict": parsed[-1]["verdict"],
        "checker": {"harness": args.checker_harness, "provider": args.checker_provider, "model": args.checker_model},
        "review_rounds": parsed, "tests": args.test,
        "audit": {k: v for k, v in (("flow", args.flow), ("decision", args.decision)) if v},
        "reviewed_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    }
    errors = validate(attestation)
    if errors: raise ValueError("; ".join(errors))
    out = pathlib.Path(args.out or f"audit/reviews/{args.jira_key.lower()}--{args.task}.json")
    if out.exists() and not args.force: raise ValueError(f"{out} exists (use --force to replace)")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(attestation, indent=2) + "\n", encoding="utf-8")
    print(out)


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("create")
    for flag in ("task", "jira_key", "base_sha", "checked_sha", "checker_harness", "checker_provider", "checker_model"):
        c.add_argument("--" + flag.replace("_", "-"), required=True)
    c.add_argument("--round-output", action="append", required=True)
    c.add_argument("--test", action="append", default=[]); c.add_argument("--flow"); c.add_argument("--decision")
    c.add_argument("--out"); c.add_argument("--force", action="store_true")
    v = sub.add_parser("validate"); v.add_argument("file")
    sub.add_parser("selfcheck")
    args = parser.parse_args(argv)
    try:
        if args.command == "create": create(args)
        elif args.command == "validate":
            errors = validate(json.loads(pathlib.Path(args.file).read_text(encoding="utf-8")))
            if errors: raise ValueError("; ".join(errors))
            print("valid")
        else:
            with tempfile.TemporaryDirectory() as d:
                d = pathlib.Path(d); report = d / "round.md"
                report.write_text('report\n```json\n{"verdict":"pass","findings":[],"diagnostic":"","lens_coverage":{"qa/coverage":true}}\n```\n')
                out = d / "audit/reviews/EAD-1--demo.json"
                create(argparse.Namespace(task="demo", jira_key="EAD-1", base_sha="a" * 40, checked_sha="b" * 40, checker_harness="pi", checker_provider="amazon-bedrock", checker_model="model", round_output=["1:" + str(report)], test=["pytest -q"], flow=None, decision=None, out=str(out), force=False))
                errors = validate(json.loads(out.read_text()))
                if errors: raise ValueError("; ".join(errors))
            print("ok")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr); return 2
    return 0

if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
