// The browsers that Claude can drive: Claude in Chrome, and Safari through
// the mcp-safari server. While one is on, a timer checks whether its browser
// extension is connected, and the statusline shows the ones that are not.
import type { Options, Query } from "@anthropic-ai/claude-agent-sdk";
import { CHROME_SERVER, type chromeCalls } from "./chrome";
import type { Event } from "./protocol";
import { errorText } from "./text";

export const SAFARI_SERVER = "mcp-safari";

// Safari's extension rescans for servers. It finds a new one after about 18 s.
const FIRST_MS = 30_000;
const EVERY_MS = 15_000;
// The SDK's calls have no timeout, and a check that never ends would stop the
// watch. The Safari call alone waits up to 30 s for a server that starts.
const CHECK_MS = 40_000;

export type Browser = Extract<Event, { type: "browsers" }>["browsers"][number];
export type BrowsersOn = { chrome: boolean; safari: boolean };

type Settings = Exclude<Options["settings"], string | undefined>;
type McpCallResponse = { response?: { content?: { type: string; text?: string }[] } };
// The SDK sends mcp_call as a control request, but its Query has no method for it.
type McpCalls = {
  request(req: { subtype: "mcp_call"; tool: string; arguments: Record<string, unknown> }): Promise<McpCallResponse>;
};
export type BrowserCalls = Pick<ReturnType<typeof chromeCalls>, "mcpServerStatus" | "getChromeBrowsers"> & McpCalls;

export function browserCalls(q: Query): Query & BrowserCalls {
  return q as Query & BrowserCalls;
}

// The flag settings. Without --safari, the server that Claude Code's MCP
// config may add does not load in the session.
export function browserSettings(safari: boolean): Settings {
  return safari ? {} : { deniedMcpServers: [{ serverName: SAFARI_SERVER }] };
}

async function chrome(q: BrowserCalls): Promise<Browser> {
  const servers = (await q.mcpServerStatus()).filter((s) => s.name === CHROME_SERVER);
  if (!servers.some((s) => s.status === "connected")) {
    const why = servers[0]
      ? `the ${CHROME_SERVER} server is ${servers[0].status}`
      : `the ${CHROME_SERVER} server is not in this session`;
    return { name: "chrome", connected: false, why };
  }
  // The dialog's connected flag stays true without an extension. The browser list does not.
  const { browsers } = await q.getChromeBrowsers();
  return browsers.length > 0
    ? { name: "chrome", connected: true }
    : { name: "chrome", connected: false, why: "no Chrome browser has the Claude extension connected" };
}

async function safari(q: BrowserCalls): Promise<Browser> {
  const res = await q.request({ subtype: "mcp_call", tool: `mcp__${SAFARI_SERVER}__status`, arguments: {} });
  const text = res.response?.content?.find((c) => c.type === "text")?.text ?? "";
  const status = JSON.parse(text) as { profiles?: unknown[] };
  return Array.isArray(status.profiles) && status.profiles.length > 0
    ? { name: "safari", connected: true }
    : { name: "safari", connected: false, why: `Safari's extension has not connected to ${SAFARI_SERVER}` };
}

async function within<T>(ms: number, p: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no answer in ${ms / 1000} s`)), ms);
  });
  try {
    return await Promise.race([p, late]);
  } finally {
    clearTimeout(timer);
  }
}

// Never throws: a check that fails counts as not connected.
export function checkBrowsers(q: BrowserCalls, on: BrowsersOn, ms = CHECK_MS): Promise<Browser[]> {
  const settle = (name: Browser["name"], label: string, check: () => Promise<Browser>) =>
    within(ms, check()).catch(
      (err): Browser => ({ name, connected: false, why: `the ${label} check failed: ${errorText(err)}` }),
    );
  return Promise.all([
    ...(on.chrome ? [settle("chrome", "Chrome", () => chrome(q))] : []),
    ...(on.safari ? [settle("safari", "Safari", () => safari(q))] : []),
  ]);
}

// Checks the browsers that are on, first after FIRST_MS and then every
// EVERY_MS. It emits after the first check, and then only on a change.
export class BrowserWatch {
  private timer: ReturnType<typeof setTimeout> | undefined;
  private checking = false;
  private stopped = false;
  private last: string | undefined;

  constructor(
    private emit: (ev: Event) => void,
    private on: BrowsersOn,
  ) {}

  start(q: BrowserCalls): void {
    if (!(this.on.chrome || this.on.safari)) return;
    this.timer = setTimeout(() => {
      this.timer = setInterval(() => void this.tick(q), EVERY_MS).unref();
      void this.tick(q);
    }, FIRST_MS).unref();
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.timer);
    clearInterval(this.timer);
    this.timer = undefined;
  }

  // The Safari call waits up to 30 s for a server that is still starting, so
  // a tick skips while the last check runs.
  async tick(q: BrowserCalls): Promise<void> {
    if (this.checking) return;
    this.checking = true;
    try {
      const browsers = await checkBrowsers(q, this.on);
      const key = JSON.stringify(browsers);
      if (this.stopped || key === this.last) return;
      this.last = key;
      this.emit({ type: "browsers", browsers });
    } finally {
      this.checking = false;
    }
  }
}
