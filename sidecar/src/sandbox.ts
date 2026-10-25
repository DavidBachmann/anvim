// Claude Code's own Bash sandbox: Seatbelt (sandbox-exec) on macOS and
// bubblewrap on Linux. With it on, a Bash command can write only in the
// project, the sandbox's temp dir and a few caches, so an accidental rm
// outside the project fails. It does not stop a hostile agent, and it does not
// protect the project.
// As a script, `bun src/sandbox.ts` prints why the sandbox cannot start here,
// or nothing, for :checkhealth.
import type {
  HookCallback,
  HookCallbackMatcher,
  HookInput,
  HookJSONOutput,
  Options,
  PermissionMode,
  PermissionResult,
  PreToolUseHookInput,
} from "@anthropic-ai/claude-agent-sdk";
import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { CODEX_TOOL } from "./tools";

export type Host = {
  platform: NodeJS.Platform;
  which: (cmd: string) => string | null;
  exists: (path: string) => boolean;
  isDir: (path: string) => boolean;
  home: string;
};

const host: Host = {
  platform: process.platform,
  which: (cmd) => Bun.which(cmd),
  exists: existsSync,
  isDir: (path) => statSync(path, { throwIfNoEntry: false })?.isDirectory() ?? false,
  home: homedir(),
};

// The tools that Claude Code's sandbox needs, by the package that has them.
const LINUX_TOOLS: [string, string][] = [
  ["bwrap", "bubblewrap"],
  ["socat", "socat"],
];

// Why the sandbox cannot start here, or undefined when it can. Claude Code
// can also find reasons that this check misses, such as WSL 1. It then writes
// one to stderr (sandboxDisabled()).
export function sandboxProblem(h: Host = host): string | undefined {
  if (h.platform === "darwin") {
    return h.exists("/usr/bin/sandbox-exec") ? undefined : "/usr/bin/sandbox-exec is missing";
  }
  if (h.platform === "linux") {
    const missing = LINUX_TOOLS.filter(([cmd]) => !h.which(cmd));
    if (missing.length === 0) return undefined;
    const cmds = missing.map(([cmd]) => cmd).join(" and ");
    const pkgs = missing.map(([, pkg]) => pkg).join(" and ");
    return `${cmds} ${missing.length > 1 ? "are" : "is"} not on PATH (install ${pkgs})`;
  }
  // Claude Code has a sandbox for Windows behind a gate, which anvim does not try.
  return `anvim uses the sandbox only on macOS and Linux, not on ${h.platform}`;
}

// The reason in Claude Code's "⚠ Sandbox disabled: <reason>" line on stderr.
export function sandboxDisabled(stderr: string): string | undefined {
  return stderr.match(/Sandbox disabled: ([^\n]+)/)?.[1]?.trim();
}

// "bypass": the user chose bypass mode, so nothing asks before a command.
// "fallback": anvim runs in default mode in place of its own default, bypass.
export type WarningKind = "plain" | "bypass" | "fallback";

function sandboxWarning(problem: string, kind: WarningKind = "plain"): string {
  if (kind === "bypass") {
    return `Claude's Bash commands run without a sandbox, and in bypass mode without asking: ${problem}. Start anvim with --mode default to be asked, or --no-sandbox to hide this warning.`;
  }
  if (kind === "fallback") {
    return `Claude's Bash commands run without a sandbox: ${problem}. anvim runs in default mode, so Claude asks before it runs a tool. Start anvim with --mode bypassPermissions to skip the prompts.`;
  }
  return `Claude's Bash commands run without a sandbox: ${problem}. Start anvim with --no-sandbox to hide this warning.`;
}

export type StartMode = {
  mode: PermissionMode;
  // The user named the mode, with --mode, ANVIM_MODE or a spec of their own.
  chosen: boolean;
  // The mode is default, because anvim's own default needs the sandbox.
  fallback?: boolean;
};

// anvim's own default is bypass mode, where only the sandbox limits a Bash
// command. So without a sandbox, a session whose mode nobody chose starts in
// default mode. A mode that the user chose stays.
export function startMode(requested: PermissionMode | undefined, chosen: boolean, sandboxRuns: boolean): StartMode {
  const mode = requested ?? "bypassPermissions";
  if (chosen || sandboxRuns || mode !== "bypassPermissions") return { mode, chosen };
  return { mode: "default", chosen, fallback: true };
}

