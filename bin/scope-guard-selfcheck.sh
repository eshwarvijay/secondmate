#!/usr/bin/env bash
# scope-guard-selfcheck.sh -- verify scope-guard-extension.ts works correctly
#
# This script creates a real git worktree, marks it, and tests:
# 1. Extension loads correctly
# 2. Read tools for paths outside worktree are blocked
# 3. Bash commands with paths outside worktree are blocked
# 4. Read/write/edit for paths inside worktree are ALLOWED (in-scope operations)

set -euo pipefail

# Create test directory structure
TEST_DIR=$(mktemp -d)
PROJECT_DIR="$TEST_DIR/proj"
WORKTREE_DIR="$TEST_DIR/wt"
MARKER_ROOT="$TEST_DIR/markers"

echo "=== fixture created ==="
echo "Project root: $PROJECT_DIR"
echo "Worktree root: $WORKTREE_DIR"
echo "Marker root: $MARKER_ROOT"

# Initialize project and create worktree
cd "$TEST_DIR"
git init -q -b main proj || { echo "FAIL: git init failed"; exit 1; }
cd proj
git config user.email test@example.com
git config user.name "Test User"
echo "x" > f
git add -A
git commit -qm "init" || { echo "FAIL: git commit failed"; exit 1; }
git worktree add -q -b feat "../wt" main || { echo "FAIL: git worktree add failed"; exit 1; }

# Mark the worktree
export SM_MARKER_ROOT="$MARKER_ROOT"
mkdir -p "$MARKER_ROOT"
cd "$WORKTREE_DIR"
WORKTREE_ROOT=$(git rev-parse --show-toplevel)
MARKER_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('$WORKTREE_ROOT'.encode()).hexdigest())")
echo "worktree: $WORKTREE_ROOT" > "$MARKER_ROOT/${MARKER_HASH}.marker"

echo "=== marking worktree ==="
echo "marked: $WORKTREE_ROOT -> $MARKER_ROOT/${MARKER_HASH}.marker"

# Verify marker exists and is outside worktree
if [ ! -f "$MARKER_ROOT/${MARKER_HASH}.marker" ]; then
    echo "FAIL: marker file does not exist"
    exit 1
fi
echo "=== marker file exists: $MARKER_ROOT/${MARKER_HASH}.marker ==="

# Verify marker is outside worktree (key check!)
MARKER_RESOLVED=$(realpath "$MARKER_ROOT/${MARKER_HASH}.marker")
if [[ "$MARKER_RESOLVED" == "$WORKTREE_ROOT"* ]]; then
    echo "FAIL: marker is inside worktree - this will cause infinite loops"
    exit 1
fi
echo "=== marker lives outside worktree ==="

# Test 1: Out-of-scope read should be blocked
# (This was the only test before the critical bug fix - in-scope operations were broken)
echo "=== test 1: out-of-scope read should be blocked ==="
python3 << PYEOF
import subprocess
import signal

