import { describe, expect, test } from "bun:test";
import type { HookInput } from "@anthropic-ai/claude-agent-sdk";
import type { Event } from "./protocol";
import { PreviewBridge, TIMEOUT_MS } from "./preview";

const base = { session_id: "s", transcript_path: "/t", cwd: "/p", hook_event_name: "PreToolUse" };
const edit = { file_path: "/p/a.js", old_string: "a", new_string: "b", replace_all: false };
const mainInput = { ...base, tool_name: "Edit", tool_input: edit, tool_use_id: "t1" } as HookInput;
const agentInput = {
  ...base,
  agent_id: "af32",
  agent_type: "general-purpose",
  tool_name: "Edit",
  tool_input: edit,
  tool_use_id: "t2",
} as HookInput;

function bridge(timeouts = TIMEOUT_MS) {
  const sent: Event[] = [];
  return { b: new PreviewBridge((ev) => sent.push(ev), timeouts), sent };
}

// Whether the promise settled within ms.
async function within(p: Promise<unknown>, ms: number): Promise<boolean> {
  return Promise.race([p.then(() => true), Bun.sleep(ms).then(() => false)]);
}

describe("PreviewBridge", () => {
  test("holds an edit until the plugin answers", async () => {
    const { b, sent } = bridge();
    const signal = new AbortController().signal;
    const held = b.hook(mainInput, "t1", { signal });
    expect(sent).toEqual([{ type: "await_preview", req: 1, tool_use_id: "t1" }]);
    expect(await within(held, 20)).toBe(false);
    b.done(1);
    expect(await held).toEqual({});
    expect(b.waiting).toBe(0);
  });

  test("sends a subagent's agent, tool and whole input", async () => {
    const { b, sent } = bridge();
    const held = b.hook(agentInput, "t2", { signal: new AbortController().signal });
    expect(sent).toEqual([
      { type: "await_preview", req: 1, tool_use_id: "t2", agent_id: "af32", name: "Edit", input: edit },
    ]);
    b.done(1);
    await held;
  });

  test("gives a subagent's typed preview longer than the main agent's", async () => {
    const { b } = bridge({ main: 30, agent: 120 });
    const signal = new AbortController().signal;
    const main = b.hook(mainInput, "t1", { signal });
    const agent = b.hook(agentInput, "t2", { signal });
    expect(await within(main, 80)).toBe(true);
    expect(await within(agent, 1)).toBe(false);
    expect(await within(agent, 100)).toBe(true);
    expect(b.waiting).toBe(0);
    expect(TIMEOUT_MS.agent).toBeGreaterThan(TIMEOUT_MS.main);
  });

  test("lets go when Claude Code aborts, and ignores a late answer", async () => {
    const { b } = bridge();
    const abort = new AbortController();
    const held = b.hook(agentInput, "t2", { signal: abort.signal });
    abort.abort();
    expect(await within(held, 20)).toBe(true);
    b.done(1);
    expect(b.waiting).toBe(0);
  });

  test("passes a call without a tool id", async () => {
    const { b, sent } = bridge();
    expect(await b.hook(mainInput, undefined, { signal: new AbortController().signal })).toEqual({});
    expect(sent).toEqual([]);
  });
});