// Sends one warning per start, from the pre-check or from Claude Code's line.
// Claude Code's line comes after the start, so a session in anvim's own
// bypass mode then falls back to default mode (`onFallback`).
export class SandboxNotice {
  private sent = false;

  constructor(
    private send: (text: string) => void,
    private start: StartMode = { mode: "default", chosen: true },
    private onFallback: () => void = () => {},
  ) {}

  warn(problem: string | undefined): void {
    if (!problem || this.sent) return;
    this.sent = true;
    let kind: WarningKind = this.start.fallback ? "fallback" : "plain";
    if (this.start.mode === "bypassPermissions") {
      kind = this.start.chosen ? "bypass" : "fallback";
      if (!this.start.chosen) {
        this.start = { mode: "default", chosen: false, fallback: true };
        this.onFallback();
      }
    }
    this.send(sandboxWarning(problem, kind));
  }

  stderr(data: string): void {
    this.warn(sandboxDisabled(data));
  }
}

// The git root above cwd, when cwd is below one. git add in cwd writes the
// root's .git/index.lock, which the sandbox allows only in a writable dir.
// Claude Code keeps .git/config and .git/hooks read-only there too. A linked
// worktree or a submodule has a .git file, and its git dir is elsewhere, so
// it gets nothing. A repo in the home dir, as some dotfiles setups have,
// would open all of home.
export function gitRoot(cwd: string, h: Host = host): string | undefined {
  for (let dir = cwd; ; dir = dirname(dir)) {
    const git = join(dir, ".git");
    if (h.exists(git)) {
      const top = dir === cwd || dir === h.home || dirname(dir) === dir;
      return top || !h.isDir(git) ? undefined : dir;
    }
    if (dirname(dir) === dir) return undefined;
  }
}

// The caches that npm (npx too), bun install and go build write to. Without
// them, those commands fail in the sandbox, and Claude retries them outside
// it, which asks. Absolute paths need no ~ expansion in any settings layer,
// and the edit guard needs no home dir to resolve them.
export function cacheDirs(h: Host = host): string[] {
  const go = h.platform === "darwin" ? "Library/Caches/go-build" : ".cache/go-build";
  return [".npm", ".bun/install/cache", go].map((dir) => join(h.home, dir));
}

export type SandboxSetup = {
  options: Pick<Options, "sandbox">;
  // Why the sandbox cannot start here, from the pre-check.
  problem?: string;
};

export function sandboxSetup(on: boolean, cwd: string, h: Host = host): SandboxSetup {
  // Options.sandbox goes into the flag settings, which beat the settings
  // files. So off stays off, also when a project's settings turn it on.
  if (!on) return { options: { sandbox: { enabled: false } } };
  const root = gitRoot(cwd, h);
  const problem = sandboxProblem(h);
  return {
    options: {
      sandbox: {
        enabled: true,
        // Without the tools, Claude Code warns on stderr and runs commands
        // unsandboxed. True would end the session instead.
        failIfUnavailable: false,
        // True would run most sandboxed commands without a permission prompt.
        autoAllowBashIfSandboxed: false,
        // Only the sandbox's writes. In default mode, Claude Code's Edit and
        // Write still ask for a path outside the cwd. The settings files'
        // lists merge in.
        filesystem: { allowWrite: [...(root ? [root] : []), ...cacheDirs(h)] },
      },
    },
    problem,
  };
}

// The commands of a command line, split at ;, &, &&, ||, |, newlines,
// parentheses and backticks outside single quotes. A $( opens a command too.
export function commandParts(line: string): string[] {
  const parts: string[] = [];
  let part = "";
  let quote: string | undefined;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (quote === "'") {
      part += c;
      if (c === "'") quote = undefined;
    } else if (c === "\\" && i + 1 < line.length) {
      part += c + line[++i];
    } else if (c === "'" && !quote) {
      quote = c;
      part += c;
    } else if (c === '"') {
      quote = quote ? undefined : c;
      part += c;
    } else if (c === "&" && (line[i - 1] === ">" || line[i - 1] === "<" || line[i + 1] === ">")) {
      // A redirection such as 2>&1 or &>file.
      part += c;
    } else if (";&|\n()`".includes(c) && (!quote || "()`".includes(c))) {
      // A command inside double quotes, as in "$(touch x)", runs too.
      parts.push(part.replace(/\$$/, ""));
      part = "";
      if (line[i + 1] === c && c !== "(" && c !== ")") i++;
    } else {
      part += c;
    }
  }
  parts.push(part);
  return parts.map((p) => p.trim()).filter(Boolean);
}

