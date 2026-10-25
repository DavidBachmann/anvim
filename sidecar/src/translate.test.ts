import { describe, expect, test } from "bun:test";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import {
  contextEvent,
  limitsEvent,
  mainThread,
  mcpEvent,
  modelsEvent,
  sessionInfoEvent,
  Translator,
  usageEvent,
} from "./translate";

const se = (event: object, parent: string | null = null) =>
  ({ type: "stream_event", event, parent_tool_use_id: parent }) as unknown as SDKMessage;
const msg = (m: object) => m as unknown as SDKMessage;

function run(messages: SDKMessage[]): Event[] {
  const t = new Translator();
  return messages.flatMap((m) => t.translate(m));
}

describe("Translator", () => {
  test("streams an Edit tool call field by field", () => {
    const events = run([
      se({ type: "message_start" }),
      se({ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "t1", name: "Edit" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"file_path": "/a' } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '.lua", "new_string": "x\\ny"}' } }),
      msg({
        type: "assistant",
        parent_tool_use_id: null,
        message: { content: [{ type: "tool_use", id: "t1", name: "Edit", input: { file_path: "/a.lua", new_string: "x\ny" } }] },
      }),
      se({ type: "content_block_stop", index: 0 }),
    ]);
    expect(events).toEqual([
      { type: "turn_start" },
      { type: "tool_start", id: "t1", name: "Edit" },
      { type: "tool_field", id: "t1", name: "Edit", key: "file_path", phase: "start" },
      { type: "tool_field", id: "t1", name: "Edit", key: "file_path", phase: "delta", text: "/a" },
      { type: "tool_field", id: "t1", name: "Edit", key: "file_path", phase: "delta", text: ".lua" },
      { type: "tool_field", id: "t1", name: "Edit", key: "file_path", phase: "end", value: "/a.lua" },
      { type: "tool_field", id: "t1", name: "Edit", key: "new_string", phase: "start" },
      { type: "tool_field", id: "t1", name: "Edit", key: "new_string", phase: "delta", text: "x\ny" },
      { type: "tool_field", id: "t1", name: "Edit", key: "new_string", phase: "end", value: "x\ny" },
      { type: "tool_use", id: "t1", name: "Edit", input: { file_path: "/a.lua", new_string: "x\ny" }, parent_id: null },
      { type: "tool_input_end", id: "t1" },
    ]);
  });

  test("text, subagent events, tool results and turn end", () => {
    const events = run([
      se({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hi" } }),
      se({ type: "content_block_stop", index: 0 }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "sub" } }, "task1"),
      msg({
        type: "user",
        parent_tool_use_id: null,
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "ok" }] }] },
        tool_use_result: { filePath: "/a.lua", originalFile: "big", structuredPatch: [{ newStart: 3, newLines: 2 }] },
      }),
      msg({ type: "result", subtype: "success", is_error: false, duration_ms: 5, total_cost_usd: 0.01, num_turns: 1 }),
    ]);
    expect(events).toEqual([
      { type: "turn_start" },
      { type: "text_start" },
      { type: "text_delta", text: "Hi" },
      { type: "text_stop" },
      {
        type: "tool_result",
        id: "t1",
        is_error: false,
        text: "ok",
        result: { filePath: "/a.lua", structuredPatch: [{ newStart: 3, newLines: 2 }] },
        parent_id: null,
      },
      { type: "turn_end", subtype: "success", is_error: false, duration_ms: 5, cost_usd: 0.01, num_turns: 1 },
    ]);
  });

  // The message order of a /compact and a /clear, as Claude Code 2.1.304 sends them.
  test("compaction, its output, a /clear and a slash command's output", () => {
    const local = (text: string) =>
      msg({ type: "user", parent_tool_use_id: null, message: { role: "user", content: `<local-command-stdout>${text}</local-command-stdout>` } });
    const result = msg({ type: "result", subtype: "success", is_error: false, duration_ms: 1, total_cost_usd: 0, num_turns: 0 });
    const events = run([
      msg({ type: "system", subtype: "status", status: "compacting" }),
      msg({ type: "system", subtype: "status", status: null, compact_result: "success" }),
      msg({ type: "system", subtype: "compact_boundary", compact_metadata: { trigger: "manual", pre_tokens: 45065, post_tokens: 16912 } }),
      msg({ type: "user", parent_tool_use_id: null, isSynthetic: true, message: { role: "user", content: "This session is being continued" } }),
      local("Compacted "),
      result,
      msg({ type: "conversation_reset", new_conversation_id: "c1", trigger: "clear", session_id: "s1" }),
      result,
      local("Total cost: $0.01"),
      result,
    ]);
    const end: Event = { type: "turn_end", subtype: "success", is_error: false, duration_ms: 1, cost_usd: 0, num_turns: 0 };
    expect(events).toEqual([
      { type: "status", status: "compacting", permission_mode: undefined },
      { type: "status", status: null, permission_mode: undefined },
      { type: "compact", trigger: "manual", pre_tokens: 45065, post_tokens: 16912 },
      end,
      { type: "reset" },
      end,
      { type: "output", text: "Total cost: $0.01" },
      end,
    ]);
  });

  // Shapes as Claude Code 2.1.304 sends them for /usage and /effort: a
  // message of Claude Code's own, with no stream events.
  test("the output of a local slash command, which comes as a message of Claude Code's own", () => {
    const synthetic = (text: string, extra: object = {}) =>
      msg({
        type: "assistant",
        parent_tool_use_id: null,
        message: { model: "<synthetic>", role: "assistant", content: [{ type: "text", text }] },
        local_command_run: { command: "effort", args: "current" },
        ...extra,
      });
    const result = msg({ type: "result", subtype: "success", is_error: false, duration_ms: 1, total_cost_usd: 0, num_turns: 0 });
    const events = run([
      synthetic("Current effort level: low (Quick, straightforward implementation)"),
      result,
      msg({ type: "system", subtype: "local_command_output", content: "Voice mode is on\n" }),
      synthetic("A subagent's own", { parent_tool_use_id: "t1" }),
    ]);
    expect(events).toEqual([
      { type: "turn_start" },
      { type: "output", text: "Current effort level: low (Quick, straightforward implementation)" },
      { type: "turn_end", subtype: "success", is_error: false, duration_ms: 1, cost_usd: 0, num_turns: 0 },
      { type: "output", text: "Voice mode is on" },
    ]);
  });

  // As Claude Code sends it with ANTHROPIC_BASE_URL at a closed port.
  test("a synthetic API error shows its text, and its code only without one", () => {
    const failed = (content: object[], extra: object) =>
      msg({
        type: "assistant",
        parent_tool_use_id: null,
        message: { model: "<synthetic>", role: "assistant", content },
        is_api_error_message: true,
        ...extra,
      });
    const refused = "API Error: Connection refused - a firewall or proxy may be blocking it (ECONNREFUSED)";
    const events = run([
      failed([{ type: "text", text: refused }], { error: "server_error" }),
      failed([], { error: "server_error" }),
      failed([{ type: "text", text: "The model's tool call could not be parsed (retry also failed)." }], {}),
    ]);
    expect(events).toEqual([
      { type: "turn_start" },
      { type: "notice", level: "error", text: refused },
      { type: "notice", level: "error", text: "server_error" },
      { type: "notice", level: "error", text: "The model's tool call could not be parsed (retry also failed)." },
    ]);
  });

  test("a long command output, such as /context, ends at a line end", () => {
    const row = "| Messages | 1.2k tokens | 0.6% |";
    const text = Array.from({ length: 1000 }, () => row).join("\n");
    const [, output] = run([
      msg({
        type: "assistant",
        parent_tool_use_id: null,
        message: { model: "<synthetic>", role: "assistant", content: [{ type: "text", text }] },
      }),
    ]);
    const lines = (output as { text: string }).text.split("\n");
    expect(lines.at(-1)).toBe("...");
    expect(lines.slice(0, -1).every((line) => line === row)).toBe(true);
    expect(lines.length).toBeGreaterThan(500);
  });

  test("init names the commands that Claude Code binds to its terminal", () => {
    const init = (extra: object) =>
      msg({ type: "system", subtype: "init", session_id: "s", model: "m", slash_commands: ["color", "usage"], ...extra });
    const [withList, without] = run([init({ terminal_slash_commands: ["color"] }), init({})]);
    expect(withList).toMatchObject({ type: "init", slash_commands: ["color", "usage"], terminal_slash_commands: ["color"] });
    expect(without).not.toHaveProperty("terminal_slash_commands");
  });

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

  test("a prompt's lifecycle names the prompt by its uuid", () => {
    const frame = (state: string) => msg({ type: "command_lifecycle", command_uuid: "u1", state, uuid: "f", session_id: "s" });
    expect(run([frame("queued"), frame("started")])).toEqual([
      { type: "prompt_state", id: "u1", state: "queued" },
      { type: "prompt_state", id: "u1", state: "started" },
    ]);
  });

  test("a failed compaction is an error notice", () => {
    const events = run([msg({ type: "system", subtype: "status", status: null, compact_result: "failed", compact_error: "too short" })]);
    expect(events.at(-1)).toEqual({ type: "notice", level: "error", text: "Compaction failed: too short" });
  });

  // Shapes as Claude Code 2.1.304 sends them for a foreground subagent.
  test("a subagent's life and tool calls", () => {
    const agent = { parent_tool_use_id: "toolu_A", agent_id: "a1", subagent_type: "general-purpose", task_description: "Edit alpha.js" };
    const events = run([
      msg({
        type: "system",
        subtype: "task_started",
        task_id: "a1",
        run_id: "r1",
        tool_use_id: "toolu_A",
        description: "Edit alpha.js",
        subagent_type: "general-purpose",
        is_backgrounded: false,
        spawn_depth: 1,
        task_type: "local_agent",
        prompt: "Add a comment",
      }),
      msg({
        type: "system",
        subtype: "task_progress",
        task_id: "a1",
        tool_use_id: "toolu_A",
        description: "Editing alpha.js",
        usage: { total_tokens: 1200, tool_uses: 1, duration_ms: 900 },
        last_tool_name: "Edit",
      }),
      msg({
        type: "assistant",
        ...agent,
        message: { content: [{ type: "tool_use", id: "t1", name: "Edit", input: { file_path: "/alpha.js" } }] },
      }),
      msg({
        type: "user",
        ...agent,
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "updated" }] },
      }),
      msg({ type: "system", subtype: "task_updated", task_id: "a1", patch: { status: "completed", end_time: 1 } }),
      msg({
        type: "system",
        subtype: "task_notification",
        task_id: "a1",
        tool_use_id: "toolu_A",
        status: "completed",
        output_file: "/tmp/a1.output",
        summary: "Added a comment",
      }),
    ]);
    expect(events).toEqual([
      {
        type: "agent_start",
        agent_id: "a1",
        tool_use_id: "toolu_A",
        description: "Edit alpha.js",
        subagent_type: "general-purpose",
        depth: 1,
        background: false,
      },
      { type: "agent_progress", agent_id: "a1", description: "Editing alpha.js", tool_uses: 1, tokens: 1200, last_tool: "Edit" },
      { type: "tool_use", id: "t1", name: "Edit", input: { file_path: "/alpha.js" }, parent_id: "toolu_A", agent_id: "a1" },
      { type: "tool_result", id: "t1", is_error: false, text: "updated", result: undefined, parent_id: "toolu_A", agent_id: "a1" },
      { type: "agent_end", agent_id: "a1", tool_use_id: "toolu_A", status: "completed", summary: "Added a comment" },
    ]);
  });

  // Usage as Claude Code 2.1.304 sends it for a haiku subagent. The result's
  // window differs from the main agent's, to show the second event.
  test("a subagent's context comes from its responses' usage and its model's window", () => {
    const t = new Translator();
    t.defaultWindow = 1_000_000;
    const usage = { input_tokens: 2, cache_creation_input_tokens: 23148, cache_read_input_tokens: 0, output_tokens: 4 };
    const events = [
      msg({
        type: "assistant",
        parent_tool_use_id: "toolu_A",
        agent_id: "a1",
        message: { model: "claude-haiku-5-5", usage, content: [{ type: "text", text: "ok" }] },
      }),
      msg({ type: "result", subtype: "success", modelUsage: { "claude-haiku-5-5": { contextWindow: 200_000 } } }),
    ]
      .flatMap((m) => t.translate(m))
      .filter((e) => e.type === "agent_context");
    expect(events).toEqual([
      { type: "agent_context", agent_id: "a1", tokens: 23154, max: 1_000_000, percent: 2 },
      { type: "agent_context", agent_id: "a1", tokens: 23154, max: 200_000, percent: 12 },
    ]);
  });

  test("a subagent's text comes as whole blocks, with a cap", () => {
    const agent = { parent_tool_use_id: "toolu_A", agent_id: "a1" };
    const said = (content: object[]) => msg({ type: "assistant", ...agent, message: { content } });
    const long = "x".repeat(7999) + "😀" + "y";
    const events = run([
      said([{ type: "text", text: "It has 3 lines." }]),
      said([{ type: "text", text: long }]),
    ]);
    expect(events).toEqual([
      { type: "agent_text", agent_id: "a1", parent_id: "toolu_A", text: "It has 3 lines." },
      // The cut falls inside the emoji's surrogate pair, so the emoji goes whole.
      { type: "agent_text", agent_id: "a1", parent_id: "toolu_A", text: "x".repeat(7999) + "..." },
    ]);
  });

  test("the main agent's text streams, and its whole message adds no agent_text", () => {
    const events = run([
      se({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hi" } }),
      se({ type: "content_block_stop", index: 0 }),
      msg({ type: "assistant", parent_tool_use_id: null, message: { content: [{ type: "text", text: "Hi" }] } }),
    ]);
    expect(events.map((e) => e.type)).toEqual(["turn_start", "text_start", "text_delta", "text_stop"]);
  });

  test("a subagent's text after the turn's result starts no turn", () => {
    const events = run([
      msg({ type: "result", subtype: "success", is_error: false, duration_ms: 5, total_cost_usd: 0, num_turns: 1 }),
      msg({ type: "assistant", parent_tool_use_id: "toolu_A", agent_id: "a1", message: { content: [{ type: "text", text: "Done." }] } }),
    ]);
    expect(events.map((e) => e.type)).toEqual(["turn_end", "agent_text"]);
  });

  test("a subagent's Read result counts its lines before the cut, and other results get none", () => {
    const agent = { parent_tool_use_id: "toolu_A", agent_id: "a1" };
    const lines = Array.from({ length: 60 }, (_, i) => `${String(i + 1).padStart(6)}\tlocal x${i} = "${"v".repeat(40)}"`);
    const text = lines.join("\n");
    expect(text.length).toBeGreaterThan(2000);
    const call = (id: string, name: string) =>
      msg({ type: "assistant", ...agent, message: { content: [{ type: "tool_use", id, name, input: {} }] } });
    const result = (id: string, content: string) =>
      msg({ type: "user", ...agent, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content }] } });
    const events = run([call("r1", "Read"), call("b1", "Bash"), result("r1", text), result("b1", "1\tnot a Read"), result("r1", text)]);
    const results = events.filter((e) => e.type === "tool_result") as Extract<Event, { type: "tool_result" }>[];
    expect(results.map((e) => e.result)).toEqual([{ file: { numLines: 60 } }, undefined, undefined]);
    expect(results[0]!.text.length).toBe(2003);
  });

  test("the main agent's Read result keeps its own tool_use_result", () => {
    const file = { filePath: "/p/matchparen.lua", numLines: 319, startLine: 1, totalLines: 319 };
    const events = run([
      msg({
        type: "assistant",
        parent_tool_use_id: null,
        message: { content: [{ type: "tool_use", id: "r1", name: "Read", input: { file_path: "/p/matchparen.lua" } }] },
      }),
      msg({
        type: "user",
        parent_tool_use_id: null,
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: "r1", content: "1\tlocal M = {}\n2\treturn M" }] },
        tool_use_result: { type: "text", file },
      }),
    ]);
    expect(events.find((e) => e.type === "tool_result")).toMatchObject({ result: { type: "text", file } });
  });

  // Shapes and order as Claude Code 2.1.304 sends them for a background
  // subagent: the Agent call returns at once, the main turn ends, the agent
  // works on, and its end starts a turn of its own.
  test("a background agent works between turns, and its end starts a turn", () => {
    const agent = { parent_tool_use_id: "toolu_F", agent_id: "f1", subagent_type: "general-purpose" };
    const result = msg({ type: "result", subtype: "success", is_error: false, duration_ms: 5, total_cost_usd: 0, num_turns: 1 });
    const t = new Translator();
    const launch = [
      se({ type: "message_start" }),
      msg({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "f1", task_type: "local_agent" }] }),
      msg({
        type: "system",
        subtype: "task_started",
        task_id: "f1",
        tool_use_id: "toolu_F",
        description: "Add FAST line",
        subagent_type: "general-purpose",
        is_backgrounded: true,
        spawn_depth: 1,
        task_type: "local_agent",
      }),
      msg({
        type: "user",
        parent_tool_use_id: null,
        message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_F", content: "Async agent launched successfully." }] },
        tool_use_result: { isAsync: true, status: "async_launched", agentId: "f1", description: "Add FAST line" },
      }),
      result,
    ];
    expect(launch.flatMap((m) => t.translate(m))).toEqual([
      { type: "turn_start" },
      {
        type: "agent_start",
        agent_id: "f1",
        tool_use_id: "toolu_F",
        description: "Add FAST line",
        subagent_type: "general-purpose",
        depth: 1,
        background: true,
      },
      {
        type: "tool_result",
        id: "toolu_F",
        is_error: false,
        text: "Async agent launched successfully.",
        result: { isAsync: true, status: "async_launched", agentId: "f1", description: "Add FAST line" },
        parent_id: null,
      },
      { type: "turn_end", subtype: "success", is_error: false, duration_ms: 5, cost_usd: 0, num_turns: 1 },
    ]);
    const between = [
      msg({ type: "system", subtype: "task_progress", task_id: "f1", description: "Editing alpha.js", usage: { total_tokens: 900, tool_uses: 2 } }),
      msg({ type: "assistant", ...agent, message: { content: [{ type: "thinking", thinking: "Now the edit." }] } }),
      msg({ type: "assistant", ...agent, message: { content: [{ type: "tool_use", id: "e1", name: "Edit", input: { file_path: "/alpha.js" } }] } }),
      msg({ type: "user", ...agent, message: { role: "user", content: [{ type: "tool_result", tool_use_id: "e1", content: "updated" }] } }),
      msg({ type: "assistant", ...agent, message: { content: [{ type: "text", text: "Done: alpha.js starts with // FAST." }] } }),
      msg({ type: "system", subtype: "task_updated", task_id: "f1", patch: { status: "completed", end_time: 1 } }),
      msg({
        type: "system",
        subtype: "task_notification",
        task_id: "f1",
        tool_use_id: "toolu_F",
        status: "completed",
        output_file: "/tmp/f1.output",
        summary: "Done: alpha.js starts with // FAST.",
        usage: { total_tokens: 16071, tool_uses: 3, duration_ms: 10442 },
      }),
      msg({ type: "system", subtype: "background_tasks_changed", tasks: [] }),
    ];
    expect(between.flatMap((m) => t.translate(m))).toEqual([
      { type: "agent_progress", agent_id: "f1", description: "Editing alpha.js", tool_uses: 2, tokens: 900, last_tool: undefined },
      { type: "tool_use", id: "e1", name: "Edit", input: { file_path: "/alpha.js" }, parent_id: "toolu_F", agent_id: "f1" },
      { type: "tool_result", id: "e1", is_error: false, text: "updated", result: undefined, parent_id: "toolu_F", agent_id: "f1" },
      { type: "agent_text", agent_id: "f1", parent_id: "toolu_F", text: "Done: alpha.js starts with // FAST." },
      {
        type: "agent_end",
        agent_id: "f1",
        tool_use_id: "toolu_F",
        status: "completed",
        summary: "Done: alpha.js starts with // FAST.",
        tool_uses: 3,
        tokens: 16071,
        duration_ms: 10442,
      },
    ]);
    const notified = [
      msg({ type: "system", subtype: "init", session_id: "s1", model: "claude-haiku-5-5", cwd: "/p", permissionMode: "default" }),
      msg({ type: "system", subtype: "status", status: "requesting" }),
      se({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }),
      se({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "FAST finished." } }),
      se({ type: "content_block_stop", index: 0 }),
      result,
    ];
    expect(notified.flatMap((m) => t.translate(m)).map((e) => e.type)).toEqual([
      "init",
      "status",
      "turn_start",
      "text_start",
      "text_delta",
      "text_stop",
      "turn_end",
    ]);
  });

  test("only the main agent's own messages are of the main thread", () => {
    expect(mainThread(se({ type: "message_start" }))).toBe(true);
    expect(mainThread(msg({ type: "system", subtype: "init" }))).toBe(true);
    expect(mainThread(msg({ type: "user", parent_tool_use_id: null, message: { content: "hi" } }))).toBe(true);
    expect(mainThread(msg({ type: "assistant", parent_tool_use_id: "toolu_A", agent_id: "a1" }))).toBe(false);
    expect(mainThread(msg({ type: "system", subtype: "task_notification", task_id: "a1" }))).toBe(false);
    expect(mainThread(msg({ type: "system", subtype: "background_tasks_changed", tasks: [] }))).toBe(false);
  });

  test("a nested subagent names its parent, and other tasks send no agent events", () => {
    const events = run([
      msg({
        type: "system",
        subtype: "task_started",
        task_id: "c1",
        tool_use_id: "toolu_C",
        description: "Edit beta.js",
        subagent_type: "general-purpose",
        is_backgrounded: true,
        spawn_depth: 2,
        parent_task_id: "b1",
        task_type: "local_agent",
      }),
      msg({ type: "system", subtype: "task_started", task_id: "s1", tool_use_id: "toolu_S", description: "npm test", task_type: "local_bash" }),
      msg({
        type: "system",
        subtype: "task_started",
        task_id: "m1",
        tool_use_id: "toolu_M",
        description: "memory",
        task_type: "local_agent",
        ambient: true,
      }),
      msg({ type: "system", subtype: "task_progress", task_id: "s1", description: "Running", usage: { total_tokens: 0, tool_uses: 0 } }),
      msg({ type: "system", subtype: "task_notification", task_id: "s1", status: "completed", output_file: "", summary: "" }),
      msg({ type: "system", subtype: "task_notification", task_id: "c1", status: "stopped", output_file: "", summary: "" }),
      msg({ type: "system", subtype: "task_notification", task_id: "c1", status: "stopped", output_file: "", summary: "" }),
    ]);
    expect(events).toEqual([
      {
        type: "agent_start",
        agent_id: "c1",
        tool_use_id: "toolu_C",
        description: "Edit beta.js",
        subagent_type: "general-purpose",
        parent_agent_id: "b1",
        depth: 2,
        background: true,
      },
      { type: "agent_end", agent_id: "c1", status: "stopped" },
    ]);
  });

  test("a background agent that leaves the task list ends, also without its notification", () => {
    const started = (id: string, background: boolean) =>
      msg({
        type: "system",
        subtype: "task_started",
        task_id: id,
        tool_use_id: `toolu_${id}`,
        description: id,
        is_backgrounded: background,
        task_type: "local_agent",
      });
    const tasks = (...ids: string[]) =>
      msg({ type: "system", subtype: "background_tasks_changed", tasks: ids.map((task_id) => ({ task_id })) });
    const ends = run([
      tasks("b1"),
      started("b1", true),
      tasks("b1", "b2"),
      started("b2", true),
      started("f1", false),
      msg({ type: "system", subtype: "task_notification", task_id: "b1", status: "completed", output_file: "", summary: "" }),
      tasks("b2"),
      tasks(),
      tasks(),
    ]).filter((e) => e.type === "agent_end");
    expect(ends).toEqual([
      { type: "agent_end", agent_id: "b1", status: "completed" },
      { type: "agent_end", agent_id: "b2", status: "completed" },
    ]);
  });

  test("a foreground agent that goes to the background says so once, and ends when it leaves the task list", () => {
    const moved = msg({ type: "system", subtype: "task_updated", task_id: "f1", patch: { is_backgrounded: true } });
    const events = run([
      msg({ type: "system", subtype: "task_started", task_id: "f1", tool_use_id: "toolu_F", description: "f1", task_type: "local_agent" }),
      msg({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "f1" }] }),
      moved,
      moved,
      msg({ type: "system", subtype: "task_updated", task_id: "f1", patch: { status: "completed" } }),
      msg({ type: "system", subtype: "background_tasks_changed", tasks: [] }),
    ]).filter((e) => e.type !== "agent_start");
    expect(events).toEqual([
      { type: "agent_background", agent_id: "f1" },
      { type: "agent_end", agent_id: "f1", status: "completed" },
    ]);
  });

  test("message_stop closes a cut tool call", () => {
    const events = run([
      se({ type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "t2", name: "Write" } }),
      se({ type: "message_stop" }),
    ]);
    expect(events.at(-1)).toEqual({ type: "tool_input_end", id: "t2" });
  });
});
