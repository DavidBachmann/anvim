import { describe, expect, test } from "bun:test";
import type { HookInput, Query } from "@anthropic-ai/claude-agent-sdk";
import { HELD, NEXT_TURN, postToolUse } from "./agentfiles";

const signal = new AbortController().signal;

function hook(held = false) {
  const reloads: unknown[] = [];
  const session = {
    reloadPlugins: async (opts: unknown) => {
      reloads.push(opts);
      return { agents: [], held };
    },
  } as unknown as Query;
  const [matcher] = postToolUse(() => session, "/p", "/home/.claude");
  const run = (file_path: string, tool_name = "Write") =>
    matcher!.hooks[0]!(
      {
        session_id: "s",
        transcript_path: "/t",
        cwd: "/p",
        hook_event_name: "PostToolUse",
        tool_name,
        tool_input: { file_path, content: "x" },
        tool_response: {},
        tool_use_id: "t1",
      } as HookInput,
      "t1",
      { signal },
    );
  return { run, reloads, matcher: matcher! };
}

const context = (out: unknown) => (out as { hookSpecificOutput?: { additionalContext?: string } }).hookSpecificOutput?.additionalContext;

describe("postToolUse", () => {
  test("reloads the agents after a write to an agent file, also in a new folder", async () => {
    const { run, reloads, matcher } = hook();
    expect(matcher.matcher).toBe("Write|Edit");
    expect(context(await run("/p/.claude/agents/dev.md"))).toBe(NEXT_TURN);
    expect(context(await run("/home/.claude/agents/team/dev.md", "Edit"))).toBe(NEXT_TURN);
    expect(reloads).toEqual([{ holdOnCacheImpact: true }, { holdOnCacheImpact: true }]);
  });

  test("leaves other files alone", async () => {
    const { run, reloads } = hook();
    for (const path of ["/p/src/a.md", "/p/.claude/agents/notes.txt", "/elsewhere/.claude/agents/dev.md"]) {
      expect(await run(path)).toEqual({});
    }
    expect(reloads).toEqual([]);
  });

  test("tells Claude to ask for /reload-plugins when the reload is held", async () => {
    const { run } = hook(true);
    expect(context(await run("/p/.claude/agents/dev.md"))).toBe(HELD);
  });
});
