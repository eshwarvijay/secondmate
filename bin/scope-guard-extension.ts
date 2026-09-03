/**
 * scope-guard-extension.ts -- pi extension for confining maker sessions to their own git worktree
 *
 * This extension provides scope confinement for pi maker sessions, equivalent to the Claude Code
 * PreToolUse hook behavior in bin/scope-guard.py. It denies:
 *   - Bash/Read/Edit/Write calls that escape the worktree boundary
 *   - Credential-store commands (macOS Keychain via `security`, `gh auth`) unless SM_MAKER_ALLOW_CREDS=1
 *   - Common Bash evasion patterns (var expansion, command substitution, interpreter inline code, pipelines into shells)
 *
 * ACTIVATION: only when the session's cwd is inside a git worktree marked by mark-maker.sh.
 * The marker lives OUTSIDE the worktree tree entirely (keyed by a hash of the worktree's realpath),
 * so this extension's own path-confinement prevents the marked session from writing/deleting it.
 *
 * FAIL-OPEN vs FAIL-CLOSED:
 *   - Can we tell if this is a maker session (no marker, git unavailable, cwd gone)? -> Fail OPEN (allow)
 *   - Given a CONFIRMED maker session, is a specific path/command in or out of scope? -> Fail CLOSED (deny)
 *
 * LIMITATIONS (by design, same as scope-guard.py):
 *   - String-heuristic Bash checks cannot enumerate every possible command encoding (Turing-complete-adjacent)
 *   - TOCTOU: path check happens before actual file operation, nothing prevents symlink swap
 *   - Does NOT catch: direct redirections (`cat</etc/passwd`), deferred execution (`find -exec` with path),
 *     interpreter exec() calls (`os.system()` inside python -c), or truly adversarial command encoding
 *
 * DOCUMENTATION: This is a best-effort deterrent, not a sandbox. See bin/scope-guard.py for full details.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const _SHELL_INTERPRETERS = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh"];
const _INTERPRETER_CODE_FLAG: Record<string, string> = {
  python: "-c", python3: "-c", python2: "-c",
  node: "-e", nodejs: "-e",
  ruby: "-e",
  perl: "-e",
  php: "-r",
};
const _SHELL_C_WRAPPERS = ["sh", "bash", "zsh", "env"];
const _MAX_NESTED_DEPTH = 4;
const _EMBEDDED_PATH_RE = /~?\/[^\s'"()]+|~[^\s'"()]*/g;

function _marker_root(): string {
  return process.env.SM_MARKER_ROOT || `${process.env.HOME || process.env.USERPROFILE}/.secondmate-markers`;
}

function _marker_path_for(root: string): string {
  const crypto = require("crypto");
  const key = crypto.createHash("sha256").update(root).digest("hex");
  return `${_marker_root()}/${key}.marker`;
}

function _is_path_candidate(tok: string): boolean {
  if (tok.startsWith("/") || tok.startsWith("~") || tok.includes("$HOME")) return true;
  if (tok.includes("$")) return true;
  if (tok.includes("$(") || tok.includes("`")) return true;
  return tok.split("/").includes("..");
}

function _has_unresolvable_ref(tok: string): boolean {
  if (tok.includes("$(") || tok.includes("`")) return true;
  const matches = tok.match(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g);
  if (matches) {
    for (const m of matches) {
      if (m.replace(/\$\{?|\}?/g, "") !== "HOME") return true;
    }
  }
  return false;
}

function _resolve_token(tok: string, cwd: string): string {
  let t = tok;
  if (t.startsWith("~")) {
    t = require("os").homedir() + t.slice(1);
  }
  if (t.includes("$HOME")) {
    t = t.replace("$HOME", process.env.HOME || process.env.USERPROFILE || require("os").homedir());
  }
  if (!t.startsWith("/")) {
    t = `${cwd}/${t}`;
  }
  return require("path").resolve(t);
}

function _within_root(path: string, root: string): boolean {
  return path === root || path.startsWith(root + require("path").sep);
}

