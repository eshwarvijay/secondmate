# Scope Guard for pi Maker Sessions

## Overview

The `bin/scope-guard-extension.ts` extension provides scope confinement for **pi maker sessions**, equivalent to the Claude Code PreToolUse hook behavior in `bin/scope-guard.py`. This ensures maker sessions are confined to their own git worktree, with no access to files or credentials outside that boundary.

## What It Does

The extension denies:

1. **Path-based tool calls (Read/Edit/Write/NotebookEdit)** that escape the worktree boundary
2. **Credential-store commands** (macOS Keychain via `security`, GitHub via `gh auth`) unless `SM_MAKER_ALLOW_CREDS=1` is explicitly set
3. **Common Bash evasion patterns**:
   - Shell variable expansion (`$VAR`, `${VAR}`)
   - Command substitution (`$(...)`, backticks)
   - Interpreter inline code (`python3 -c`, `node -e`, `ruby -e`)
   - Pipelines ending in a shell interpreter

## Activation

The extension activates **only when** the session's cwd is inside a git worktree marked by `bin/mark-maker.sh`. The marker lives **outside** the worktree tree entirely (keyed by a hash of the worktree's realpath), so this extension's own path-confinement prevents the marked session from writing/deleting it.

## How It Works

1. **Marker detection**: `is_maker_worktree()` uses `git rev-parse --show-toplevel` to find the worktree root, then checks for a marker file under `SM_MARKER_ROOT` (default: `~/.secondmate-markers`).

2. **Tool interception**: The `tool_call` event handler checks if the session is a marked maker worktree. If so, it runs `decide()` for each tool invocation.

3. **Decision logic**:
   - **Bash**: Scans the command string for credential commands, path references, pipeline into shell, interpreter inline code, and nested wrappers (sh -c, eval).
   - **Read/Edit/Write/NotebookEdit**: Resolves the path and checks if it's within the worktree.
   - If the check fails, returns `{ block: true, reason }` to deny the tool call.

## Commands

### `/scope-guard-status`

Check scope guard marker status for the current worktree. Shows:
- Current worktree path
- Whether it's a real git worktree (not the primary checkout)
- Whether scope guard is active
- Marker path location

### `/scope-guard-marker`

Print the marker file path for the current worktree.

## Fail-Open vs Fail-Closed

The design follows the same pattern as `scope-guard.py`:

- **Fail OPEN** (allow): Can't determine if this is a maker session (no marker, git unavailable, cwd gone)
- **Fail CLOSED** (deny): Given a CONFIRMED maker session, anything unresolvable or ambiguous is denied

## Limitations

By design (same as `scope-guard.py`):

1. **String-heuristic Bash checks**: Cannot enumerate every possible command encoding (Turing-complete-adjacent problem)
2. **TOCTOU**: Path check happens before actual file operation; nothing prevents symlink swap between check and execution
3. **Does NOT catch**:
   - Direct redirections (`cat</etc/passwd`)
   - Deferred execution (`find -exec cat /etc/passwd \;`)
   - Interpreter `exec()` calls (`os.system()` inside `python -c`)
   - Truly adversarial command encoding

**This is a best-effort deterrent, not a sandbox.** The same limitations apply to the Claude Code `scope-guard.py` PreToolUse hook.

## Usage

### In a Maker Session

1. **Mark the worktree** (done by `bin/new-worktree.sh`, `bin/herdr-pane.sh spawn`, or manually after `herdr worktree create`):
   ```bash
   bin/mark-maker.sh --cwd /path/to/worktree
   ```

2. **Start pi with the extension**:
   ```bash
   pi --extension /path/to/scope-guard-extension.ts
   ```

3. **Verify it's working**:
   ```bash
   /scope-guard-status
   ```

4. **Try out-of-scope access** (should be blocked):
   ```bash
   # Try to read a file outside the worktree
   read /etc/passwd
   ```

### In a Non-Maker Session

If the session is NOT in a marked worktree, the extension does nothing — all tool calls proceed normally. This ensures:
- Primary checkout: no interference
- Other worktrees without markers: no interference
- Regular pi usage: no interference

## Integration with Secondmate

When secondmate spawns a pi maker session:

1. `herdr-pane.sh spawn` (or equivalent) calls `mark-maker.sh` to create the marker
2. The pi maker is launched with `--extension bin/scope-guard-extension.ts`
3. The extension enforces worktree confinement for all tool calls
4. If a tool call attempts to escape, it's blocked with a warning and reason

## Comparison with Claude Code scope-guard.py

| Aspect | Claude Code (`scope-guard.py`) | pi (`scope-guard-extension.ts`) |
|--------|-------------------------------|--------------------------------|
| Hook mechanism | `hooks/hooks.json` PreToolUse | Extension `tool_call` event |
| Works for | Claude Code makers only | pi makers only |
| Marker convention | Same: `~/.secondmate-markers` keyed by `sha256(worktree_root)` | Same |
| Bash checks | Python shlex + regex | TypeScript simple split |
| Path checks | Python os.path | TypeScript path module |
| Credential blocking | Same patterns | Same patterns |
| Limitations | Same heuristic limitations | Same heuristic limitations |

**Important**: Neither mechanism provides the same level of enforcement. Both are best-effort deterrents, not security sandboxes. A deliberately adversarial user can always find an encoding that bypasses the checks.

## Selfcheck

Run the selfcheck script to verify the marker convention and extension loading:

```bash
bin/scope-guard-selfcheck.sh
```

This creates:
- A temporary git project
- A linked worktree
- A marker file via `mark-maker.sh`
- Verifies the marker is outside the worktree
- Tests the extension loads correctly

## Environment Variables

- `SM_MARKER_ROOT`: Override marker directory (default: `~/.secondmate-markers`)
- `SM_MAKER_ALLOW_CREDS`: Set to `1` to allow credential-store commands in maker sessions

## Files

- `bin/scope-guard-extension.ts`: The pi extension source
- `bin/scope-guard.py`: The Claude Code PreToolUse hook (same semantics)
- `bin/mark-maker.sh`: The marker creation script (shared by both)
- `bin/scope-guard-selfcheck.sh`: Selfcheck script

## See Also

- `bin/scope-guard.py`: Claude Code equivalent
- `bin/mark-maker.sh`: Shared marker mechanism
- `docs/ARCHITECTURE.md`: Secondmate architecture overview
