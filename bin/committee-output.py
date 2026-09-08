#!/usr/bin/env python3
"""Extract and classify a planner response from pi's JSON event stream."""
import argparse
import json
import re
import sys

# Keep this list extensible: each model family can expose a different tool dialect.
# Match only known structural shapes, while tolerating serializer whitespace around
# their delimiters.
BAD_PATTERNS = (
    re.compile(r"<\s*tool_call\s*>"),
    re.compile(r"<\s*\|\s*tool_calls_section_begin\s*\|\s*>"),
    re.compile(r"<\s*\|\s*tool_call_begin\s*\|\s*>"),
    re.compile(r"<\s*function\s*="),
)


def extract(messages):
    """Return (text, bad): follow checker-progress.py's multipart text handling."""
    if not isinstance(messages, list):
        return "", True
    assistant = next((m for m in reversed(messages) if isinstance(m, dict) and m.get("role") == "assistant"), None)
    if assistant is None:
        return "", True
    bad = assistant.get("stopReason", "") != "stop"
    parts = assistant.get("content", [])
    if not isinstance(parts, list):
        return "", True
    text_parts = []
    for part in parts:
        if not isinstance(part, dict):
            bad = True
        elif part.get("type") == "text":
            # Preserve empty and multipart text parts, as checker-progress.py does.
            text = part.get("text", "")
            if isinstance(text, str):
                text_parts.append(text)
            else:
                bad = True
        elif part.get("type") == "thinking":
            # Real Bedrock reasoning responses include a separate thinking part; it
            # is normal metadata, not a tool invocation and is not planner prose.
            pass
        else:
            bad = True
    text = "\n".join(text_parts)
    return text, bad or not text.strip() or any(pattern.search(text) for pattern in BAD_PATTERNS)


def classify(stream):
    result = ("", True)
    for line in stream:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "agent_end":
            result = extract(event.get("messages", []))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input")
    parser.add_argument("--output")
    parser.add_argument("--selfcheck", action="store_true")
    args = parser.parse_args()
    if args.selfcheck:
        return selfcheck()
    if not args.input or not args.output:
        parser.error("--input and --output are required unless --selfcheck is used")
    with open(args.input, encoding="utf-8", errors="replace") as stream:
        text, bad = classify(stream)
    with open(args.output, "w", encoding="utf-8") as output:
        output.write(text)
        if text:
            output.write("\n")
    return 1 if bad else 0


def _event(text, content_type="text", stop="stop"):
    return json.dumps({"type": "agent_end", "messages": [{"role": "assistant", "stopReason": stop, "content": [{"type": content_type, "text": text}]}]})


def selfcheck():
    # These are captured production failures, deliberately not invented approximations.
    kimi = " I'll map the integration surface for this bug fix in `bin/plan-committee.sh`. Let me examine the relevant files to identify all connections. <|tool_calls_section_begin|> <|tool_call_begin|> functions.Read:0 <|tool_call_argument_begin|> {\"file\": \"/Users/eshwar.vijay/secondmate/bin/plan-committee.sh\"} <|tool_call_end|> <|tool_calls_section_end|>"
    qwen = "I'll analyze the bug in `bin/plan-committee.sh` by walking through its concrete implementation steps. Let me first examine the file and related code.\n\n<tool_call>\n<function=read_file>\n<item path=\"/Users/eshwar.vijay/secondmate/bin/plan-committee.sh\">"
    clean = "### Implementation Steps\n1. Add a JSON-aware classifier and retry malformed planner output."
    failures = []
    for name, text, expected in (("kimi fixture", kimi, True), ("qwen fixture", qwen, True), ("clean fixture", clean, False)):
        _, got = classify([_event(text)])
        if got != expected:
            failures.append(f"{name}: expected bad={expected}, got {got}")
    _, structural = classify([_event("", content_type="toolCall")])
    if not structural:
        failures.append("non-text content part was not classified bad")
    _, stopped = classify([_event(clean, stop="length")])
    if not stopped:
        failures.append("non-stop stopReason was not classified bad")
    _, whitespace_tool_call = classify([_event("<tool_call > <function =read_file>")])
    if not whitespace_tool_call:
        failures.append("whitespace-variant tool call was not classified bad")
    _, inner_kimi_tool_call = classify([_event("preamble < | tool_call_begin | > functions.Read:0 more")])
    if not inner_kimi_tool_call:
        failures.append("inner Kimi tool-call token was not classified bad")
    _, angle_bracket_prose = classify([_event("the value is <100 and the function=foo() call succeeds")])
    if angle_bracket_prose:
        failures.append("ordinary angle-bracket prose was incorrectly classified bad")
    null_messages = json.dumps({"type": "agent_end", "messages": None})
    null_text, null_bad = classify([null_messages])
    if null_text != "" or not null_bad:
        failures.append("null messages was not classified as empty bad output")
    if failures:
        print("\n".join("FAIL: " + failure for failure in failures), file=sys.stderr)
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
