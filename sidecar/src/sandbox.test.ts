import { afterAll, describe, expect, test } from "bun:test";
import type { HookCallback, HookInput } from "@anthropic-ai/claude-agent-sdk";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cacheDirs,
  commandParts,
  excludedCommand,
  GUARD_TIMEOUT_S,
  gitRoot,
  type GuardSettings,
  type Host,
  preToolUse,
  REASONS,
  realPath,
  SandboxGuard,
  SandboxNotice,
  sandboxDisabled,
  sandboxProblem,
  sandboxSetup,
  startMode,
} from "./sandbox";
import { SendBack } from "./sendback";
import { CODEX_TOOL } from "./tools";

// A host with these dirs and files, and these commands on PATH.
function host(platform: NodeJS.Platform, dirs: string[] = [], cmds: string[] = [], files: string[] = []): Host {
  return {
    platform,
    which: (cmd) => (cmds.includes(cmd) ? `/usr/bin/${cmd}` : null),
    exists: (path) => dirs.includes(path) || files.includes(path),
    isDir: (path) => dirs.includes(path),
    home: "/home/u",
  };
}

const mac = host("darwin", [], [], ["/usr/bin/sandbox-exec"]);
const on = { enabled: true, failIfUnavailable: false, autoAllowBashIfSandboxed: false };
const macCaches = ["/home/u/.npm", "/home/u/.bun/install/cache", "/home/u/Library/Caches/go-build"];

