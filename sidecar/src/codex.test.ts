import { describe, expect, test } from "bun:test";
import type { SessionMessage } from "@anthropic-ai/claude-agent-sdk";
import { CodexStream, codexState, unwrapShell } from "./codex";
import { historyEvents } from "./sessions";

// As codex-cli 0.164.0 printed it for `codex exec --json`. The error item is
// a wrapper's warning, not a failure.
const recording = `
{"type":"thread.started","thread_id":"01a17317-c271-71b0-a36b-379525be2574"}
{"type":"item.completed","item":{"id":"item_0","type":"error","message":"\`--dangerously-bypass-hook-trust\` is enabled."}}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I'll read notes.txt, then change \`b\` to \`B\`.\\n"}}
{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat notes.txt'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'cat notes.txt'","aggregated_output":"a\\nb\\n","exit_code":0,"status":"completed"}}
{"type":"item.started","item":{"id":"item_4","type":"file_change","changes":[{"path":"/work/notes.txt","kind":"update"}],"status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_4","type":"file_change","changes":[{"path":"/work/notes.txt","kind":"update"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"done"}}
{"type":"turn.completed","usage":{"input_tokens":71005,"cached_input_tokens":54144,"cache_write_input_tokens":0,"output_tokens":118,"reasoning_output_tokens":0}}
`;

const agent = { agent_id: "codex-1", parent_id: "toolu_1" };

describe("CodexStream", () => {
  test("turns a Codex run into the events of a subagent", () => {
    const stream = new CodexStream("codex-1", "toolu_1", "/work");
    const events = recording
      .trim()
      .split("\n")
      .flatMap((line) => stream.line(line));
    expect(events).toEqual([
      { type: "agent_text", ...agent, text: "I'll read notes.txt, then change `b` to `B`.\n" },
      { type: "agent_progress", agent_id: "codex-1", description: "Running cat notes.txt", tool_uses: 1, last_tool: "Bash" },
      { type: "tool_use", id: "codex-1:item_3", name: "Bash", input: { command: "cat notes.txt" }, ...agent },
      { type: "tool_result", id: "codex-1:item_3", is_error: false, text: "a\nb\n", ...agent },
      { type: "agent_progress", agent_id: "codex-1", description: "Editing notes.txt", tool_uses: 2, last_tool: "Edit" },
      { type: "tool_use", id: "codex-1:item_4:0", name: "Edit", input: { file_path: "/work/notes.txt" }, ...agent },
      { type: "tool_result", id: "codex-1:item_4:0", is_error: false, text: "Updated notes.txt", ...agent },
      { type: "agent_text", ...agent, text: "done" },
      { type: "agent_context", agent_id: "codex-1", tokens: 71123 },
    ]);
    const end = stream.end({ description: "Change b to B", code: 0, stderr: "", durationMs: 9000 });
    expect(end.event).toEqual({
      type: "agent_end",
      agent_id: "codex-1",
      tool_use_id: "toolu_1",
      status: "completed",
      summary: "done",
      tool_uses: 2,
      tokens: 71123,
      duration_ms: 9000,
    });
    // A resumed session draws the saved notification as the agent's end.
    const saved = {
      type: "user",
      uuid: "u",
      session_id: "s",
      parent_tool_use_id: null,
      message: { role: "user", content: end.notification },
    } as unknown as SessionMessage;
    expect(historyEvents([saved])).toEqual([{ ...end.event, description: "Change b to B" } as typeof end.event]);
  });

  test("a failed run ends with the tail of stderr", () => {
    const stream = new CodexStream("codex-2", "toolu_2", "/work");
    const end = stream.end({ description: "Fix it", code: 1, stderr: "Error: not logged in\n", durationMs: 10 });
    expect(end.event).toMatchObject({ status: "failed", summary: "Codex exited with code 1.\nError: not logged in" });
    expect(end.notification).toContain("<status>failed</status>");
  });

  test("unwraps the shell that Codex runs each command in", () => {
    expect(unwrapShell("/bin/zsh -lc 'cat notes.txt'")).toBe("cat notes.txt");
    expect(unwrapShell(`/bin/bash -lc 'echo '"'"'hi'"'"''`)).toBe("echo 'hi'");
    expect(unwrapShell(`/bin/zsh -lc "grep -n \\"x\\" a.ts"`)).toBe('grep -n "x" a.ts');
    expect(unwrapShell("ls -la")).toBe("ls -la");
  });
});

describe("codexState", () => {
  test("offers the codex tool only when it is wanted, installed and logged in", async () => {
    const which = (bin: string | null) => () => bin;
    const login = (ok: boolean) => async () => ok;
    expect(await codexState(false, which("/bin/codex"), login(true))).toEqual({ state: "off" });
    expect(await codexState(true, which(null), login(true))).toEqual({ state: "missing" });
    expect(await codexState(true, which("/bin/codex"), login(false))).toEqual({ state: "logged_out" });
    expect(await codexState(true, which("/bin/codex"), login(true))).toEqual({ state: "on", bin: "/bin/codex" });
  });
});
