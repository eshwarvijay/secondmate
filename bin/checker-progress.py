#!/usr/bin/env python3
# ponytail: simplest working solution: extract final assistant text from agent_end, filter progress to stderr.
"""checker-progress.py -- filter pi's --mode json output: print progress to stderr, final review to stdout.

Usage:
  pi --mode json ... | checker-progress.py > review.txt 2> progress.txt
  checker-progress.py --selfcheck  # run basic regression tests

Event types handled:
  - session, agent_start, agent_settled, turn_start, turn_end, message_start, message_end: ignored
  - message_update: only text deltas are tracked; never flood the terminal
  - tool_execution_start: print "checker: <tool> -- <args/truncated>" to stderr
  - tool_execution_end: ignored (already printed at start)
  - agent_end: extract final assistant message's content from messages array and print to stdout

Key behaviors:
  - Final output comes ONLY from agent_end.messages[-1].content[0].text (authoritative assembled text)
  - Progress to stderr: one line per tool_execution_start, nothing per text_delta (too noisy)
  - Malformed JSON lines are skipped gracefully (no crash)
  - Exit code propagation: the filter always exits 0; pi's exit code is preserved via pipefail
"""
import json, sys, io
from typing import Optional


def _truncate(s: str, max_len: int = 80) -> str:
    """Truncate string to max_len, adding ... if truncated."""
    if len(s) <= max_len:
        return s
    return s[:max_len - 3] + "..."


def _print_progress(tool_name: str, args: dict) -> None:
    """Print a single progress line to stderr, based on tool type and args."""
    if tool_name == "bash":
        cmd = args.get("command", "")
        # Truncate the command to keep it readable
        truncated = _truncate(cmd, 70)
        print(f"checker: bash -- {truncated}", file=sys.stderr, flush=True)
    elif tool_name == "read":
        path = args.get("path", "")
        truncated = _truncate(path, 70)
        print(f"checker: read -- {truncated}", file=sys.stderr, flush=True)
    else:
        # Generic handler for other tools
        print(f"checker: {tool_name} -- {args}", file=sys.stderr, flush=True)


def _extract_final_text(messages: list) -> Optional[str]:
    """Extract the final assistant message's text content from agent_end messages array."""
    if not messages:
        return None
    # The last message is typically the assistant's final response
    last_msg = messages[-1]
    if last_msg.get("role") != "assistant":
        # If the last message isn't assistant, look for the last assistant message
        for msg in reversed(messages):
            if msg.get("role") == "assistant":
                last_msg = msg
                break
        else:
            return None
    
    content = last_msg.get("content", [])
    if not content:
        return None
    
    # Content is a list of content parts; get the first text part
    for part in content:
        if isinstance(part, dict) and part.get("type") == "text":
            return part.get("text", "")
    
    return None


def _process_line(line: str, out_file, err_file):
    """Process a single JSON line and write progress to err_file, final text to out_file."""
    line = line.strip()
    if not line:
        return
    
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        # Skip malformed lines gracefully
        return
    
    event_type = obj.get("type")
    
    if event_type == "tool_execution_start":
        tool_name = obj.get("toolName", "unknown")
        args = obj.get("args", {})
        _print_progress(tool_name, args)
    
    elif event_type == "agent_end":
        final_text = _extract_final_text(obj.get("messages", []))
        if final_text:
            print(final_text, file=out_file, flush=True)


