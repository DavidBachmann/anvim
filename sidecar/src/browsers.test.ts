import type { McpServerStatus } from "@anthropic-ai/claude-agent-sdk";
import { expect, test } from "bun:test";
import { type BrowserCalls, BrowserWatch, browserSettings, checkBrowsers } from "./browsers";
import type { Event } from "./protocol";

test("without --safari, the mcp-safari server is denied for the session", () => {
  expect(browserSettings(false)).toEqual({ deniedMcpServers: [{ serverName: "mcp-safari" }] });
  expect(browserSettings(true)).toEqual({});
});

// A session whose Chrome server, Chrome browsers and Safari status call answer as given.
function fake(opts: {
  chrome?: string;
  browsers?: number;
  safari?: () => Promise<string>;
}): BrowserCalls & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    mcpServerStatus: async () =>
      opts.chrome ? [{ name: "claude-in-chrome", status: opts.chrome } as McpServerStatus] : [],
    getChromeBrowsers: async () => ({
      browsers: Array.from({ length: opts.browsers ?? 0 }, (_, i) => ({
        device_id: `d${i}`,
        name: `B${i}`,
        current: false,
      })),
    }),
    request: async (req) => {
      calls.push(req.tool);
      const text = await (opts.safari ?? (async () => "{}"))();
      return { response: { content: [{ type: "text", text }] } };
    },
  };
}

const status = (profiles: unknown[]) => async () => JSON.stringify({ bridge: "authenticated", profiles, port: 8092 });
const state = (browsers: { name: string; connected: boolean }[]) => browsers.map((b) => [b.name, b.connected]);

test("Chrome is connected only with a connected server and a browser", async () => {
  const on = { chrome: true, safari: false };
  expect(state(await checkBrowsers(fake({ chrome: "connected", browsers: 1 }), on))).toEqual([["chrome", true]]);
  // The server connects without an extension.
  const none = await checkBrowsers(fake({ chrome: "connected", browsers: 0 }), on);
  expect(none).toMatchObject([{ name: "chrome", connected: false, why: expect.any(String) }]);
  expect(state(await checkBrowsers(fake({ chrome: "failed", browsers: 1 }), on))).toEqual([["chrome", false]]);
});

test("Safari is connected only when its status lists a profile", async () => {
  const on = { chrome: false, safari: true };
  const q = fake({ safari: status([{ id: "p" }]) });
  expect(state(await checkBrowsers(q, on))).toEqual([["safari", true]]);
  expect(q.calls).toEqual(["mcp__mcp-safari__status"]);
  const none = await checkBrowsers(fake({ safari: status([]) }), on);
  expect(none).toMatchObject([{ name: "safari", connected: false, why: expect.any(String) }]);
});

test("a check that fails counts as not connected, with the error", async () => {
  const q = fake({
    chrome: "connected",
    safari: async () => {
      throw new Error("MCP server not connected: mcp-safari");
    },
  });
  q.getChromeBrowsers = async () => {
    throw new Error("offline");
  };
  const browsers = await checkBrowsers(q, { chrome: true, safari: true });
  expect(state(browsers)).toEqual([
    ["chrome", false],
    ["safari", false],
  ]);
  expect(browsers[0]!.why).toContain("offline");
  expect(browsers[1]!.why).toContain("MCP server not connected: mcp-safari");
});

test("a check that never answers counts as not connected", async () => {
  const q = fake({ safari: () => new Promise<string>(() => {}) });
  const browsers = await checkBrowsers(q, { chrome: false, safari: true }, 10);
  expect(browsers).toMatchObject([{ name: "safari", connected: false, why: expect.stringContaining("no answer") }]);
});

test("the watch emits the first result, then only changes", async () => {
  const events: Event[] = [];
  let profiles: unknown[] = [];
  const q = fake({ safari: async () => JSON.stringify({ profiles }) });
  const watch = new BrowserWatch((ev) => events.push(ev), { chrome: false, safari: true });
  await watch.tick(q);
  await watch.tick(q);
  profiles = [{ id: "p" }];
  await watch.tick(q);
  expect(events.map((ev) => ev.type === "browsers" && state(ev.browsers))).toEqual([
    [["safari", false]],
    [["safari", true]],
  ]);
});