describe("the sandbox", () => {
  test("is on with prompts for Bash, and goes on unsandboxed where it cannot start", () => {
    expect(sandboxSetup(true, "/p", mac)).toEqual({
      options: { sandbox: { ...on, filesystem: { allowWrite: macCaches } } },
      problem: undefined,
    });
  });

  test("lets npm, bun install and go build write their caches", () => {
    expect(cacheDirs(mac)).toEqual(macCaches);
    const linux = host("linux", [], ["bwrap", "socat"]);
    expect(cacheDirs(linux)).toEqual(["/home/u/.npm", "/home/u/.bun/install/cache", "/home/u/.cache/go-build"]);
    expect(sandboxSetup(true, "/p", linux).options.sandbox).toEqual({
      ...on,
      filesystem: { allowWrite: cacheDirs(linux) },
    });
  });

  test("off is enabled false, so that no settings file turns it on", () => {
    expect(sandboxSetup(false, "/p", host("linux"))).toEqual({ options: { sandbox: { enabled: false } } });
  });

  test("the pre-check names the tools that are missing, and --no-sandbox", () => {
    expect(sandboxProblem(mac)).toBeUndefined();
    expect(sandboxProblem(host("darwin"))).toBe("/usr/bin/sandbox-exec is missing");
    expect(sandboxProblem(host("linux", [], ["bwrap", "socat"]))).toBeUndefined();
    expect(sandboxProblem(host("linux", [], ["socat"]))).toBe("bwrap is not on PATH (install bubblewrap)");
    expect(sandboxProblem(host("linux"))).toBe("bwrap and socat are not on PATH (install bubblewrap and socat)");
    expect(sandboxProblem(host("win32"))).toBe("anvim uses the sandbox only on macOS and Linux, not on win32");
    expect(sandboxSetup(true, "/p", host("linux", [], ["bwrap"])).problem).toBe(
      "socat is not on PATH (install socat)",
    );
  });

  test("starts anvim's own bypass mode only with a sandbox, and keeps a mode that the user chose", () => {
    const bypass = "bypassPermissions";
    // The shipped default, with the sandbox on, off, or unable to start.
    expect(startMode(bypass, false, true)).toEqual({ mode: bypass, chosen: false });
    expect(startMode(bypass, false, false)).toEqual({ mode: "default", chosen: false, fallback: true });
    expect(startMode(undefined, false, false)).toEqual({ mode: "default", chosen: false, fallback: true });
    // A restart after a fallback starts in default mode again, with no new fallback.
    expect(startMode("default", false, false)).toEqual({ mode: "default", chosen: false });
    // A chosen mode stays, bypass too.
    expect(startMode(bypass, true, false)).toEqual({ mode: bypass, chosen: true });
    expect(startMode("acceptEdits", true, false)).toEqual({ mode: "acceptEdits", chosen: true });
    expect(startMode("plan", true, true)).toEqual({ mode: "plan", chosen: true });
  });

  test("Claude Code's late line moves anvim's own bypass mode to default mode, once", () => {
    const sent: string[] = [];
    let fallbacks = 0;
    const notice = new SandboxNotice((text) => sent.push(text), startMode("bypassPermissions", false, true), () => {
      fallbacks++;
    });
    notice.stderr("Loading plugins\n");
    expect(fallbacks).toBe(0);
    notice.stderr("\n⚠ Sandbox disabled: WSL 1 is not supported\n");
    notice.stderr("\n⚠ Sandbox disabled: WSL 1 is not supported\n");
    expect(fallbacks).toBe(1);
    expect(sent).toEqual([
      "Claude's Bash commands run without a sandbox: WSL 1 is not supported. anvim runs in default mode, so Claude asks before it runs a tool. Start anvim with --mode bypassPermissions to skip the prompts.",
    ]);
    // A chosen bypass mode stays, and the warning says what that means.
    const chosen = new SandboxNotice((text) => sent.push(text), startMode("bypassPermissions", true, true), () => {
      fallbacks++;
    });
    chosen.stderr("\n⚠ Sandbox disabled: WSL 1 is not supported\n");
    expect(fallbacks).toBe(1);
    expect(sent.at(-1)).toStartWith("Claude's Bash commands run without a sandbox, and in bypass mode without asking:");
  });

  test("reads the reason from Claude Code's warning on stderr", () => {
    const line =
      "\n⚠ Sandbox disabled: bubblewrap cannot create a user namespace\n  Commands will run WITHOUT sandboxing.\n";
    expect(sandboxDisabled(line)).toBe("bubblewrap cannot create a user namespace");
    expect(sandboxDisabled("some other output\n")).toBeUndefined();
  });

  test("warns once per start, from the pre-check or from Claude Code's line", () => {
    const sent: string[] = [];
    const notice = new SandboxNotice((text) => sent.push(text));
    notice.warn(undefined);
    notice.stderr("Loading plugins\n");
    expect(sent).toEqual([]);
    notice.stderr("\n⚠ Sandbox disabled: WSL 1 is not supported\n");
    notice.warn("the pre-check's warning");
    notice.stderr("\n⚠ Sandbox disabled: again\n");
    expect(sent).toEqual([
      "Claude's Bash commands run without a sandbox: WSL 1 is not supported. Start anvim with --no-sandbox to hide this warning.",
    ]);
  });

  test("lets the sandbox write the git root when the cwd is below it, so that git add works", () => {
    const repo = host("darwin", ["/w/repo/.git"], [], ["/usr/bin/sandbox-exec"]);
    expect(gitRoot("/w/repo/a/b", repo)).toBe("/w/repo");
    expect(sandboxSetup(true, "/w/repo/a", repo).options.sandbox).toEqual({
      ...on,
      filesystem: { allowWrite: ["/w/repo", ...macCaches] },
    });
    // The cwd is the root, or in no repo.
    expect(gitRoot("/w/repo", repo)).toBeUndefined();
    expect(gitRoot("/w/other", repo)).toBeUndefined();
    // The nearest repo counts, as for git.
    expect(gitRoot("/w/repo/inner/x", host("darwin", ["/w/repo/.git", "/w/repo/inner/.git"]))).toBe("/w/repo/inner");
    // A linked worktree or a submodule has a .git file, and its git dir is elsewhere.
    expect(gitRoot("/w/tree/sub", host("darwin", ["/w/.git"], [], ["/w/tree/.git"]))).toBeUndefined();
    // Never all of home or the whole disk.
    expect(gitRoot("/home/u/project", host("linux", ["/home/u/.git"]))).toBeUndefined();
    expect(gitRoot("/project", host("linux", ["/.git"]))).toBeUndefined();
    // Off, nothing widens what the sandbox allows.
    expect(sandboxSetup(false, "/w/repo/a", repo).options.sandbox).toEqual({ enabled: false });
  });
});