// Words that run the rest of the line as a command, with the GNU names that
// macOS gives coreutils, and shell keywords that come before a command.
const WRAPPERS = new Set(
  ["env", "timeout", "time", "nice", "nohup", "stdbuf", "noglob", "command", "builtin", "exec", "sudo", "xargs"].flatMap(
    (w) => [w, "g" + w],
  ),
);
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"]);
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*\+?=/;

// A word as the shell reads it: without quotes and backslashes.
function unquote(word: string): string {
  return word.replace(/\\(.)/g, "$1").replace(/["']/g, "");
}

// A part's words, and the places where its command can start: the first word
// after VAR=value words and keywords, and after a wrapper every later word,
// because the wrapper's options can take values.
function commandWords(part: string): { words: string[]; starts: number[] } {
  const words = (part.match(/(?:"(?:\\.|[^"\\])*"?|'[^']*'?|\\.|[^\s"'\\])+/g) ?? [])
    .map(unquote)
    .map((w) => w.replace(/^\d*[<>]+&?\S*$/, ""))
    .filter(Boolean);
  const starts: number[] = [];
  for (let i = 0; i < words.length; i++) {
    const word = words[i]!;
    if (ASSIGNMENT.test(word) || KEYWORDS.has(word)) continue;
    starts.push(i);
    if (WRAPPERS.has(basename(word))) for (let j = i + 1; j < words.length; j++) starts.push(j);
    break;
  }
  return { words, starts };
}

// The words of an entry before its first `*`. Each command that the entry
// matches starts with them, since Claude Code matches a rule from the start
// of a command. The last word is only a prefix when the `*` is part of it.
type EntryWords = { words: string[]; partial: boolean };

// Undefined when the first word has a `*`: such an entry can match any command.
function entryWords(entry: string): EntryWords | undefined {
  const text = entry.trim().replace(/:\*$/, "");
  const star = text.search(/(?<!\\)\*/);
  const head = star < 0 ? text : text.slice(0, star);
  const words = head.split(/\s+/).filter(Boolean).map(unquote);
  const partial = star >= 0 && !/\s$/.test(head);
  if (words.length === 0 || (partial && words.length === 1)) return undefined;
  return { words, partial };
}

function startsWith(words: string[], at: number, entry: EntryWords): boolean {
  return entry.words.every((want, k) => {
    const word = words[at + k];
    if (word === undefined) return false;
    const prefix = entry.partial && k === entry.words.length - 1;
    // The command word may be a path, such as /usr/bin/touch.
    return (k === 0 ? [word, basename(word)] : [word]).some((w) => (prefix ? w.startsWith(want) : w === want));
  });
}

// Whether Claude Code could run a command outside the sandbox because of
// sandbox.excludedCommands. Claude Code runs a line outside it when each of
// its commands matches an entry, after it strips VAR=value words, wrappers
// such as timeout and quotes. Its parser has more forms than anvim can follow,
// so anvim asks for any line in which a command starts with an entry's words
// before its first `*`. That asks for some lines that Claude Code keeps in the
// sandbox.
export function excludedCommand(line: string, entries: string[]): boolean {
  const parsed = entries.filter((e) => typeof e === "string" && e.trim() !== "").map(entryWords);
  if (parsed.length === 0) return false;
  if (parsed.includes(undefined)) return true;
  return commandParts(line).some((part) => {
    const { words, starts } = commandWords(part);
    return starts.some((at) => parsed.some((entry) => startsWith(words, at, entry!)));
  });
}

// Claude Code's own list of files and dirs whose edits it asks about in
// default mode, because tools read them as config and run what they name
// (Claude Code 2.1.304). Bypass mode edits them without a prompt.
const PROTECTED_FILES = new Set(
  [
    ".gitconfig",
    ".gitmodules",
    ".bashrc",
    ".bash_profile",
    ".zshrc",
    ".zprofile",
    ".profile",
    ".zshenv",
    ".zlogin",
    ".zlogout",
    ".bash_login",
    ".bash_aliases",
    ".bash_logout",
    ".envrc",
    ".ripgreprc",
    ".mcp.json",
    ".claude.json",
    ".npmrc",
    ".yarnrc",
    ".yarnrc.yml",
    ".pnp.cjs",
    ".pnp.loader.mjs",
    ".pnpmfile.cjs",
    "bunfig.toml",
    ".bunfig.toml",
    ".bazelrc",
    ".bazelversion",
    ".bazeliskrc",
    ".pre-commit-config.yaml",
    "lefthook.yml",
    ".lefthook.yml",
    "lefthook.yaml",
    ".lefthook.yaml",
    "gradle-wrapper.properties",
    "maven-wrapper.properties",
    ".devcontainer.json",
    "pyrightconfig.json",
  ].map((f) => f.toLowerCase()),
);
const PROTECTED_DIRS = new Set([
  ".git",
  ".vscode",
  ".idea",
  ".claude",
  ".husky",
  ".cargo",
  ".devcontainer",
  ".yarn",
  ".mvn",
]);

// Whether a path below a trusted dir is in Claude Code's list: a dir of the
// list or .config/git on the way, or a file of the list at the end. As in
// Claude Code, the first .claude/worktrees, where its worktree agents work,
// and .claude/scheduled_tasks.json do not count. A later .claude does.
function protectedPath(path: string): boolean {
  const parts = path
    .split(sep)
    .filter(Boolean)
    .map((p) => p.toLowerCase());
  let worktree = false;
  return (
    parts.some((p, i) => {
      if (p === ".claude" && !worktree && parts[i + 1] === "worktrees") {
        worktree = true;
        return false;
      }
      if (p === ".claude" && parts[i + 1] === "scheduled_tasks.json" && i + 2 === parts.length) return false;
      return PROTECTED_DIRS.has(p) || (p === ".config" && parts[i + 1] === "git");
    }) || PROTECTED_FILES.has(parts.at(-1) ?? "")
  );
}

// A path as the system resolves it, with symlinks followed. A part that does
// not exist yet keeps its name, so a new file resolves through its nearest
// existing parent.
export function realPath(path: string): string {
  let dir: string = sep;
  for (const part of path.split(sep)) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      dir = dirname(dir);
      continue;
    }
    const next = join(dir, part);
    try {
      dir = realpathSync.native(next);
    } catch {
      dir = next;
    }
  }
  return dir;
}

function inside(path: string, dir: string): boolean {
  return path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep);
}

