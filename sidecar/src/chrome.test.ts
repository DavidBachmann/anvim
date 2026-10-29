import type { McpServerStatus } from "@anthropic-ai/claude-agent-sdk";
import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromeArgs, chromeEvent, chromeForCodex, enabledByDefault } from "./chrome";

test("a flag wins over Claude Code's Enabled by default setting, which decides without one", () => {
  const dir = mkdtempSync(join(tmpdir(), "anvim-chrome-"));
  writeFileSync(join(dir, ".claude.json"), JSON.stringify({ claudeInChromeDefaultEnabled: true }));
  const on = () => enabledByDefault({ CLAUDE_CONFIG_DIR: dir });
  expect(on()).toBe(true);
  expect(enabledByDefault({ CLAUDE_CONFIG_DIR: join(dir, "missing") })).toBe(false);
  expect(chromeArgs(undefined, on)).toEqual({ chrome: null });
  expect(chromeArgs(false, on)).toEqual({ "no-chrome": null });
  expect(chromeArgs(true, () => false)).toEqual({ chrome: null });
  expect(chromeArgs(undefined, () => false)).toEqual({});
});

test("the Chrome tab reads the server's state as Claude Code's /chrome dialog does", () => {
  const dialog = {
    allowed: true,
    subscriber: true,
    wsl: false,
    installed: true,
    connected: true,
    paired_browser: "Browser 1",
    enabled_by_default: false,
    urls: { install: "i", reconnect: "r", permissions: "p" },
  };
  const server = (status: string) => [{ name: "claude-in-chrome", status } as McpServerStatus];
  const state = (servers: McpServerStatus[]) => {
    const ev = chromeEvent(dialog, servers, true);
    return ev.type === "chrome" ? ev.chrome : undefined;
  };
  expect(state(server("connected"))).toMatchObject({ status: "connected", browser: "Browser 1", skips_checks: true });
  expect(state(server("pending"))?.status).toBe("connecting");
  expect(state(server("disabled"))?.status).toBe("disabled");
  expect(state(server("needs-auth"))?.status).toBe("failed");
  // Without the server, the extension has nothing to skip.
  expect(state([])).toMatchObject({ status: "absent", skips_checks: false });
});

test("hands Claude's Chrome to Codex only with a clear browser, in the session's mode", async () => {
  const config = { type: "stdio", command: "/sdk/claude", args: ["--claude-in-chrome-mcp"] };
  const chrome = { name: "claude-in-chrome", status: "connected", source: "dynamic", config } as McpServerStatus;
  const browser = (id: string, current = false) => ({ device_id: id, name: id, current });
  const handOver = (servers: McpServerStatus[], browsers: ReturnType<typeof browser>[], mode = "default", env = {}) =>
    chromeForCodex(
      { mcpServerStatus: async () => servers, getChromeBrowsers: async () => ({ browsers }) },
      mode,
      env,
    );

  expect(await handOver([], [browser("a")])).toContain("The user can connect it with /chrome.");
  expect(await handOver([{ ...chrome, status: "failed" }], [browser("a")])).toContain("/chrome");
  // A settings server can take the name, but it is not Claude Code's own.
  expect(await handOver([{ ...chrome, source: "project" }], [browser("a")])).toContain("/chrome");
  expect(await handOver([chrome], [])).toContain("No browser is connected");
  expect(await handOver([chrome], [browser("a"), browser("b")])).toContain("Ask the user to select one with /chrome");

  const current = await handOver([chrome], [browser("a"), browser("b", true)], "bypassPermissions", {
    CLAUDE_CONFIG_DIR: "/c",
  });
  expect(current).toEqual({
    name: "claude-in-chrome",
    command: "/sdk/claude",
    args: ["--claude-in-chrome-mcp"],
    env: {
      CLAUDE_CONFIG_DIR: "/c",
      CLAUDE_CHROME_PAIRED_DEVICE_ID: "b",
      CLAUDE_CHROME_PERMISSION_MODE: "skip_all_permission_checks",
    },
  });
  // The default login has no config dir, and every mode but bypass asks.
  const only = await handOver([chrome], [browser("a")], "acceptEdits");
  expect(only).toMatchObject({ env: { CLAUDE_CHROME_PAIRED_DEVICE_ID: "a", CLAUDE_CHROME_PERMISSION_MODE: "ask" } });
  expect(only).not.toHaveProperty("env.CLAUDE_CONFIG_DIR");
});
