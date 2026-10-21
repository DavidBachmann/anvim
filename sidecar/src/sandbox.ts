// Claude Code's own Bash sandbox: Seatbelt (sandbox-exec) on macOS and
// bubblewrap on Linux. With it on, a Bash command can write only in the
// project and the sandbox's temp dir, so an accidental rm outside the project
// fails. It does not stop a hostile agent, and it does not protect the project.
// As a script, `bun src/sandbox.ts` prints why the sandbox cannot start here,
// or nothing, for :checkhealth.
import type { Options } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

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

export function sandboxWarning(problem: string): string {
  return `Claude's Bash commands run without a sandbox: ${problem}. Start anvim with --no-sandbox to hide this warning.`;
}

// Sends one warning per start, from the pre-check or from Claude Code's line.
export class SandboxNotice {
  private sent = false;

  constructor(private send: (text: string) => void) {}

  warn(text: string | undefined): void {
    if (!text || this.sent) return;
    this.sent = true;
    this.send(text);
  }

  stderr(data: string): void {
    const reason = sandboxDisabled(data);
    if (reason) this.warn(sandboxWarning(reason));
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

export type SandboxSetup = {
  options: Pick<Options, "sandbox">;
  // A warning for the user when the sandbox cannot start.
  warning?: string;
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
        // Only the sandbox's writes. Claude Code's Edit and Write still ask
        // for a path outside the cwd. The settings files' lists merge in.
        ...(root && { filesystem: { allowWrite: [root] } }),
      },
    },
    warning: problem ? sandboxWarning(problem) : undefined,
  };
}

if (import.meta.main) {
  const problem = sandboxProblem();
  if (problem) process.stdout.write(problem + "\n");
}