describe("excluded commands", () => {
  test("ask when a command word of the line is an entry's first word", () => {
    expect(excludedCommand("touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("npm run build", ["npm run:*"])).toBe(true);
    expect(excludedCommand("make", ["make"])).toBe(true);
    // Claude Code keeps these in the sandbox. anvim asks anyway, because it
    // cannot follow every form that Claude Code's parser takes.
    expect(excludedCommand("make all", ["make"])).toBe(true);
    expect(excludedCommand("touch ~/x && echo WROTE || echo BLOCKED", ["touch *"])).toBe(true);
    expect(excludedCommand("cat a | touch b", ["touch *"])).toBe(true);
    // Other command words, and the same word as an argument, do not ask.
    expect(excludedCommand("ls touch", ["touch *"])).toBe(false);
    expect(excludedCommand("touchy x", ["touch *"])).toBe(false);
    expect(excludedCommand("echo 'touch x; rm y'", ["touch *", "rm *"])).toBe(false);
    expect(excludedCommand("touch x", [])).toBe(false);
  });

  test("ask for the lines that ran outside the sandbox in bypass mode", () => {
    // With touch * in a project's settings, each of these ran outside the sandbox.
    expect(excludedCommand("CI=1; touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("gtimeout 5 touch ~/x", ["touch *"])).toBe(true);
    expect(excludedCommand("touch\t~/x", ["touch *"])).toBe(true);
  });

  test("see through quotes, VAR=value words, wrappers and their options", () => {
    expect(excludedCommand("'touch' x", ["touch *"])).toBe(true);
    expect(excludedCommand('t"ouch" x', ["touch *"])).toBe(true);
    expect(excludedCommand("\\touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("CI=1 FOO='a b' make", ["make"])).toBe(true);
    expect(excludedCommand("timeout -s KILL 5 touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("env -u HOME nice -n 5 make 2>&1", ["make"])).toBe(true);
    expect(excludedCommand("/usr/bin/touch x", ["touch *"])).toBe(true);
    expect(excludedCommand("if true; then touch x; fi", ["touch *"])).toBe(true);
    expect(excludedCommand("echo $(touch x)", ["touch *"])).toBe(true);
    expect(excludedCommand('echo "`touch x`"', ["touch *"])).toBe(true);
    expect(excludedCommand("(cd a && touch x)", ["touch *"])).toBe(true);
  });

  test("match an entry's words before its first star, from where a command starts", () => {
    expect(excludedCommand("npm run build", ["npm run *"])).toBe(true);
    expect(excludedCommand("npm run", ["npm run *"])).toBe(true);
    expect(excludedCommand("npm test", ["npm run *"])).toBe(false);
    expect(excludedCommand("npm install", ["npm run:*"])).toBe(false);
    expect(excludedCommand("timeout 5 npm run build", ["npm run *"])).toBe(true);
    expect(excludedCommand("echo npm run x", ["npm run *"])).toBe(false);
    // A star inside a word makes that word a prefix.
    expect(excludedCommand("npm run-script x", ["npm run*"])).toBe(true);
    expect(excludedCommand("npm test", ["npm run*"])).toBe(false);
    // Claude Code keeps this line in the sandbox, because grep matches no entry.
    expect(excludedCommand("docker ps | grep x", ["docker *"])).toBe(true);
  });

  test("an entry with a star in its first word asks for every command", () => {
    expect(excludedCommand("ls", ["*"])).toBe(true);
    expect(excludedCommand("rm -rf x", ["* -rf *"])).toBe(true);
    expect(excludedCommand("docker-compose up", ["docker* up"])).toBe(true);
    expect(excludedCommand("podman run", ["docker* up"])).toBe(true);
  });

  test("split a line at its commands", () => {
    expect(commandParts("echo 'a && b' | wc -l; ls\nfalse || true &")).toEqual([
      "echo 'a && b'",
      "wc -l",
      "ls",
      "false",
      "true",
    ]);
    expect(commandParts('echo "a; \\" b"')).toEqual(['echo "a; \\" b"']);
    expect(commandParts("make 2>&1 &> log")).toEqual(["make 2>&1 &> log"]);
    expect(commandParts("a $(b) `c`")).toEqual(["a", "b", "c"]);
  });
});


// A project with a git root above it, a home with a Claude config dir, and
// dirs outside both.
const root = realpathSync(mkdtempSync(join(tmpdir(), "anvim-guard-")));
const repo = join(root, "repo");
const cwd = join(repo, "app");
const home = join(root, "home");
const outside = join(root, "outside");
for (const dir of [join(repo, ".git"), join(cwd, "src"), join(home, ".claude"), join(home, "cache"), outside]) {
  mkdirSync(dir, { recursive: true });
}
writeFileSync(join(cwd, "src", "a.ts"), "");
symlinkSync(outside, join(cwd, "link"));
symlinkSync(join(cwd, "src"), join(outside, "back"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function guard(settings: GuardSettings = {}) {
  return new SandboxGuard({
    cwd,
    home,
    configDir: join(home, ".claude"),
    tmpDir: join(root, "sbtmp"),
    platform: "darwin",
    settings: async () => settings,
  });
}

const signal = new AbortController().signal;
const base = { session_id: "s", transcript_path: "/t", cwd, hook_event_name: "PreToolUse" };
let next = 0;

// Runs a hook for one tool call. Returns the ask's reason, or undefined.
async function reason(hook: HookCallback, tool_name: string, tool_input: Record<string, unknown>) {
  const id = `toolu_${++next}`;
  const out = await hook({ ...base, tool_name, tool_input, tool_use_id: id } as HookInput, id, { signal });
  const specific = (out as { hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string } })
    .hookSpecificOutput;
  if (!specific) {
    expect(out).toEqual({});
    return undefined;
  }
  expect(specific.permissionDecision).toBe("ask");
  return specific.permissionDecisionReason;
}

const write = (g: SandboxGuard, file_path: string) => reason(g.edit, "Write", { file_path, content: "x" });

describe("the Bash guard", () => {
  test("asks for an escape from the sandbox, and canUseTool takes the reason once", async () => {
    const g = guard();
    const out = await g.bash(
      { ...base, tool_name: "Bash", tool_input: { command: "rm ~/x", dangerouslyDisableSandbox: true } } as HookInput,
      "toolu_esc",
      { signal },
    );
    expect(out).toEqual({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: "runs outside the sandbox",
      },
    });
    expect(g.take("toolu_esc")).toBe(REASONS.escape);
    expect(g.take("toolu_esc")).toBeUndefined();
    expect(await reason(g.bash, "Bash", { command: "rm ~/x" })).toBeUndefined();
    expect(await reason(g.bash, "Bash", { command: "rm ~/x", dangerouslyDisableSandbox: false })).toBeUndefined();
    // Claude Code's input schema turns the string into true.
    expect(await reason(g.bash, "Bash", { command: "rm ~/x", dangerouslyDisableSandbox: "true" })).toBe(REASONS.escape);
  });

  test("asks for a command that the effective excludedCommands let out", async () => {
    const g = guard({ effective: { sandbox: { excludedCommands: ["touch *"] } } });
    expect(await reason(g.bash, "Bash", { command: "touch ~/x && echo done" })).toBe(REASONS.excluded);
    expect(await reason(g.bash, "Bash", { command: "ls ~" })).toBeUndefined();
  });

  test("without the fallback, asks for no escape, but still for an excluded command", async () => {
    const g = guard({ effective: { sandbox: { allowUnsandboxedCommands: false, excludedCommands: ["touch *"] } } });
    expect(await reason(g.bash, "Bash", { command: "rm ~/x", dangerouslyDisableSandbox: true })).toBeUndefined();
    // A probe: with these project settings, touch ran outside the sandbox in bypass mode.
    expect(await reason(g.bash, "Bash", { command: "touch ~/x" })).toBe(REASONS.excluded);
  });

  test("asks the user itself in bypass mode, where Claude Code would drop the hook's ask", async () => {
    const asked: unknown[] = [];
    let answer: { behavior: "allow" } | { behavior: "deny"; message: string } = { behavior: "allow" };
    const g = new SandboxGuard({
      cwd,
      tmpDir: join(root, "sbtmp"),
      settings: async () => ({}),
      prompt: async (tool, input, opts) => {
        asked.push([tool, input, opts.toolUseID, opts.agentID, g.take(opts.toolUseID), opts.description]);
        return answer;
      },
    });
    const call = (tool_input: Record<string, unknown>, permission_mode: string, agent_id?: string) =>
      g.bash(
        { ...base, permission_mode, agent_id, tool_name: "Bash", tool_input, tool_use_id: "toolu_b" } as HookInput,
        "toolu_b",
        { signal },
      );
    const escape = { command: "echo x > ~/.zshrc", description: "Write x", dangerouslyDisableSandbox: true };
    expect(await call(escape, "bypassPermissions", "a1")).toEqual({});
    expect(asked).toEqual([["Bash", escape, "toolu_b", "a1", REASONS.escape, "Write x"]]);
    answer = { behavior: "deny", message: "The user doesn't want to proceed" };
    expect(await call(escape, "bypassPermissions")).toEqual({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "The user doesn't want to proceed",
      },
    });
    // In the other modes, Claude Code asks, once.
    for (const mode of ["default", "acceptEdits"]) {
      expect(await call(escape, mode)).toMatchObject({ hookSpecificOutput: { permissionDecision: "ask" } });
    }
    expect(asked).toHaveLength(2);
    const write = await g.edit(
      {
        ...base,
        permission_mode: "bypassPermissions",
        tool_name: "Write",
        tool_input: { file_path: join(cwd, ".claude", "settings.json") },
        tool_use_id: "toolu_w",
      } as HookInput,
      "toolu_w",
      { signal },
    );
    expect(write).toMatchObject({ hookSpecificOutput: { permissionDecision: "deny" } });
    expect(asked.at(-1)).toEqual([
      "Write",
      { file_path: join(cwd, ".claude", "settings.json") },
      "toolu_w",
      undefined,
      REASONS.settings,
      undefined,
    ]);
  });

  test("asks before a Codex run that writes, in bypass mode too, and never sends it back", async () => {
    const asked: string[] = [];
    const g = new SandboxGuard({
      cwd,
      tmpDir: join(root, "sbtmp"),
      settings: async () => ({}),
      prompt: async (_tool, _input, opts) => {
        asked.push(g.take(opts.toolUseID)!);
        return { behavior: "allow" };
      },
    });
    const call = (tool_input: Record<string, unknown>, permission_mode: string) =>
      g.codex(
        { ...base, permission_mode, tool_name: CODEX_TOOL, tool_input, tool_use_id: "toolu_c" } as HookInput,
        "toolu_c",
        { signal },
      );
    const task = { description: "Fix it", prompt: "Fix the bug" };
    expect(await call(task, "bypassPermissions")).toEqual({});
    expect(asked).toEqual([REASONS.codex]);
    expect(await call(task, "default")).toMatchObject({ hookSpecificOutput: { permissionDecision: "ask" } });
    expect(await call({ ...task, read_only: true }, "bypassPermissions")).toEqual({});
    expect(await call(task, "plan")).toEqual({});
    expect(asked).toHaveLength(1);
    // Codex has no way to write inside the sandbox, so the user decides at once.
    const sendBack = new SendBack({ tmpDir: "/tmp", log: () => {} });
    expect(sendBack.decide({ tool: CODEX_TOOL, input: task, reason: REASONS.codex })).toBeUndefined();
  });

  test("still asks for an escape when the settings cannot be read", async () => {
    const g = new SandboxGuard({
      cwd,
      settings: async () => {
        throw new Error("no session");
      },
    });
    expect(await reason(g.bash, "Bash", { command: "ls", dangerouslyDisableSandbox: true })).toBe(REASONS.escape);
  });
});

describe("the edit guard", () => {
  test("lets edits in the cwd go, and asks for a path outside the trusted dirs", async () => {
    const g = guard();
    expect(await write(g, join(cwd, "src", "a.ts"))).toBeUndefined();
    expect(await reason(g.edit, "Edit", { file_path: join(cwd, "src", "a.ts"), old_string: "a" })).toBeUndefined();
    expect(await write(g, join(home, "notes.txt"))).toBe("outside the trusted dirs: ~/notes.txt");
    expect(await write(g, join(outside, "x"))).toBe(`outside the trusted dirs: ${join(outside, "x")}`);
    expect(await reason(g.edit, "NotebookEdit", { notebook_path: join(outside, "n.ipynb") })).toBe(
      REASONS.outside(join(outside, "n.ipynb")),
    );
    // The git root is not the cwd, so it is outside unless the settings allow it.
    expect(await write(g, join(repo, "README.md"))).toBe(REASONS.outside(join(repo, "README.md")));
  });

  test("resolves symlinks, also for a new file under a new dir", async () => {
    const g = guard();
    expect(await write(g, join(cwd, "link", "x"))).toBe(REASONS.outside(join(outside, "x")));
    expect(await write(g, join(cwd, "link", "new", "dir", "x"))).toBe(
      REASONS.outside(join(outside, "new", "dir", "x")),
    );
    expect(await write(g, join(cwd, "new", "dir", "x"))).toBeUndefined();
    expect(await write(g, join(outside, "back", "a.ts"))).toBeUndefined();
    // The system takes .. after the symlink, a lexical resolve before it. Both must be trusted.
    expect(await write(g, `${cwd}/link/../x`)).toBe(REASONS.outside(join(root, "x")));
    expect(realPath(`${cwd}/link/../x`)).toBe(join(root, "x"));
    // Here the system's form is in the cwd, and the lexical one is not.
    expect(realPath(`${outside}/back/../x`)).toBe(join(cwd, "x"));
    expect(await write(g, `${outside}/back/../x`)).toBe(REASONS.outside(join(outside, "x")));
  });

  test("trusts the sandbox's temp dir, the config dir's projects, plans and agent memory, and allowWrite", async () => {
    const g = guard({
      effective: {
        sandbox: {
          filesystem: { allowWrite: ["~/cache", `/${outside}/ok`, "rel", repo, join(root, "glob", "*")] },
        },
      },
    });
    expect(await write(g, join(root, "sbtmp", "scratch.txt"))).toBeUndefined();
    expect(await write(g, join(home, ".claude", "projects", "p", "memory", "m.md"))).toBeUndefined();
    expect(await write(g, join(home, ".claude", "plans", "plan.md"))).toBeUndefined();
    expect(await write(g, join(home, ".claude", "agent-memory", "a", "m.md"))).toBeUndefined();
    expect(await write(g, join(home, ".claude", "settings.json"))).toBe(
      "outside the trusted dirs: ~/.claude/settings.json",
    );
    expect(await write(g, join(home, "cache", "x"))).toBeUndefined();
    expect(await write(g, join(outside, "ok", "x"))).toBeUndefined();
    expect(await write(g, join(cwd, "rel", "x"))).toBeUndefined();
    expect(await write(g, join(repo, "README.md"))).toBeUndefined();
    // A glob entry is no trusted dir.
    expect(await write(g, join(root, "glob", "x"))).toBe(REASONS.outside(join(root, "glob", "x")));
  });

  test("trusts the caches that the sandbox may write, next to a settings file's allowWrite", async () => {
    // getSettings() merges the flag settings' list with the settings files' lists.
    const own = sandboxSetup(true, cwd, { ...host("darwin"), home }).options.sandbox!.filesystem!.allowWrite!;
    const g = guard({ effective: { sandbox: { filesystem: { allowWrite: [...own, "~/cache"] } } } });
    expect(await write(g, join(home, ".npm", "_cacache", "x"))).toBeUndefined();
    expect(await write(g, join(home, ".bun", "install", "cache", "x"))).toBeUndefined();
    expect(await write(g, join(home, "Library", "Caches", "go-build", "x"))).toBeUndefined();
    expect(await write(g, join(home, "cache", "x"))).toBeUndefined();
    // Only the caches themselves, not their neighbors.
    expect(await write(g, join(home, ".npmrc"))).toBe(REASONS.outside("~/.npmrc"));
    expect(await write(g, join(home, ".bun", "bin", "bun"))).toBe(REASONS.outside("~/.bun/bin/bun"));
    // Claude Code's protected names still ask below them.
    expect(await write(g, join(home, ".npm", ".npmrc"))).toBe(REASONS.config);
  });

  test("asks for the project's settings files, in the cwd and in the git root", async () => {
    const g = guard({ effective: { sandbox: { filesystem: { allowWrite: [repo] } } } });
    for (const dir of [cwd, repo]) {
      expect(await write(g, join(dir, ".claude", "settings.json"))).toBe(REASONS.settings);
      expect(await write(g, join(dir, ".claude", "settings.local.json"))).toBe(REASONS.settings);
    }
    // macOS finds the file by any case.
    expect(await write(g, join(cwd, ".Claude", "Settings.json"))).toBe(REASONS.settings);
  });

  test("asks for Claude Code's protected files and dirs below the trusted dirs", async () => {
    const g = guard({ effective: { sandbox: { filesystem: { allowWrite: [repo] } } } });
    for (const path of [
      join(cwd, ".claude", "agents", "a.md"),
      join(cwd, ".claude", "hooks.json"),
      join(cwd, ".mcp.json"),
      join(cwd, ".envrc"),
      join(cwd, "sub", ".npmrc"),
      join(cwd, ".vscode", "settings.json"),
      join(cwd, ".config", "git", "config"),
      join(cwd, ".Husky", "pre-commit"),
      join(repo, ".git", "hooks", "pre-commit"),
      join(repo, ".gitmodules"),
      join(root, "sbtmp", ".zshrc"),
    ]) {
      expect(await write(g, path)).toBe(REASONS.config);
    }
    // Claude Code's worktree agents work in .claude/worktrees, and it does not
    // ask there, but it does for its list inside the worktree.
    const tree = join(cwd, ".claude", "worktrees", "w1");
    expect(await write(g, join(tree, "src", "a.ts"))).toBeUndefined();
    expect(await write(g, join(tree, ".git"))).toBe(REASONS.config);
    expect(await write(g, join(tree, ".claude", "settings.json"))).toBe(REASONS.config);
    expect(await write(g, join(tree, ".claude", "worktrees", "w2", "a.ts"))).toBe(REASONS.config);
    expect(await write(g, join(tree, ".mcp.json"))).toBe(REASONS.config);
    expect(await write(g, join(cwd, ".claude", "scheduled_tasks.json"))).toBeUndefined();
    expect(await write(g, join(cwd, ".claude", "x", "scheduled_tasks.json"))).toBe(REASONS.config);
    expect(await write(g, join(cwd, "src", "git", "config"))).toBeUndefined();
    expect(await write(g, join(cwd, "claude", "x.md"))).toBeUndefined();
    // Only the part below the trusted dir counts, so the config dir's own name does not.
    expect(await write(g, join(home, ".claude", "projects", "p", "memory", "m.md"))).toBeUndefined();
  });

  test("off registers no guard hooks, on runs the edit guard after the preview", async () => {
    const preview: HookCallback = async () => ({});
    expect(preToolUse(preview)).toEqual([{ matcher: "Edit|Write|NotebookEdit", hooks: [preview] }]);
    const order: string[] = [];
    const slow: HookCallback = async () => {
      order.push("preview starts");
      await Bun.sleep(20);
      order.push("preview ends");
      return {};
    };
    // In bypass mode the guard asks the user itself, which shows when it runs.
    const g = new SandboxGuard({
      cwd,
      tmpDir: join(root, "sbtmp"),
      settings: async () => ({}),
      prompt: async () => {
        order.push("guard asks");
        return { behavior: "allow" };
      },
    });
    const hooks = preToolUse(slow, g);
    expect(hooks.map((h) => h.matcher)).toEqual(["Edit|Write|NotebookEdit", "Bash", CODEX_TOOL]);
    // A prompt from the guard waits for the user, not for Claude Code's default timeout.
    expect(hooks.map((h) => h.timeout)).toEqual([GUARD_TIMEOUT_S, GUARD_TIMEOUT_S, GUARD_TIMEOUT_S]);
    expect(hooks[1]!.hooks).toEqual([g.bash]);
    const out = await hooks[0]!.hooks[0]!(
      {
        ...base,
        permission_mode: "bypassPermissions",
        tool_name: "Write",
        tool_input: { file_path: join(outside, "x") },
        tool_use_id: "toolu_o",
      } as HookInput,
      "toolu_o",
      { signal },
    );
    expect(out).toEqual({});
    expect(order).toEqual(["preview starts", "preview ends", "guard asks"]);
  });
});
