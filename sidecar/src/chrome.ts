// Claude in Chrome, as Claude Code's terminal runs it with --chrome, and its
// /chrome dialog. The SDK has the dialog's calls, but not in its types.
import type { McpServerStatus, Query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ChromeState, Event } from "./protocol";

export const CHROME_SERVER = "claude-in-chrome";

type ChromeDialog = Omit<ChromeState, "status" | "browser" | "skips_checks"> & {
  connected: boolean;
  paired_browser?: string;
};
type ChromeBrowser = { device_id: string; name: string; os_platform?: string; current: boolean };
type ChromeCalls = {
  getChromeDialog(): Promise<ChromeDialog>;
  getChromeBrowsers(): Promise<{ browsers: ChromeBrowser[] }>;
  selectChromeBrowser(deviceId: string): Promise<{ name?: string }>;
};

export function chromeCalls(q: Query): ChromeCalls {
  return q as unknown as ChromeCalls;
}

// Claude Code's "Enabled by default" setting, in its global config. Its
// terminal reads it at start, and an SDK session ignores it.
export function enabledByDefault(env: NodeJS.ProcessEnv = process.env): boolean {
  try {
    const file = join(env.CLAUDE_CONFIG_DIR || homedir(), ".claude.json");
    return JSON.parse(readFileSync(file, "utf8")).claudeInChromeDefaultEnabled === true;
  } catch {
    return false;
  }
}

// Claude Code's --chrome or --no-chrome. Without a flag, the setting decides.
// Off adds no flag, so CLAUDE_CODE_ENABLE_CFC=1 still turns it on.
export function chromeArgs(chrome: boolean | undefined, byDefault = enabledByDefault): Record<string, null> {
  if (chrome === false) return { "no-chrome": null };
  return (chrome ?? byDefault()) ? { chrome: null } : {};
}

// The claude binary that the SDK runs, from its package for this platform.
function claudeBinary(): string {
  const require = createRequire(import.meta.url);
  const base = `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`;
  for (const pkg of [base, `${base}-musl`]) {
    try {
      return join(dirname(require.resolve(`${pkg}/package.json`)), "claude");
    } catch {}
  }
  throw new Error(`${base} is not installed`);
}

// Writes the setting as Claude Code's editor extensions do. It holds for the
// next sessions, in anvim and in the terminal.
export async function setEnabledByDefault(on: boolean): Promise<void> {
  const proc = Bun.spawn([claudeBinary(), "edit-chrome-settings", "--json"], {
    stdin: new Blob([JSON.stringify({ enabledByDefault: on })]),
    stdout: "ignore",
    stderr: "pipe",
  });
  const [code, err] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(err.trim() || `claude edit-chrome-settings ended with ${code}`);
}

// As Claude Code's dialog reads its server's state.
function chromeStatus(servers: McpServerStatus[]): ChromeState["status"] {
  const own = servers.filter((s) => s.name === CHROME_SERVER);
  if (own.some((s) => s.status === "connected")) return "connected";
  if (own.some((s) => s.status === "pending")) return "connecting";
  if (own.some((s) => s.status === "disabled")) return "disabled";
  return own.length > 0 ? "failed" : "absent";
}

export type ChromeMessage = NonNullable<Extract<Event, { type: "chrome" }>["message"]>;

export function chromeEvent(
  dialog: ChromeDialog,
  servers: McpServerStatus[],
  skipsChecks: boolean,
  message?: ChromeMessage,
): Event {
  const status = chromeStatus(servers);
  return {
    type: "chrome",
    chrome: {
      allowed: dialog.allowed,
      subscriber: dialog.subscriber,
      wsl: dialog.wsl,
      installed: dialog.installed,
      status,
      browser: status === "connected" ? dialog.paired_browser : undefined,
      enabled_by_default: dialog.enabled_by_default,
      skips_checks: skipsChecks && status !== "absent",
      urls: dialog.urls,
    },
    message,
  };
}

export function browsersEvent(browsers: ChromeBrowser[]): Event {
  return {
    type: "chrome_browsers",
    browsers: browsers.map((b) => ({ device_id: b.device_id, name: b.name, os: b.os_platform, current: b.current })),
  };
}
