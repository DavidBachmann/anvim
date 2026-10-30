import { describe, expect, test } from "bun:test";
import { contextEvent, mcpEvent, modelsEvent, sessionInfoEvent, usageEvent } from "./dialogs";
import { limitsEvent, limitsResetDelay } from "./limits";

describe("dialogs", () => {
  test("models carry their effort levels, and a model without effort has none", () => {
    expect(
      modelsEvent([
        {
          value: "haiku",
          displayName: "Haiku 5.5",
          description: "Fastest",
          resolvedModel: "claude-haiku-5-5",
          supportsEffort: true,
          supportedEffortLevels: ["low", "medium"],
        },
        { value: "claude-haiku-4-5", displayName: "Haiku 4.5", description: "Older", supportsEffort: false },
      ]),
    ).toEqual({
      type: "models",
      models: [
        { value: "haiku", name: "Haiku 5.5", description: "Fastest", resolved: "claude-haiku-5-5", effort_levels: ["low", "medium"] },
        { value: "claude-haiku-4-5", name: "Haiku 4.5", description: "Older", resolved: undefined },
      ],
    });
  });

  test("usage has the plan's limits in Claude Code's order, and what used them", () => {
    const window = (requests: number) => ({
      request_count: requests,
      session_count: 2,
      behaviors: [
        { key: "subagent_heavy", pct: 88, count: 5 },
        { key: "a_new_key", pct: 10, count: 1 },
      ],
      agents: [
        { name: "nvim-plugin", pct: 16 },
        { name: "general-purpose", pct: 1 },
      ],
      skills: [],
      plugins: [],
      mcp_servers: [{ name: "anvim", pct: 1 }],
    });
    const answer = {
      session: {
        total_cost_usd: 7.56,
        total_api_duration_ms: 1229000,
        total_duration_ms: 42601000,
        total_lines_added: 226,
        total_lines_removed: 31,
        model_usage: {
          "claude-opus-5-5": {
            inputTokens: 3700,
            outputTokens: 109100,
            cacheReadInputTokens: 14400000,
            cacheCreationInputTokens: 310200,
            costUSD: 7.56,
          },
          "claude-haiku-5-5": {
            inputTokens: 1400,
            outputTokens: 25,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            costUSD: 0.0002,
          },
        },
      },
      subscription_type: "team",
      rate_limits_available: true,
      rate_limits: {
        five_hour: { utilization: 12, resets_at: "2026-10-23T22:59:59.901863+00:00" },
        seven_day: { utilization: 33, resets_at: "2026-10-24T02:59:59+00:00" },
        seven_day_sonnet: null,
        model_scoped: [{ display_name: "Fable", utilization: 0, resets_at: null }],
      },
      behaviors: { day: window(10), week: window(70) },
    } as unknown as Parameters<typeof usageEvent>[0];
    const day = {
      title: "Last 24h · 10 requests · 2 sessions",
      lines: [
        "88% of your usage came from subagent-heavy sessions",
        "Top subagents: nvim-plugin 16%, general-purpose 1%",
        "Top MCP servers: anvim 1%",
      ],
    };
    expect(usageEvent(answer)).toEqual({
      type: "usage",
      usage: {
        session: {
          title: "Session",
          lines: [
            "Total cost: $7.56",
            "Total duration (API): 20m 29s",
            "Total duration (wall): 11h 50m 1s",
            "Total code changes: 226 lines added, 31 lines removed",
            "Usage by model:",
            "  claude-opus-5-5: 3.7k input, 109.1k output, 14.4m cache read, 310.2k cache write ($7.56)",
            "  claude-haiku-5-5: 1.4k input, 25 output, 0 cache read, 0 cache write ($0.0002)",
          ],
        },
        limits: [
          { title: "Current session", percent: 12, resets_at: 1792796399 },
          { title: "Current week (all models)", percent: 33, resets_at: 1792810799 },
          { title: "Current week (Fable)", percent: 0 },
        ],
        windows: [day, { ...day, title: "Last 7d · 70 requests · 2 sessions" }],
      },
    });
    // Without a plan, there are no limits.
    const apiKey = { ...answer, subscription_type: null, rate_limits: null, behaviors: null };
    expect(usageEvent(apiKey)).toMatchObject({ type: "usage", usage: { limits: [], windows: [] } });
    // The statusline's share of the same answer.
    expect(limitsEvent(answer)).toEqual({ type: "limits", session: 12, week: 33 });
    expect(limitsEvent(apiKey)).toEqual({ type: "limits" });
    // The statusline fetches again a minute after the first reset, even when idle.
    const [session, week] = [Date.parse("2026-10-23T22:59:59.901Z"), Date.parse("2026-10-24T02:59:59Z")];
    expect(limitsResetDelay(answer, session - 1000)).toBe(61_000);
    expect(limitsResetDelay(answer, session)).toBe(week - session + 60_000);
    expect(limitsResetDelay(answer, week)).toBeUndefined();
    expect(limitsResetDelay(apiKey)).toBeUndefined();
  });

  test("context_usage draws Claude Code's grid and legend, and sums the MCP tools by server", () => {
    const cell = (categoryName: string, color: string, squareFullness: number) => ({ categoryName, color, squareFullness });
    const answer = {
      model: "claude-opus-5-5",
      totalTokens: 390800,
      maxTokens: 1000000,
      percentage: 39.08,
      categories: [
        { name: "Messages", tokens: 358900, color: "purple_FOR_SUBAGENTS_ONLY", kind: "used" },
        { name: "MCP tools (deferred)", tokens: 79300, color: "inactive", kind: "deferred" },
        { name: "Free space", tokens: 576200, color: "promptBorder", kind: "free" },
        { name: "Compact buffer", tokens: 0, color: "inactive", kind: "buffer" },
      ],
      gridRows: [[cell("Messages", "purple_FOR_SUBAGENTS_ONLY", 1), cell("Messages", "purple_FOR_SUBAGENTS_ONLY", 0.4), cell("Free space", "promptBorder", 1)]],
      mcpTools: [
        { name: "a", serverName: "notion", tokens: 2000, isLoaded: false },
        { name: "b", serverName: "notion", tokens: 1500, isLoaded: false },
        { name: "c", serverName: "anvim", tokens: 300, isLoaded: true },
      ],
      agents: [],
      memoryFiles: [],
    } as unknown as Parameters<typeof contextEvent>[0];
    expect(contextEvent(answer)).toEqual({
      type: "context_usage",
      context: {
        title: "claude-opus-5-5 · 390.8k/1m tokens (39%)",
        grid: [
          [
            { glyph: "⛁", color: "purple_FOR_SUBAGENTS_ONLY" },
            { glyph: "⛀", color: "purple_FOR_SUBAGENTS_ONLY" },
            { glyph: "⛶", color: "promptBorder" },
          ],
        ],
        legend: [
          { glyph: "⛁", color: "purple_FOR_SUBAGENTS_ONLY", text: "Messages: 358.9k tokens (35.9%)" },
          { glyph: "⛶", color: "inactive", text: "MCP tools (deferred): 79.3k tokens (7.9%)", dim: true },
          { glyph: "⛶", color: "promptBorder", text: "Free space: 576.2k tokens (57.6%)" },
        ],
        sections: [{ title: "MCP tools", lines: ["notion: 2 tools, 3.5k (deferred)", "anvim: 1 tool, 300"] }],
      },
    });
  });

  test("mcp_servers marks anvim's own server by its source, not its name", () => {
    const servers = [
      { name: "anvim", status: "connected", source: "sdk", tools: [{ name: "show_user" }] },
      { name: "anvim", status: "failed", source: "user", error: "boom", config: { command: "npx", args: ["evil"] } },
      { name: "Notion", status: "needs-auth", source: "claudeai", config: { type: "claudeai-proxy", url: "https://proxy", id: "1" } },
    ] as unknown as Parameters<typeof mcpEvent>[0];
    expect(mcpEvent(servers, "Could not reconnect x: no")).toEqual({
      type: "mcp_servers",
      servers: [
        { name: "anvim", status: "connected", scope: "sdk", tools: ["show_user"], own: true },
        { name: "anvim", status: "failed", scope: "user", where: "npx evil", error: "boom", tools: [] },
        { name: "Notion", status: "needs-auth", scope: "claudeai", tools: [] },
      ],
      error: "Could not reconnect x: no",
    });
  });

  test("session_info names the login and counts the MCP servers by status", () => {
    const servers = (["needs-auth", "connected", "needs-auth", "pending"] as const).map((status, i) => ({
      name: `s${i}`,
      status,
    }));
    const team = { email: "a@b.c", organization: "Org", subscriptionType: "Claude Team", apiProvider: "firstParty" as const };
    expect(sessionInfoEvent("2.1.304", team, servers)).toEqual({
      type: "session_info",
      info: {
        version: "2.1.304",
        login: "Claude Team account",
        organization: "Org",
        email: "a@b.c",
        mcp: "1 connected · 2 need auth · 1 pending",
      },
    });
    expect(sessionInfoEvent(undefined, { apiKeySource: "ANTHROPIC_API_KEY" }, [])).toMatchObject({
      info: { login: "API key (ANTHROPIC_API_KEY)", mcp: "none" },
    });
  });
});