function _is_path_violation(pathValue: string | undefined, cwd: string, root: string): { valid: boolean; reason: string } {
  if (!pathValue) return { valid: false, reason: "missing path" };
  const p = require("path").resolve(require("os").homedir(), pathValue as string);
  const resolved = require("path").resolve(p);
  if (_within_root(resolved, root)) return { valid: true, reason: "" };
  return { valid: false, reason: `'${pathValue}' resolves to ${resolved}, outside the maker's worktree (${root})` };
}

function _credential_command(tokens: string[]): string | null {
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i] === "security") return "'security' reads the macOS Keychain";
    if (tokens[i] === "gh" && i + 1 < tokens.length && tokens[i + 1] === "auth") return "'gh auth' reads stored GitHub credentials";
  }
  return null;
}

function _embedded_code_violation(code: string | undefined, cwd: string, root: string): string | null {
  if (!code) return null;
  let match;
  while ((match = _EMBEDDED_PATH_RE.exec(code)) !== null) {
    const tok = match[0];
    if (_has_unresolvable_ref(tok)) {
      return `ambiguous path-like token '${tok}' embedded in interpreter code (unresolved shell variable/substitution)`;
    }
    const resolved = _resolve_token(tok, cwd);
    if (!_within_root(resolved, root)) {
      return `embedded interpreter code references '${tok}' -> resolves to ${resolved}, outside the maker's worktree (${root})`;
    }
  }
  return null;
}

function _interpreter_inline_code_violation(tokens: string[], cwd: string, root: string): string | null {
  for (let i = 0; i < tokens.length; i++) {
    const flag = _INTERPRETER_CODE_FLAG[require("path").basename(tokens[i])];
    if (!flag) continue;
    for (let j = i + 1; j < tokens.length; j++) {
      if (tokens[j] === flag && j + 1 < tokens.length) {
        const reason = _embedded_code_violation(tokens[j + 1], cwd, root);
        if (reason) return reason;
        break;
      }
    }
  }
  return null;
}

function _pipeline_into_shell(tokens: string[]): string | null {
  const segments: string[][] = [];
  let current: string[] = [];
  for (const tok of tokens) {
    if (tok === "|") {
      segments.push(current);
      current = [];
    } else {
      current.push(tok);
    }
  }
  segments.push(current);
  if (segments.length < 2) return null;
  const last = segments[segments.length - 1];
  if (last && _SHELL_INTERPRETERS.includes(require("path").basename(last[0]))) {
    return `pipeline's final stage is a shell interpreter ('${require("path").basename(last[0])}') -- denied by default (what a piped-in script will do can't be verified without executing it)`;
  }
  return null;
}

function _nested_command_violation(tokens: string[], cwd: string, root: string, depth: number): string | null {
  if (depth >= _MAX_NESTED_DEPTH) return null;
  for (let i = 0; i < tokens.length; i++) {
    const name = require("path").basename(tokens[i]);
    let nested_code: string | undefined, label: string | undefined;
    if (_SHELL_C_WRAPPERS.includes(name)) {
      for (let j = i + 1; j < tokens.length; j++) {
        if (tokens[j] === "-c" && j + 1 < tokens.length) {
          nested_code = tokens[j + 1];
          label = `${name} -c`;
          break;
        }
      }
    } else if (name === "eval" && i + 1 < tokens.length) {
      nested_code = tokens.slice(i + 1).join(" ");
      label = "eval";
    }
    if (nested_code === undefined) continue;
    const { allowed, reason } = check_bash(nested_code, cwd, root, depth + 1);
    if (!allowed) return `${reason} (nested in ${label})`;
  }
  return null;
}

