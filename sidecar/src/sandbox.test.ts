import { describe, expect, test } from "bun:test";
import { gitRoot, type Host, SandboxNotice, sandboxDisabled, sandboxProblem, sandboxSetup } from "./sandbox";

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

describe("the sandbox", () => {
  test("is on with prompts for Bash, and goes on unsandboxed where it cannot start", () => {
    expect(sandboxSetup(true, "/p", mac)).toEqual({ options: { sandbox: on }, warning: undefined });
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
    expect(sandboxSetup(true, "/p", host("linux", [], ["bwrap"])).warning).toBe(
      "Claude's Bash commands run without a sandbox: socat is not on PATH (install socat). Start anvim with --no-sandbox to hide this warning.",
    );
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
      filesystem: { allowWrite: ["/w/repo"] },
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