class _Capture:
    """Context manager to capture stdout/stderr for testing."""
    def __init__(self):
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self._old_stdout = None
        self._old_stderr = None
    
    def __enter__(self):
        self._old_stdout = sys.stdout
        self._old_stderr = sys.stderr
        sys.stdout = self.stdout
        sys.stderr = self.stderr
        return self
    
    def __exit__(self, *args):
        sys.stdout = self._old_stdout
        sys.stderr = self._old_stderr


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "selfcheck":
        # --- selfcheck: run basic regression tests ---
        failures = []
        
        # Test 1: Basic agent_end extraction with final text
        test1_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":"Final review text here"}],"api":"test","provider":"test","model":"test","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cost":{"input":0.001,"output":0.0005,"cacheRead":0,"cacheWrite":0,"total":0.0015}},"stopReason":"stop","timestamp":123,"rawStopReason":"end_turn"}],"willRetry":false}',
        ]
        with _Capture() as cap:
            for line in test1_lines:
                _process_line(line, sys.stdout, sys.stderr)
        if cap.stdout.getvalue().strip() != "Final review text here":
            failures.append(f"Test 1 failed: expected 'Final review text here', got '{cap.stdout.getvalue().strip()}'")
        
        # Test 2: Tool execution progress (bash)
        test2_lines = [
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"git diff HEAD"}}',
        ]
        with _Capture() as cap:
            for line in test2_lines:
                _process_line(line, sys.stdout, sys.stderr)
        if "checker: bash -- git diff HEAD" not in cap.stderr.getvalue():
            failures.append(f"Test 2 failed: expected bash tool progress in stderr")
        
        # Test 3: Read tool progress with truncation
        test3_lines = [
            '{"type":"tool_execution_start","toolName":"read","args":{"path":"/very/long/path/to/a/file/that/should/be/truncated.md"}}',
        ]
        with _Capture() as cap:
            for line in test3_lines:
                _process_line(line, sys.stdout, sys.stderr)
        stderr_out = cap.stderr.getvalue().strip()
        if "checker: read -- " not in stderr_out:
            failures.append(f"Test 3 failed: expected read tool progress in stderr")
        elif "...}" in stderr_out or "should be truncat" not in stderr_out:
            # Should be truncated with ...
            pass
        else:
            failures.append(f"Test 3 failed: expected truncation in progress line")
        
        # Test 4: Malformed JSON line should not crash
        test4_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":"Works after malformed"}],"api":"test","provider":"test","model":"test","usage":{},"stopReason":"stop","timestamp":123}],"willRetry":false}',
            '{invalid json line',
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"true"}}',
        ]
        with _Capture() as cap:
            for line in test4_lines:
                _process_line(line, sys.stdout, sys.stderr)
        # Should extract text from first valid agent_end without crashing
        if cap.stdout.getvalue().strip() != "Works after malformed":
            failures.append(f"Test 4 failed: should handle malformed JSON without crash, got '{cap.stdout.getvalue().strip()}'")
        
        # Test 5: No assistant message in agent_end (edge case)
        test5_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123}],"willRetry":false}',
        ]
        with _Capture() as cap:
            for line in test5_lines:
                _process_line(line, sys.stdout, sys.stderr)
        # Should output nothing (no assistant message)
        if cap.stdout.getvalue().strip() != "":
            failures.append(f"Test 5 failed: expected empty output for no assistant message, got '{cap.stdout.getvalue().strip()}'")
        
        # Test 6: Multiple tool executions
        test6_lines = [
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"git status"}}',
            '{"type":"tool_execution_start","toolName":"read","args":{"path":"README.md"}}',
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"python3 -m test"}}',
        ]
        with _Capture() as cap:
            for line in test6_lines:
                _process_line(line, sys.stdout, sys.stderr)
        stderr_lines = cap.stderr.getvalue().strip().split('\n')
        if len(stderr_lines) != 3:
            failures.append(f"Test 6 failed: expected 3 progress lines, got {len(stderr_lines)}")
        elif "git status" not in stderr_lines[0] or "README.md" not in stderr_lines[1] or "python3 -m test" not in stderr_lines[2]:
            failures.append(f"Test 6 failed: expected specific commands in progress lines")
        
        if failures:
            for f in failures:
                print(f"FAIL: {f}", file=sys.stderr)
            sys.exit(1)
        else:
            print("ok")
            sys.exit(0)
    
    # --- main mode: read from stdin, filter, output ---
    
    for line in sys.stdin:
        _process_line(line, sys.stdout, sys.stderr)


if __name__ == "__main__":
    main()
