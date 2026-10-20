import { describe, expect, test } from "bun:test";
import type { HookInput } from "@anthropic-ai/claude-agent-sdk";
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
