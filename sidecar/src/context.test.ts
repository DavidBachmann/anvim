import { describe, expect, test } from "bun:test";
import type { HookInput, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { contextHook, contextText, PendingContexts } from "./context";
import { commandsEvent } from "./translate";

const MAYBE = "This may or may not be related to the current task.";

describe("contextText", () => {
  test("names the open file with the cursor and the visible lines", () => {
    expect(contextText({ file: "lua/a.lua", cursor_line: 42, visible: [20, 70] }, "/p")).toBe(
      `The user opened the file /p/lua/a.lua in the IDE. ${MAYBE}\n` +
        "The cursor is on line 42, and lines 20 to 70 are visible.",
    );
    expect(contextText({ file: "/elsewhere/b.lua" }, "/p")).toBe(
      `The user opened the file /elsewhere/b.lua in the IDE. ${MAYBE}`,
    );
  });

  test("gives a selection in Claude Code's words, without the cursor", () => {
    const ctx = {
      file: "a.lua",
      cursor_line: 13,
      visible: [1, 40] as [number, number],
      selection: { start_line: 12, end_line: 13, text: "local a = 1\nreturn a", mode: "line" as const },
    };
    expect(contextText(ctx, "/p")).toBe(
      `The user selected the lines 12 to 13 from /p/a.lua:\nlocal a = 1\nreturn a\n${MAYBE}`,
    );
  });

  test("cuts a long selection where Claude Code does, between characters", () => {
    const text = "é".repeat(2500);
    const out = contextText({ file: "a.lua", selection: { start_line: 1, end_line: 1, text, mode: "char" } }, "/p");
    expect(out).toContain(`${"é".repeat(2000)}\n... (truncated)\n${MAYBE}`);
    expect(out).not.toContain("é".repeat(2001));
  });

  test("says nothing without a file", () => {
    expect(contextText({}, "/p")).toBe("");
  });
});

describe("PendingContexts", () => {
  const ctx = (file: string) => ({ file });

  test("finds each prompt's context by its text, in order for equal texts", () => {
    const p = new PendingContexts();
    p.push("first", ctx("a"));
    p.push("again", ctx("b"));
    p.push("again", ctx("c"));
    expect(p.take("first")).toEqual(ctx("a"));
    expect(p.take("again")).toEqual(ctx("b"));
    expect(p.take("again")).toEqual(ctx("c"));
    expect(p.size).toBe(0);
  });

  test("drops prompts that went past the hook, and gives none for an unknown text", () => {
    const p = new PendingContexts();
    p.push("/compact", ctx("a"));
    p.push("what does this do?", ctx("b"));
    expect(p.take("expanded skill text")).toBeUndefined();
    expect(p.size).toBe(2);
    expect(p.take("what does this do?")).toEqual(ctx("b"));
    expect(p.size).toBe(0);
  });

  test("keeps a prompt sent during a turn, whose hook runs after that turn's result", () => {
    const p = new PendingContexts();
    p.push("count to 40", ctx("a"));
    p.turnStart();
    expect(p.take("count to 40")).toEqual(ctx("a"));
    p.push("say banana", ctx("b"));
    p.turnEnd();
    expect(p.take("say banana")).toEqual(ctx("b"));
    p.turnStart();
    p.turnEnd();
    expect(p.size).toBe(0);
  });

  test("drops prompts of a turn that ran no hook, so a prompt sent again gets its own context", () => {
    const p = new PendingContexts();
    p.push("/compact", ctx("old"));
    p.turnStart();
    p.push("/compact", ctx("queued"));
    p.turnEnd();
    expect(p.size).toBe(1);
    p.turnStart();
    p.turnEnd();
    expect(p.size).toBe(0);
    p.push("/compact", ctx("new"));
    expect(p.take("/compact")).toEqual(ctx("new"));
  });

  // Message shapes and order as Claude Code 2.1.304 sends them while two
  // background agents run.
  describe("turns of a session with background agents", () => {
    const msg = (m: object) => m as unknown as SDKMessage;
    const init = msg({ type: "system", subtype: "init", session_id: "s" });
    const main = msg({ type: "stream_event", event: { type: "message_start" }, parent_tool_use_id: null });
    const result = msg({ type: "result", subtype: "success", num_turns: 1 });
    const between = [
      msg({ type: "assistant", parent_tool_use_id: "toolu_A", agent_id: "a1", message: { content: [] } }),
      msg({ type: "user", parent_tool_use_id: "toolu_A", agent_id: "a1", message: { content: [] } }),
      msg({ type: "system", subtype: "task_progress", task_id: "a1", tool_use_id: "toolu_A" }),
      msg({ type: "system", subtype: "task_started", task_id: "b1", task_type: "local_bash" }),
      msg({ type: "system", subtype: "background_tasks_changed", tasks: [] }),
    ];
    const local = msg({ type: "user", parent_tool_use_id: null, message: { content: "<local-command-stdout>$0</local-command-stdout>" } });

    test("a subagent's messages between turns start no turn", () => {
      const p = new PendingContexts();
      p.push("launch two agents", ctx("a"));
      expect(p.take("launch two agents")).toEqual(ctx("a"));
      [init, main, result, ...between].forEach((m) => p.message(m));
      // A local command while the agents run: its turn starts with its output.
      p.push("/cost");
      [local, result].forEach((m) => p.message(m));
      expect(p.size).toBe(0);
    });

    test("a notification turn passes the hook and keeps a prompt sent meanwhile", () => {
      const p = new PendingContexts();
      [main, result, ...between].forEach((m) => p.message(m));
      p.push("what changed?", ctx("b"));
      expect(p.take("<task-notification>\n<task-id>a1</task-id>")).toBeUndefined();
      [init, main, result].forEach((m) => p.message(m));
      expect(p.take("what changed?")).toEqual(ctx("b"));
    });
  });

  test("keeps a bounded queue", () => {
    const p = new PendingContexts();
    for (let i = 0; i < 30; i++) p.push(`p${i}`, ctx(String(i)));
    expect(p.size).toBe(20);
    expect(p.take("p0")).toBeUndefined();
    expect(p.take("p29")).toEqual(ctx("29"));
  });
});

describe("contextHook", () => {
  const signal = new AbortController().signal;
  const input = (prompt: string) =>
    ({
      hook_event_name: "UserPromptSubmit",
      prompt,
      session_id: "s",
      transcript_path: "/t",
      cwd: "/p",
    }) as HookInput;

  test("adds the context of the prompt that it runs for", async () => {
    const p = new PendingContexts();
    p.push("what does this file do?", { file: "a.lua", cursor_line: 3 });
    p.push("no context");
    expect(await contextHook(p)(input("what does this file do?"), undefined, { signal })).toEqual({
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: `The user opened the file /p/a.lua in the IDE. ${MAYBE}\nThe cursor is on line 3.`,
      },
    });
    expect(await contextHook(p)(input("no context"), undefined, { signal })).toEqual({});
    expect(await contextHook(p)(input("never sent"), undefined, { signal })).toEqual({});
  });
});

describe("commandsEvent", () => {
  test("keeps names, descriptions and argument hints", () => {
    expect(
      commandsEvent([
        { name: "review", description: "Review a pull request", argumentHint: "<pr>" },
        { name: "compact", description: "Clear history but keep a summary", argumentHint: "" },
      ]),
    ).toEqual({
      type: "commands",
      commands: [
        { name: "review", description: "Review a pull request", argument_hint: "<pr>" },
        { name: "compact", description: "Clear history but keep a summary" },
      ],
    });
  });
});