// A path under the home dir, written with ~.
export function tildePath(path: string, home = homedir()): string {
  return inside(path, home) ? "~" + path.slice(home.length) : path;
}

// What anvim's guards read from getSettings(): the effective settings.
export type GuardSettings = {
  effective?: {
    sandbox?: {
      allowUnsandboxedCommands?: boolean;
      excludedCommands?: string[];
      filesystem?: { allowWrite?: string[] };
    };
  };
};

// Asks the user as canUseTool does (permissions.ts).
export type GuardPrompt = (
  tool: string,
  input: Record<string, unknown>,
  opts: { signal: AbortSignal; toolUseID: string; agentID?: string; description?: string },
) => Promise<PermissionResult | null>;

export type GuardOptions = {
  cwd: string;
  settings: () => Promise<GuardSettings>;
  prompt?: GuardPrompt;
  home?: string;
  // CLAUDE_CONFIG_DIR, else ~/.claude.
  configDir?: string;
  // The sandbox's $TMPDIR, which Bash can write already. Claude Code puts it
  // in CLAUDE_CODE_TMPDIR, else /tmp, on every platform.
  tmpDir?: string;
  platform?: NodeJS.Platform;
};

export const REASONS = {
  escape: "runs outside the sandbox",
  excluded: "runs outside the sandbox (excluded command)",
  settings: "changes the sandbox's settings",
  config: "changes a config that runs outside the sandbox",
  outside: (path: string) => `outside the trusted dirs: ${path}`,
  codex: "writes outside the sandbox, also files that run code",
};

