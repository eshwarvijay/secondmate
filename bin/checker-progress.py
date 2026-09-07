#!/usr/bin/env python3
# ponytail: simplest working solution: extract final assistant text from agent_end, filter progress to stderr.
"""checker-progress.py -- filter pi's --mode json output: print progress to stderr, final review to stdout.

Usage:
  pi --mode json ... | checker-progress.py > review.txt 2> progress.txt
  checker-progress.py --selfcheck  # run basic regression tests

Event types handled:
  - session, agent_start, agent_settled, turn_start, turn_end, message_start, message_end: ignored
  - message_update: text_start prints "checker: writing analysis..." once (not per delta)
  - tool_execution_start: print "checker: <tool> -- <args/truncated>" to stderr
  - tool_execution_end: ignored (already printed at start)
  - agent_end: extract final assistant message's content from messages array and print to stdout

Key behaviors:
  - Final output comes ONLY from agent_end.messages[-1].content[0].text (authoritative assembled text)
  - Progress to stderr: one line per tool_execution_start, one "writing analysis..." on text_start
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


def _print_progress(tool_name: str, args: dict, err_file) -> None:
    """Print a single progress line to err_file, based on tool type and args."""
    if tool_name == "bash":
        cmd = args.get("command", "")
        # Truncate the command to keep it readable
        truncated = _truncate(cmd, 70)
        print(f"checker: bash -- {truncated}", file=err_file, flush=True)
    elif tool_name == "read":
        path = args.get("path", "")
        truncated = _truncate(path, 70)
        print(f"checker: read -- {truncated}", file=err_file, flush=True)
    else:
        # Generic handler for other tools
        print(f"checker: {tool_name} -- {args}", file=err_file, flush=True)


def _extract_final_text(messages: list) -> Optional[str]:
    """Extract the final assistant message's text content from agent_end messages array.
    
    Returns None if:
    - No assistant message found
    - The assistant message has stopReason 'error' or 'aborted'
    - No text content found
    
    Collects ALL text-type content parts in order and joins with newlines.
    """
    if not messages:
        return None
    
    # Find the last assistant message
    last_msg = None
    for msg in reversed(messages):
        if msg.get("role") == "assistant":
            last_msg = msg
            break
    
    if last_msg is None:
        return None
    
    # Check stopReason: error or aborted = suppress output (real pi text mode behavior)
    stop_reason = last_msg.get("stopReason", "")
    if stop_reason in ("error", "aborted"):
        return None
    
    content = last_msg.get("content", [])
    if not content:
        return None
    
    # Collect ALL text-type parts in order
    text_parts = []
    for part in content:
        if isinstance(part, dict) and part.get("type") == "text":
            text = part.get("text", "")
            if text:
                text_parts.append(text)
    
    if not text_parts:
        return None
    
    return "\n".join(text_parts)


def _process_line(line: str, out_file, err_file, text_start_printed: list):
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
        _print_progress(tool_name, args, err_file)
    
    elif event_type == "message_update":
        # Check for text_start event type within message_update
        # pi sends: message_update -> assistantMessageEvent -> {type: 'text_start', ...}
        assistant_message_event = obj.get("assistantMessageEvent", {})
        if isinstance(assistant_message_event, dict) and assistant_message_event.get("type") == "text_start":
            # Print the marker only once (first time)
            if not text_start_printed[0]:
                print("checker: writing analysis...", file=err_file, flush=True)
                text_start_printed[0] = True
    
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
            text_start = [False]
            for line in test1_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if cap.stdout.getvalue().strip() != "Final review text here":
            failures.append(f"Test 1 failed: expected 'Final review text here', got '{cap.stdout.getvalue().strip()}'")
        
        # Test 2: Tool execution progress (bash)
        test2_lines = [
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"git diff HEAD"}}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test2_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if "checker: bash -- git diff HEAD" not in cap.stderr.getvalue():
            failures.append(f"Test 2 failed: expected bash tool progress in stderr")
        
        # Test 3: Read tool progress with truncation
        test3_lines = [
            '{"type":"tool_execution_start","toolName":"read","args":{"path":"/very/long/path/to/a/file/that/exceeds/the/truncation/limit/significantly/extra/long.md"}}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test3_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        stderr_out = cap.stderr.getvalue().strip()
        # Assert (a) full untruncated path is NOT present in output
        if "/very/long/path/to/a/file/that/exceeds/the/truncation/limit.md" in stderr_out:
            failures.append(f"Test 3 failed: expected full path to be truncated, but it's present in output")
        # Assert (b) output ends with the '...' truncation marker
        elif not stderr_out.endswith("..."):
            failures.append(f"Test 3 failed: expected truncation marker '...' at end of output")
        
        # Test 4: Malformed JSON line should not crash
        test4_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":"Works after malformed"}],"api":"test","provider":"test","model":"test","usage":{},"stopReason":"stop","timestamp":123}],"willRetry":false}',
            '{invalid json line',
            '{"type":"tool_execution_start","toolName":"bash","args":{"command":"true"}}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test4_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        # Should extract text from first valid agent_end without crashing
        if cap.stdout.getvalue().strip() != "Works after malformed":
            failures.append(f"Test 4 failed: should handle malformed JSON without crash, got '{cap.stdout.getvalue().strip()}'")
        
        # Test 5: No assistant message in agent_end (edge case)
        test5_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123}],"willRetry":false}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test5_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
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
            text_start = [False]
            for line in test6_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        stderr_lines = cap.stderr.getvalue().strip().split('\n')
        if len(stderr_lines) != 3:
            failures.append(f"Test 6 failed: expected 3 progress lines, got {len(stderr_lines)}")
        elif "git status" not in stderr_lines[0] or "README.md" not in stderr_lines[1] or "python3 -m test" not in stderr_lines[2]:
            failures.append(f"Test 6 failed: expected specific commands in progress lines")
        
        # Test 7: text_start message_update event
        test7_lines = [
            '{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test7_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if "checker: writing analysis..." not in cap.stderr.getvalue():
            failures.append(f"Test 7 failed: expected text_start marker in stderr")
        # Verify second text_start doesn't print again (dedup)
        test7b_lines = [
            '{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":1}}',
        ]
        with _Capture() as cap:
            text_start = [True]  # Already printed
            for line in test7b_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if "checker: writing analysis..." in cap.stderr.getvalue():
            failures.append(f"Test 7b failed: expected dedup, marker printed twice")
        
        # Test 8: stopReason 'error' or 'aborted' must produce empty stdout
        test8_error_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":" partial text"}],"api":"test","provider":"test","model":"test","usage":{},"stopReason":"error","timestamp":123}],"willRetry":false}',
        ]
        test8_aborted_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"test"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":"some text"}],"api":"test","provider":"test","model":"test","usage":{},"stopReason":"aborted","timestamp":123}],"willRetry":false}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test8_error_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if cap.stdout.getvalue().strip() != "":
            failures.append(f"Test 8a failed: stopReason='error' should produce empty stdout, got '{cap.stdout.getvalue().strip()}'")
        with _Capture() as cap:
            text_start = [False]
            for line in test8_aborted_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        if cap.stdout.getvalue().strip() != "":
            failures.append(f"Test 8b failed: stopReason='aborted' should produce empty stdout, got '{cap.stdout.getvalue().strip()}'")
        
        # Test 9: Multi-part text content - ALL text parts must be concatenated
        test9_lines = [
            '{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"user query"}],"timestamp":123},{"role":"assistant","content":[{"type":"text","text":"first part"},{"type":"text","text":"second part"},{"type":"text","text":"third part"}],"api":"test","provider":"test","model":"test","usage":{},"stopReason":"stop","timestamp":123}],"willRetry":false}',
        ]
        with _Capture() as cap:
            text_start = [False]
            for line in test9_lines:
                _process_line(line, sys.stdout, sys.stderr, text_start)
        expected = "first part\nsecond part\nthird part"
        if cap.stdout.getvalue().strip() != expected:
            failures.append(f"Test 9 failed: expected '{expected}', got '{cap.stdout.getvalue().strip()}'")
        
        # Test 10: _print_progress must use the err_file parameter (direct call test)
        # This directly tests the API contract violation fix
        from io import StringIO
        custom_err = StringIO()
        args = {"command": "echo hello"}
        _print_progress("bash", args, custom_err)
        if custom_err.getvalue().strip() != "checker: bash -- echo hello":
            failures.append(f"Test 10 failed: _print_progress must use err_file param, got '{custom_err.getvalue().strip()}'")
        if sys.stderr is not None and hasattr(sys.stderr, 'getvalue'):
            # Verify the print didn't go to global sys.stderr (if it was patched)
            if "checker: bash" in sys.stderr.getvalue():
                failures.append(f"Test 10 failed: progress printed to global sys.stderr instead of err_file param")
        
        if failures:
            for f in failures:
                print(f"FAIL: {f}", file=sys.stderr)
            sys.exit(1)
        else:
            print("ok")
            sys.exit(0)
    
    # --- main mode: read from stdin, filter, output ---
    
    # Track if text_start marker has been printed (list to allow mutation in nested function)
    text_start_printed = [False]
    
    for line in sys.stdin:
        _process_line(line, sys.stdout, sys.stderr, text_start_printed)


if __name__ == "__main__":
    main()
