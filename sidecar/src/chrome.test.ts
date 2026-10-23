import type { McpServerStatus } from "@anthropic-ai/claude-agent-sdk";
import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chromeArgs, chromeEvent, enabledByDefault } from "./chrome";

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