// anvim's guards for what the sandbox does not cover. Each one is a
// PreToolUse hook that asks, in every mode, bypass mode included. A Bash call
// with dangerouslyDisableSandbox, or one that sandbox.excludedCommands lets
// out, runs outside the sandbox. The edit tools run in Claude Code's own
// process, so the sandbox never sees their writes.
export class SandboxGuard {
  // The reason of each ask, by tool_use id, until canUseTool takes it.
  private asked = new Map<string, string>();
  private home: string;
  private configDir: string;
  readonly tmpDir: string;
  private platform: NodeJS.Platform;

  constructor(private opts: GuardOptions) {
    this.home = opts.home ?? homedir();
    this.configDir = opts.configDir ?? process.env.CLAUDE_CONFIG_DIR ?? join(this.home, ".claude");
    this.tmpDir = opts.tmpDir ?? join(process.env.CLAUDE_CODE_TMPDIR || "/tmp", `claude-${process.getuid?.() ?? 0}`);
    this.platform = opts.platform ?? process.platform;
  }

  // The reason of anvim's own ask for this tool call, once.
  take(toolUseID: string | undefined): string | undefined {
    if (!toolUseID) return undefined;
    const reason = this.asked.get(toolUseID);
    this.asked.delete(toolUseID);
    return reason;
  }

  // In bypass mode, Claude Code drops a hook's ask where its own safety check
  // would ask, such as for .claude/settings.json or a .zshrc, and runs the
  // tool. So in bypass mode the guard asks the user itself, and answers with
  // a deny or with nothing. In the other modes, Claude Code asks once. Both
  // go through canUseTool, which can send the call back (sendback.ts).
  private async ask(input: HookInput, toolUseID: string | undefined, signal: AbortSignal, reason: string) {
    const id = toolUseID ?? (input as PreToolUseHookInput).tool_use_id;
    if (id) {
      this.asked.set(id, reason);
      // A deny rule can answer before canUseTool takes the reason.
      if (this.asked.size > 100) this.asked.delete(this.asked.keys().next().value!);
    }
    const { permission_mode, tool_name, tool_input, agent_id } = input as PreToolUseHookInput;
    if (permission_mode !== "bypassPermissions" || !this.opts.prompt || !id) {
      return {
        hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: reason },
      } satisfies HookJSONOutput;
    }
    const { description } = (tool_input ?? {}) as Record<string, unknown>;
    const result = await this.opts.prompt(tool_name, (tool_input ?? {}) as Record<string, unknown>, {
      signal,
      toolUseID: id,
      agentID: agent_id,
      // As Claude Code describes a Bash command in canUseTool.
      description: tool_name === "Bash" && typeof description === "string" ? description : undefined,
    });
    if (result?.behavior === "allow") return {};
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: result?.message ?? reason,
      },
    } satisfies HookJSONOutput;
  }

  private async sandbox(): Promise<NonNullable<GuardSettings["effective"]>["sandbox"]> {
    try {
      return (await this.opts.settings()).effective?.sandbox;
    } catch {
      return undefined;
    }
  }

  bash: HookCallback = async (input, toolUseID, { signal }) => {
    const { tool_input } = input as PreToolUseHookInput;
    const { command, dangerouslyDisableSandbox } = (tool_input ?? {}) as Record<string, unknown>;
    // The settings change during a session, so each call reads them.
    const sandbox = await this.sandbox();
    // Claude Code's input schema takes the string too. Without the fallback,
    // Claude Code keeps such a call in the sandbox. Excluded commands still
    // run outside it then.
    const escape = dangerouslyDisableSandbox === true || dangerouslyDisableSandbox === "true";
    if (escape && sandbox?.allowUnsandboxedCommands !== false) return this.ask(input, toolUseID, signal, REASONS.escape);
    if (typeof command === "string" && excludedCommand(command, sandbox?.excludedCommands ?? [])) {
      return this.ask(input, toolUseID, signal, REASONS.excluded);
    }
    return {};
  };

  edit: HookCallback = async (input, toolUseID, { signal }) => {
    const { tool_input } = input as PreToolUseHookInput;
    const { file_path, notebook_path } = (tool_input ?? {}) as Record<string, unknown>;
    const given = typeof file_path === "string" ? file_path : notebook_path;
    if (typeof given !== "string" || given === "") return {};
    const path = this.absolute(given);
    // A path with .. after a symlink differs between the system's view and a
    // lexical one, and both must be trusted.
    const paths = [...new Set([realPath(path), realPath(resolve(path))])];
    const fold = (p: string) => (this.platform === "darwin" || this.platform === "win32" ? p.toLowerCase() : p);
    const settings = this.settingsFiles().map(fold);
    if (paths.some((p) => settings.includes(fold(p)))) return this.ask(input, toolUseID, signal, REASONS.settings);
    const trusted = await this.trusted();
    const outside = paths.find((p) => !trusted.some((dir) => inside(p, dir)));
    if (outside) return this.ask(input, toolUseID, signal, REASONS.outside(tildePath(outside, this.home)));
    // Each path is below a trusted dir. The part below the nearest one counts.
    const below = (p: string) => {
      const dir = trusted.filter((d) => inside(p, d)).reduce((a, b) => (b.length > a.length ? b : a));
      return p.slice(dir.length);
    };
    return paths.some((p) => protectedPath(below(p))) ? this.ask(input, toolUseID, signal, REASONS.config) : {};
  };

  // Codex's own sandbox lets it write files in the project that Claude's
  // edits ask for, such as .envrc. Plan mode runs it read-only (permissions.ts).
  codex: HookCallback = async (input, toolUseID, { signal }) => {
    const { tool_input, permission_mode } = input as PreToolUseHookInput;
    const { read_only } = (tool_input ?? {}) as Record<string, unknown>;
    if (read_only === true || permission_mode === "plan") return {};
    return this.ask(input, toolUseID, signal, REASONS.codex);
  };

  private absolute(path: string): string {
    if (path === "~" || path.startsWith("~/")) return join(this.home, path.slice(1));
    return isAbsolute(path) ? path : join(this.opts.cwd, path);
  }

  // The project's own settings files. An edit there can widen the sandbox, and
  // in bypass mode nothing else would ask.
  private settingsFiles(): string[] {
    const roots = [this.opts.cwd, gitRoot(this.opts.cwd, { ...host, home: this.home })];
    return roots.flatMap((root) =>
      root ? ["settings.json", "settings.local.json"].map((file) => realPath(join(root, ".claude", file))) : [],
    );
  }

  // The dirs that an edit may write without a prompt.
  private async trusted(): Promise<string[]> {
    const allowWrite = (await this.sandbox())?.filesystem?.allowWrite ?? [];
    const entries = allowWrite
      // Claude Code expands a glob anew for each command. anvim asks instead.
      .filter((entry) => typeof entry === "string" && entry !== "" && !/[*?[\]{}]/.test(entry))
      .map((entry) => (entry.startsWith("//") ? entry.slice(1) : entry));
    return [
      this.opts.cwd,
      ...entries,
      this.tmpDir,
      join(this.configDir, "projects"),
      join(this.configDir, "plans"),
      // Subagents keep their user-scope memory here.
      join(this.configDir, "agent-memory"),
    ].map((dir) => realPath(this.absolute(dir)));
  }
}