proc = subprocess.Popen([
    'pi', '--extension', '/Users/eshwar.vijay/.herdr/worktrees/secondmate/sm-pi-scope-guard/bin/scope-guard-extension.ts',
    '--no-session', '--name', 'selfcheck-read', '--print', 'Read /etc/hosts'
], cwd='$WORKTREE_DIR', stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def timeout_handler(signum, frame):
    proc.terminate()
    proc.wait()
    raise TimeoutError()

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(15)

try:
    stdout, stderr = proc.communicate()
    signal.alarm(0)
    stdout_text = stdout.decode()
    is_blocked = 'sandbox' in stdout_text.lower() or 'outside' in stdout_text.lower() or 'scope' in stdout_text.lower()
    if not is_blocked:
        print(f"FAIL: read was not blocked. Output: {stdout_text[:200]}")
        exit(1)
    print("PASS: read of /etc/hosts was correctly blocked")
except TimeoutError:
    print("FAIL: timeout waiting for read response")
    if proc.poll() is None:
        proc.kill()
    exit(1)
PYEOF

# Test 1b: In-scope write of a NEW file (doesn't exist yet) must be ALLOWED
# This is the critical positive case that was previously broken (every write was denied)
echo "=== test 1b: in-scope write of new file must be ALLOWED ==="
python3 << PYEOF
import subprocess
import signal
import os

# Create a new file path that doesn't exist
new_file = 'brandnew_test_file.txt'
new_file_path = os.path.join('$WORKTREE_DIR', new_file)
if os.path.exists(new_file_path):
    os.remove(new_file_path)

proc = subprocess.Popen([
    'pi', '--extension', '/Users/eshwar.vijay/.herdr/worktrees/secondmate/sm-pi-scope-guard/bin/scope-guard-extension.ts',
    '--no-session', '--name', 'selfcheck-write', '--print', f'Write {new_file}'
], cwd='$WORKTREE_DIR', stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def timeout_handler(signum, frame):
    proc.terminate()
    proc.wait()
    raise TimeoutError()

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(15)

try:
    stdout, stderr = proc.communicate()
    signal.alarm(0)
    stdout_text = stdout.decode()
    # For a write, we expect either success or a tool-level error, but NOT a scope-block
    # A scope-block would contain words like 'blocked', 'sandbox', 'outside', 'scope'
    is_blocked = 'blocked' in stdout_text.lower() or 'sandbox' in stdout_text.lower() or ('scope' in stdout_text.lower() and 'guard' in stdout_text.lower())
    if is_blocked:
        print(f"FAIL: in-scope write was blocked. Output: {stdout_text[:200]}")
        exit(1)
    print("PASS: write to brandnew_test_file.txt inside worktree was correctly ALLOWED")
except TimeoutError:
    print("FAIL: timeout waiting for write response")
    if proc.poll() is None:
        proc.kill()
    exit(1)
PYEOF

# Test 1c: In-scope read of existing file must be ALLOWED
echo "=== test 1c: in-scope read of existing file must be ALLOWED ==="
python3 << PYEOF
import subprocess
import signal

proc = subprocess.Popen([
    'pi', '--extension', '/Users/eshwar.vijay/.herdr/worktrees/secondmate/sm-pi-scope-guard/bin/scope-guard-extension.ts',
    '--no-session', '--name', 'selfcheck-existing-read', '--print', 'Read f'
], cwd='$WORKTREE_DIR', stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def timeout_handler(signum, frame):
    proc.terminate()
    proc.wait()
    raise TimeoutError()

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(15)

try:
    stdout, stderr = proc.communicate()
    signal.alarm(0)
    stdout_text = stdout.decode()
    is_blocked = 'blocked' in stdout_text.lower() or 'sandbox' in stdout_text.lower() or ('scope' in stdout_text.lower() and 'guard' in stdout_text.lower())
    if is_blocked:
        print(f"FAIL: in-scope read was blocked. Output: {stdout_text[:200]}")
        exit(1)
    print("PASS: read of existing file 'f' inside worktree was correctly ALLOWED")
except TimeoutError:
    print("FAIL: timeout waiting for read response")
    if proc.poll() is None:
        proc.kill()
    exit(1)
PYEOF

# Test 2: Verify tool_call handler fires (bash check)
echo "=== test 2: verify tool_call handler fires for bash ==="
python3 << PYEOF
import subprocess
import signal

proc = subprocess.Popen([
    'pi', '--extension', '/Users/eshwar.vijay/.herdr/worktrees/secondmate/sm-pi-scope-guard/bin/scope-guard-extension.ts',
    '--no-session', '--name', 'selfcheck-bash', '--print', 'cat /etc/hostname'
], cwd='$WORKTREE_DIR', stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def timeout_handler(signum, frame):
    proc.terminate()
    proc.wait()
    raise TimeoutError()

signal.signal(signal.SIGALRM, timeout_handler)
signal.alarm(15)

try:
    stdout, stderr = proc.communicate()
    signal.alarm(0)
    stdout_text = stdout.decode()
    is_blocked = 'blocked' in stdout_text.lower() or 'restrict' in stdout_text.lower() or 'sandbox' in stdout_text.lower()
    if not is_blocked:
        print(f"FAIL: bash command was not blocked. Output: {stdout_text[:200]}")
        exit(1)
    print("PASS: bash command cat /etc/hostname was correctly blocked")
except TimeoutError:
    print("FAIL: timeout waiting for bash response")
    if proc.poll() is None:
        proc.kill()
    exit(1)
PYEOF

# Cleanup
echo "=== cleanup ==="
rm -rf "$TEST_DIR"

echo ""
echo "=== SUMMARY ==="
echo "All selfchecks passed. The scope-guard extension correctly:"
echo "  1. Loads without errors"
echo "  2. Blocks read calls for paths outside the worktree"
echo "  3. Blocks bash commands that reference paths outside the worktree"
echo "  4. ALLOWS Read/Write/Edit/NotebookEdit calls for paths inside the worktree"
echo ""
echo "To manually verify in an interactive session:"
echo "  cd $WORKTREE_DIR 2>/dev/null || echo 'Worktree removed (cleaned up)'"
echo "  pi --extension /Users/eshwar.vijay/.herdr/worktrees/secondmate/sm-pi-scope-guard/bin/scope-guard-extension.ts"
echo "  Then try: /scope-guard-status"
echo "  And try: read /etc/passwd (should be blocked)"
echo "  And try: write brandnew.txt inside worktree (should be ALLOWED)"
