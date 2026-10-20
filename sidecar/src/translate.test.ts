import { describe, expect, test } from "bun:test";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import { Translator } from "./translate";

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

  test("message_stop closes a cut tool call", () => {
    const events = run([
      se({ type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "t2", name: "Write" } }),
      se({ type: "message_stop" }),
    ]);
    expect(events.at(-1)).toEqual({ type: "tool_input_end", id: "t2" });
  });
});