// The PreToolUse hooks: the preview handshake, and the guards while the
// sandbox is on. The edit guard runs after the preview hook in one callback,
// because Claude Code runs the hooks of a matcher in parallel. So its prompt
// opens once the preview has caught up.
export function preToolUse(preview: HookCallback, guard?: SandboxGuard): HookCallbackMatcher[] {
  if (!guard) return [{ matcher: "Edit|Write|NotebookEdit", hooks: [preview] }];
  const edit: HookCallback = async (input, toolUseID, opts) => {
    await preview(input, toolUseID, opts);
    return guard.edit(input, toolUseID, opts);
  };
  // A guard's own prompt in bypass mode waits for the user. When a hook misses
  // its timeout, in seconds, Claude Code does not run the tool, and Claude
  // reads that as an error.
  return [
    { matcher: "Edit|Write|NotebookEdit", hooks: [edit], timeout: GUARD_TIMEOUT_S },
    { matcher: "Bash", hooks: [guard.bash], timeout: GUARD_TIMEOUT_S },
    { matcher: CODEX_TOOL, hooks: [guard.codex], timeout: GUARD_TIMEOUT_S },
  ];
}

export const GUARD_TIMEOUT_S = 24 * 60 * 60;

if (import.meta.main) {
  const problem = sandboxProblem();
  if (problem) process.stdout.write(problem + "\n");
}