function check_bash(command: string | undefined, cwd: string, root: string, _depth = 0): { allowed: boolean; reason: string } {
  let tokens: string[];
  try {
    // Simple whitespace split for shell command tokens
    const parts = (command || "").trim();
    if (!parts) {
      tokens = [];
    } else {
      // Basic shell tokenization - split on whitespace, preserving quoted strings
      tokens = [];
      let current = "";
      let inQuote = false;
      let quoteChar = "";
      
      for (let i = 0; i < parts.length; i++) {
        const char = parts[i];
        if ((char === '"' || char === "'") && !inQuote) {
          inQuote = true;
          quoteChar = char;
        } else if (char === quoteChar && inQuote) {
          inQuote = false;
          quoteChar = "";
        } else if (char === " " && !inQuote) {
          if (current.length > 0) {
            tokens.push(current);
            current = "";
          }
        } else {
          current += char;
        }
      }
      if (current.length > 0) {
        tokens.push(current);
      }
    }
  } catch {
    return { allowed: false, reason: "unparseable shell syntax -- ambiguous, denying" };
  }

  if (process.env.SM_MAKER_ALLOW_CREDS !== "1") {
    const cred = _credential_command(tokens);
    if (cred) return { allowed: false, reason: `blocked: ${cred} (set SM_MAKER_ALLOW_CREDS=1 to allow)` };
  }

  const pipeline_reason = _pipeline_into_shell(tokens);
  if (pipeline_reason) return { allowed: false, reason: pipeline_reason };

  const interp_reason = _interpreter_inline_code_violation(tokens, cwd, root);
  if (interp_reason) return { allowed: false, reason: interp_reason };

  for (const tok of tokens) {
    if (!_is_path_candidate(tok)) continue;
    if (_has_unresolvable_ref(tok)) {
      return { allowed: false, reason: `ambiguous path token '${tok}' (unresolved shell variable/substitution)` };
    }
    const resolved = _resolve_token(tok, cwd);
    if (!_within_root(resolved, root)) {
      return { allowed: false, reason: `'${tok}' resolves to ${resolved}, outside the maker's worktree (${root})` };
    }
  }

  const nested_reason = _nested_command_violation(tokens, cwd, root, _depth);
  if (nested_reason) return { allowed: false, reason: nested_reason };

  return { allowed: true, reason: "" };
}

function decide(
  toolName: string,
  toolInput: Record<string, unknown>,
  cwd: string,
  root: string,
): { allowed: boolean; reason: string } {
  // Use lowercase tool names (what pi actually emits)
  if (toolName === "bash") {
    const command = (toolInput["command"] as string | undefined) ?? "";
    return check_bash(command, cwd, root);
  }

  // Use 'path' (not 'file_path' or 'notebook_path') - what pi's built-in tools actually use
  if (toolName === "read" || toolName === "write" || toolName === "edit" || toolName === "notebookedit") {
    const pathValue = (toolInput["path"] as string | undefined);
    return _is_path_violation(pathValue, cwd, root);
  }

  // Tool outside this extension's scope
  return { allowed: true, reason: "" };
}

function is_maker_worktree(cwd: string): string | null {
  try {
    const { execSync } = require("child_process");
    const top = execSync(`git -C "${cwd}" rev-parse --show-toplevel`, {
      encoding: "utf-8",
      timeout: 3000,
    }).trim();
    if (!top) return null;
    const root = require("path").resolve(top);

    const marker_path = _marker_path_for(root);
    if (!require("fs").existsSync(marker_path)) return null;

    // Defensive: marker must be outside worktree
    if (_within_root(require("path").resolve(marker_path), root)) return null;

    return root;
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    // Only enforce in maker sessions (marked worktrees)
    const root = is_maker_worktree(ctx.cwd);
    if (!root) return undefined;

    // Only act on specific tools (lowercase - what pi actually emits)
    if (!["bash", "read", "write", "edit", "notebookedit"].includes(event.toolName.toLowerCase())) return undefined;

    const cwd = ctx.cwd;
    const { allowed, reason } = decide(event.toolName, event.input, cwd, root);

    if (!allowed) {
      if (ctx.hasUI) {
        ctx.ui.notify(`Scope guard: ${reason}`, "warning");
      }
      return { block: true, reason };
    }

    return undefined;
  });

  // Register a helper command to check marker status
  pi.registerCommand("scope-guard-status", {
    description: "Check scope guard marker status for current worktree",
    handler: async (_args, ctx) => {
      const root = is_maker_worktree(ctx.cwd);
      const isMarkerSet = root !== null;
      
      let msg = `Current worktree: ${ctx.cwd}\n`;
      msg += `Scope guard: ${isMarkerSet ? "ACTIVE" : "INACTIVE (worktree not marked)"}\n`;
      
      if (root) {
        msg += `Marker path: ${_marker_path_for(root)}\n`;
      }
      
      ctx.ui.notify(msg, "info");
    },
  });
}
