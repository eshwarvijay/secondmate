#!/usr/bin/env python3
"""Select trusted incremental PR-review state and render an append-only bot comment.

  pr-review-state.py select --comments comments.json --repository OWNER/REPO --pr N \
    --head-sha SHA --trusted-login LOGIN [--out prior.json]
  pr-review-state.py render --repository OWNER/REPO --pr N --head-sha SHA --base-sha SHA \
    --jira-key KEY --mode MODE --report checker.md --check-url URL \
    [--prior prior.json] [--tests STATUS] [--out comment.md]

Comments are durable review memory. Only state authored by the configured bot login and
whose reviewed SHA remains an ancestor of the current PR head is eligible.
"""
import argparse, datetime as dt, hashlib, json, pathlib, re, subprocess, sys

MARKER = re.compile(r"<!-- secondmate-review-state:v1\s*(\{.*?\})\s*-->", re.S)
VALID = {"pass", "fail", "error", "refused"}


def load_json(path): return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
def dump(value, path): pathlib.Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
def ancestor(old, head):
    return subprocess.run(["git", "merge-base", "--is-ancestor", old, head]).returncode == 0

def states(comments, repository, pr, trusted):
    for comment in comments:
        if comment.get("user", {}).get("login") != trusted: continue
        match = MARKER.search(comment.get("body", ""))
        if not match: continue
        try: state = json.loads(match.group(1))
        except json.JSONDecodeError: continue
        if (state.get("schema_version") == 1 and state.get("repository") == repository and
            state.get("pr_number") == pr and state.get("head_sha") and
            isinstance(state.get("review_version"), int)):
            state["comment_id"] = comment.get("id")
            state["comment_url"] = comment.get("html_url", "")
            yield state

def select(args):
    candidates = [s for s in states(load_json(args.comments), args.repository, args.pr, args.trusted_login)
                  if ancestor(s["head_sha"], args.head_sha) and not s.get("findings_truncated", False)]
    prior = max(candidates, key=lambda s: (s["review_version"], s.get("reviewed_at", "")), default=None)
    if prior is None: prior = {"review_version": 0, "open_findings": [], "reason": "no valid trusted prior state"}
    dump(prior, args.out)
    print(prior["reason"] if "reason" in prior else f"v{prior['review_version']} from {prior['head_sha']}")

def final_envelope(report):
    text = pathlib.Path(report).read_text(encoding="utf-8")
    blocks = re.findall(r"```json\s*(\{.*?\})\s*```", text, re.S)
    if not blocks: raise ValueError("checker report has no fenced JSON envelope")
    data = json.loads(blocks[-1])
    if data.get("verdict") not in VALID or not isinstance(data.get("findings"), list):
        raise ValueError("checker report has invalid verdict/findings")
    for key in ("resolved_finding_ids", "still_open_finding_ids", "superseded_finding_ids"):
        if key in data and (not isinstance(data[key], list) or not all(isinstance(x, str) for x in data[key])):
            raise ValueError(f"{key} must be a list of strings")
    return data

def finding_id(jira, finding):
    return "F-" + hashlib.sha256((jira + "\0" + finding).encode()).hexdigest()[:12]

def render(args):
    report = pathlib.Path(args.report).read_text(encoding="utf-8")
    envelope = final_envelope(args.report)
    prior = load_json(args.prior) if args.prior else {"review_version": 0, "open_findings": []}
    version = prior.get("review_version", 0) + 1
    findings = [{"id": finding_id(args.jira_key, item), "text": item} for item in envelope["findings"]]
    # Checker may preserve old IDs explicitly. New current-report findings remain open on fail.
    current_ids = {x["id"] for x in findings}
    still = set(envelope.get("still_open_finding_ids", []))
    resolved = set(envelope.get("resolved_finding_ids", []))
    superseded = set(envelope.get("superseded_finding_ids", []))
    old_ids = {x.get("id") for x in prior.get("open_findings", [])}
    unresolved_old = old_ids - resolved - superseded
    # If the checker omitted classifications, preserve old items only when explicitly listed as still open.
    open_findings = findings + [x for x in prior.get("open_findings", []) if x.get("id") in still and x.get("id") not in current_ids]
    status = {"pass": "✅ Pass", "fail": "❌ Needs changes", "error": "⚠️ Review error", "refused": "⚠️ Review refused"}[envelope["verdict"]]
    prior_link = f"[v{prior['review_version']}]({prior.get('comment_url', '')})" if prior.get("comment_id") else "none"
    resolution = "\n".join(f"- `{item}` {'✅ resolved' if item in resolved else '↪ superseded' if item in superseded else '❌ still open'}" for item in sorted((resolved | superseded | still) & old_ids)) or "- No prior findings to resolve."
    listed = "\n".join(f"- `{item['id']}` — {item['text']}" for item in findings) or "- No findings."
    state = {"schema_version": 1, "repository": args.repository, "pr_number": args.pr,
             "review_version": version, "parent_comment_id": prior.get("comment_id"),
             "head_sha": args.head_sha, "base_sha": args.base_sha, "jira_key": args.jira_key,
             "mode": args.mode, "verdict": envelope["verdict"], "open_findings": open_findings,
             "resolved_finding_ids": sorted(resolved), "still_open_finding_ids": sorted(still),
             "superseded_finding_ids": sorted(superseded), "new_finding_ids": sorted(current_ids - old_ids),
             "lens_coverage": envelope.get("lens_coverage", {}), "tests": args.tests,
             "workflow_run_id": args.workflow_run_id, "findings_truncated": False,
             "reviewed_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")}
    body = f"## Secondmate Review v{version} — {args.jira_key}\n\n**Status:** {status}  \n**Mode:** {args.mode}  \n**Reviewed SHA:** `{args.head_sha[:12]}` · **Base:** `{args.base_sha[:12]}`  \n**Prior review:** {prior_link}  \n**Tests:** {args.tests}  \n**Check:** {args.check_url}\n\n### Prior-finding resolution\n{resolution}\n\n### Findings in this review\n{listed}\n\n**Diagnostic:** {envelope.get('diagnostic', '') or 'None.'}\n\n<!-- secondmate-review-state:v1\n{json.dumps(state, separators=(',', ':'))}\n-->\n"
    pathlib.Path(args.out).write_text(body, encoding="utf-8")

def main(argv):
    p = argparse.ArgumentParser(); sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    for n in ("comments", "repository", "head_sha", "trusted_login", "out"): s.add_argument("--" + n.replace("_", "-"), required=True)
    s.add_argument("--pr", type=int, required=True)
    r = sub.add_parser("render")
    for n in ("repository", "head_sha", "base_sha", "jira_key", "mode", "report", "check_url", "out"): r.add_argument("--" + n.replace("_", "-"), required=True)
    r.add_argument("--pr", type=int, required=True); r.add_argument("--prior"); r.add_argument("--tests", default="not configured"); r.add_argument("--workflow-run-id", default="")
    args = p.parse_args(argv)
    try:
        if args.cmd == "select": select(args)
        else: render(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr); return 2
    return 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
