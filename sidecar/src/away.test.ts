import { describe, expect, test } from "bun:test";
import type { HookInput, PermissionResult, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { AWAY_OFF, AWAY_ON, heldText, QUESTION } from "./away";
import { PermissionBridge } from "./permissions";
import type { Event } from "./protocol";
import { REASONS, SandboxGuard } from "./sandbox";

const cwd = "/work/project";
const escape = { command: "npm i -g x", dangerouslyDisableSandbox: true };

function setup() {
  const sent: Event[] = [];
  const log: string[] = [];
  // The test fires a timer by hand.
  const timers: { fn: () => void; ms: number; cleared: boolean }[] = [];
  const bridge = new PermissionBridge(
    (ev) => sent.push(ev),
    (fn, ms) => {
      const t = { fn, ms, cleared: false };
      timers.push(t);
      return () => (t.cleared = true);
    },
  );
  const guard = new SandboxGuard({
    cwd,
    home: "/home/u",
    tmpDir: "/tmp/claude-1",
    settings: async () => ({}),
    prompt: (tool, input, opts) => bridge.canUseTool(tool, input, { ...opts, requestId: "anvim-guard" }),
  });
  bridge.useGuard(guard, (line) => log.push(line));
  let next = 0;
  const ask = (tool: string, input: Record<string, unknown>, agentID?: string) => {
    const controller = new AbortController();
    const result = bridge.canUseTool(tool, input, {
      signal: controller.signal,
      toolUseID: `toolu_${++next}`,
      requestId: "r",
      agentID,
    }) as Promise<PermissionResult>;
    return { result, controller };
  };
  // A Bash call in bypass mode, which the guard's hook decides.
  const bypass = (tool_input: Record<string, unknown>, agent_id?: string) => {
    const id = `toolu_${++next}`;
    return guard.bash(
      {
        session_id: "s",
        transcript_path: "/t",
        cwd,
        hook_event_name: "PreToolUse",
        permission_mode: "bypassPermissions",
        agent_id,
        tool_name: "Bash",
        tool_input,
        tool_use_id: id,
      } as HookInput,
      id,
      { signal: new AbortController().signal },
    ) as Promise<any>;
  };
  const of = <T extends Event["type"]>(type: T) =>
    sent.filter((e) => e.type === type) as Extract<Event, { type: T }>[];
  return { bridge, sent, log, timers, ask, bypass, of };
}

const questions = {
  questions: [{ question: "Which name?", header: "Name", multiSelect: false, options: [{ label: "A" }] }],
};

describe("away mode", () => {
  test("holds the main agent's guarded call, and denies a question with the text to answer itself", async () => {
    const { bridge, bypass, ask, of, log } = setup();
    bridge.setAway(true);
    const text = heldText(REASONS.escape, true);
    expect(await bypass(escape)).toMatchObject({
      hookSpecificOutput: { permissionDecision: "deny", permissionDecisionReason: text },
    });
    expect(await ask("AskUserQuestion", questions).result).toEqual({ behavior: "deny", message: QUESTION });
    // A request that no guard asked about is held too.
    const other = await ask("Bash", { command: "make" }).result;
    expect(other.behavior).toBe("deny");
    // Two fetches of different URLs must not group as one row.
    await ask("WebFetch", { url: "https://a.example", prompt: "Sum it up" }).result;
    expect(of("permission_request")).toHaveLength(0);
    expect(of("send_back")).toHaveLength(0);
    expect(of("held").map((e) => [e.agent_id, e.tool, e.target, e.reason, e.away])).toEqual([
      [undefined, "Bash", "npm i -g x", REASONS.escape, true],
      [undefined, "AskUserQuestion", "Which name?", "a question", true],
      [undefined, "Bash", "make", "would ask the user", true],
      [undefined, "WebFetch", "https://a.example", "would ask the user", true],
    ]);
    expect(log[0]).toBe("held: main Bash runs outside the sandbox: npm i -g x");
  });

  test("turning on answers the open requests, except a plan's approval", async () => {
    const { bridge, ask, of } = setup();
    const command = ask("Bash", { command: "make" });
    const question = ask("AskUserQuestion", questions);
    const plan = ask("ExitPlanMode", { plan: "# Plan" });
    expect(of("permission_request").map((e) => e.req)).toEqual([1, 2, 3]);
    bridge.setAway(true);
    expect((await command.result).behavior).toBe("deny");
    expect(await question.result).toEqual({ behavior: "deny", message: QUESTION });
    expect(of("permission_cancel").map((e) => e.req)).toEqual([1, 2]);
    expect(of("held")).toHaveLength(2);
    expect(bridge.waiting).toBe(1);
    // A plan asks while away too.
    ask("ExitPlanMode", { plan: "# Other" });
    expect(bridge.waiting).toBe(2);
    bridge.respond({ type: "permission_response", req: 3, behavior: "allow", mode: "default" });
    expect((await plan.result).behavior).toBe("allow");
  });

  test("a request that waits turns away on, and an answer or a cancel clears its timer", async () => {
    const { bridge, ask, timers, of } = setup();
    bridge.awayAfterMs = 10 * 60_000;
    ask("Bash", { command: "a" });
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow" });
    ask("Bash", { command: "b" }).controller.abort();
    expect(timers.map((t) => [t.ms, t.cleared])).toEqual([
      [600_000, true],
      [600_000, true],
    ]);
    const waits = ask("Bash", { command: "c" });
    timers[2]!.fn();
    expect(bridge.away).toBe(true);
    expect(of("away")).toEqual([{ type: "away", away: true, after: 10 }]);
    expect((await waits.result).behavior).toBe("deny");
    expect(of("held")).toMatchObject([{ target: "c", away: true }]);
    // While away, no request starts a timer.
    ask("ExitPlanMode", { plan: "# Plan" });
    expect(timers).toHaveLength(3);
  });

  test("the main agent hears each switch once, with its next tool call or prompt", async () => {
    const { bridge } = setup();
    const tool = (agent_id?: string) =>
      bridge.notice.preToolUse({ hook_event_name: "PreToolUse", agent_id } as HookInput, "t", {
        signal: new AbortController().signal,
      });
    const prompt = () =>
      bridge.notice.prompt({ hook_event_name: "UserPromptSubmit" } as HookInput, undefined, {
        signal: new AbortController().signal,
      });
    const context = (out: unknown) =>
      (out as { hookSpecificOutput?: { additionalContext?: string } }).hookSpecificOutput?.additionalContext;
    expect(await tool()).toEqual({});
    bridge.setAway(true);
    expect(context(await tool("a1"))).toBeUndefined();
    expect(context(await tool())).toBe(AWAY_ON);
    expect(context(await prompt())).toBeUndefined();
    bridge.setAway(false);
    expect(context(await prompt())).toBe(AWAY_OFF);
    expect(context(await tool())).toBeUndefined();
    // On and off again before a call: nothing changed for Claude.
    bridge.setAway(true);
    bridge.setAway(false);
    expect(await tool()).toEqual({});
    // /clear starts a conversation that has not heard it.
    bridge.setAway(true);
    expect(context(await tool())).toBe(AWAY_ON);
    bridge.message({ type: "conversation_reset" } as unknown as SDKMessage);
    expect(context(await prompt())).toBe(AWAY_ON);
  });
});
