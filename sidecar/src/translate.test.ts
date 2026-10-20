import { describe, expect, test } from "bun:test";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import { mainThread, Translator } from "./translate";

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

  test("message_stop closes a cut tool call", () => {
    const events = run([
      se({ type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "t2", name: "Write" } }),
      se({ type: "message_stop" }),
    ]);
    expect(events.at(-1)).toEqual({ type: "tool_input_end", id: "t2" });
  });
});
