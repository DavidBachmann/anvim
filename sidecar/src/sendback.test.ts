import { describe, expect, test } from "bun:test";
import type { HookInput, PermissionResult, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CANCELLED, PermissionBridge } from "./permissions";
import type { Event } from "./protocol";
import { REASONS, SandboxGuard } from "./sandbox";
import { hint } from "./sendback";

const root = realpathSync(mkdtempSync(join(tmpdir(), "anvim-sendback-")));
// Not the real /tmp/claude-<uid>: in Claude's own sandbox, tmpdir() lies in
// it, and the guard would trust the whole fixture.
const TMP = join(root, "claude-tmp");
const cwd = join(root, "project");
const home = join(root, "home");
mkdirSync(cwd);
mkdirSync(home);
process.on("exit", () => rmSync(root, { recursive: true, force: true }));

// A bridge with a real guard, as main.ts wires them: in bypass mode the guard
// asks through canUseTool.
function setup(settings: object = {}) {
  const sent: Event[] = [];
  const log: string[] = [];
  const bridge = new PermissionBridge((ev) => sent.push(ev));
  const guard = new SandboxGuard({
    cwd,
    home,
    configDir: join(home, ".claude"),
    tmpDir: TMP,
    platform: "darwin",
    settings: async () => settings,
    prompt: (tool, input, opts) => bridge.canUseTool(tool, input, { ...opts, requestId: "anvim-guard" }),
  });
  bridge.useGuard(guard, (line) => log.push(line));
  let next = 0;
  // A tool call in bypass mode: the guard's hook decides it.
  const bypass = (tool_name: string, tool_input: Record<string, unknown>, agent_id?: string) => {
    const id = `toolu_${++next}`;
    const input = { session_id: "s", transcript_path: "/t", cwd, hook_event_name: "PreToolUse" };
    const hook = tool_name === "Bash" ? guard.bash : guard.edit;
    const out = hook(
      { ...input, permission_mode: "bypassPermissions", agent_id, tool_name, tool_input, tool_use_id: id } as HookInput,
      id,
      { signal: new AbortController().signal },
    );
    return { id, out: out as Promise<any> };
  };
  // A tool call in default mode: the hook asks, then Claude Code calls canUseTool.
  const ask = async (tool_name: string, tool_input: Record<string, unknown>, agent_id?: string) => {
    const id = `toolu_${++next}`;
    const input = { session_id: "s", transcript_path: "/t", cwd, hook_event_name: "PreToolUse" };
    const hook = tool_name === "Bash" ? guard.bash : guard.edit;
    const out = (await hook(
      { ...input, permission_mode: "default", agent_id, tool_name, tool_input, tool_use_id: id } as HookInput,
      id,
      { signal: new AbortController().signal },
    )) as any;
    const result = out.hookSpecificOutput
      ? (bridge.canUseTool(tool_name, tool_input, {
          signal: new AbortController().signal,
          toolUseID: id,
          requestId: "r",
          agentID: agent_id,
          decisionReason: out.hookSpecificOutput.permissionDecisionReason,
        }) as Promise<PermissionResult>)
      : undefined;
    return { id, out, result };
  };
  const requests = () => sent.filter((e) => e.type === "permission_request");
  const sendBacks = () => sent.filter((e) => e.type === "send_back");
  return { bridge, guard, sent, log, bypass, ask, requests, sendBacks };
}

const escape = { command: "npm i -g x", dangerouslyDisableSandbox: true };

function words(text: string): number {
  return text.split(/\s+/).filter(Boolean).length;
}

describe("the send-back hints", () => {
  test("say that anvim has not asked the user yet, and how to get the user's answer", () => {
    const reasons = [REASONS.escape, REASONS.excluded, REASONS.settings, REASONS.config, REASONS.outside("~/x")];
    const hints = reasons.map((r) => hint(r, TMP));
    for (const h of hints) {
      expect(h).toStartWith("anvim held this ");
      expect(h).toContain("has not asked the user yet");
      expect(h).toEndWith("send the same call again, and anvim asks the user.");
      expect(words(h)).toBeLessThanOrEqual(80);
    }
    expect(new Set(hints).size).toBe(5);
    expect(hints[0]).toContain("$TMPDIR");
    expect(hints[0]).toContain("npm, bun and go caches, and in dirs that the settings allow");
    expect(hints[1]).toContain("exclude this command from the sandbox, so it can run outside the sandbox");
    expect(hints[2]).toContain("Claude Code's settings");
    expect(hints[3]).toContain("git hooks or shell startup files");
    // Each hint names a way that needs no prompt.
    for (const h of hints.slice(2, 4)) expect(h).toContain("If the task does not need this change, go on without it");
    expect(hints[4]).toContain(`the sandbox's temp dir, ${TMP}.`);
  });
});

describe("the send-back", () => {
  test("sends the main agent's first guarded call back in default mode, and asks for the next one", async () => {
    const { ask, sent, requests, sendBacks, log } = setup();
    const first = await ask("Bash", escape);
    expect(first.out.hookSpecificOutput.permissionDecision).toBe("ask");
    expect(await first.result).toEqual({ behavior: "deny", message: hint(REASONS.escape, TMP) });
    expect(sendBacks()).toEqual([
      { type: "send_back", tool_use_id: first.id, agent_id: undefined, reason: REASONS.escape },
    ]);
    expect(requests()).toHaveLength(0);
    // The next guarded call asks, whatever it is.
    const second = await ask("Write", { file_path: join(home, "x"), content: "x" });
    expect(requests()).toMatchObject([{ tool: "Write", reason: REASONS.outside("~/x"), tool_use_id: second.id }]);
    expect(sendBacks()).toHaveLength(1);
    expect(sent.map((e) => e.type)).toEqual(["send_back", "permission_request"]);
    expect(log).toEqual([
      "send-back: main Bash runs outside the sandbox: npm i -g x",
      `send-back: asked main Write outside the trusted dirs: ~/x: ${join(home, "x")} (other call)`,
    ]);
  });

  test("in bypass mode the guard's hook denies with the hint, without a prompt", async () => {
    const { bypass, requests, sendBacks, log } = setup();
    const first = bypass("Bash", escape);
    expect(await first.out).toEqual({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: hint(REASONS.escape, TMP),
      },
    });
    expect(sendBacks()).toMatchObject([{ tool_use_id: first.id, reason: REASONS.escape }]);
    expect(requests()).toHaveLength(0);
    // The same call again asks the user.
    const second = bypass("Bash", escape);
    await Bun.sleep(1);
    expect(requests()).toMatchObject([{ tool: "Bash", reason: REASONS.escape, tool_use_id: second.id }]);
    expect(log).toEqual([
      "send-back: main Bash runs outside the sandbox: npm i -g x",
      "send-back: asked main Bash runs outside the sandbox: npm i -g x (same call)",
    ]);
  });

  test("decides each call once, and both paths share one send-back per agent", async () => {
    const { bridge, bypass, ask, requests, sendBacks, log } = setup();
    bypass("Bash", escape);
    await Bun.sleep(1);
    // The guard's reason is gone, so a second canUseTool for the call is a
    // plain request of Claude Code's own.
    const again = bridge.canUseTool("Bash", escape, {
      signal: new AbortController().signal,
      toolUseID: "toolu_1",
      requestId: "r",
    });
    void again;
    expect(requests()).toMatchObject([{ tool_use_id: "toolu_1", reason: undefined }]);
    await ask("Bash", escape);
    expect(requests()).toHaveLength(2);
    expect(sendBacks()).toHaveLength(1);
    expect(log).toHaveLength(2);
  });

  test("each subagent gets its own send-back, a background one too", async () => {
    const { ask, bypass, requests, sendBacks, log } = setup();
    await ask("Bash", escape);
    const sub = await ask("Bash", escape, "a1");
    expect(await sub.result).toMatchObject({ behavior: "deny" });
    await ask("Bash", escape, "a1");
    // A background agent's call between turns comes in bypass mode with its id.
    const bg = bypass("Write", { file_path: join(cwd, ".mcp.json"), content: "{}" }, "bg2");
    expect(await bg.out).toMatchObject({
      hookSpecificOutput: { permissionDecision: "deny", permissionDecisionReason: hint(REASONS.config, TMP) },
    });
    expect(sendBacks().map((e) => [e.agent_id, e.reason])).toEqual([
      [undefined, REASONS.escape],
      ["a1", REASONS.escape],
      ["bg2", REASONS.config],
    ]);
    expect(requests().map((e) => e.agent_id)).toEqual(["a1"]);
    expect(log[3]).toBe(
      `send-back: bg2 Write changes a config that runs outside the sandbox: ${join(cwd, ".mcp.json")}`,
    );
  });

  test("/clear starts over for the main agent, and a compaction does not", async () => {
    const { bridge, ask, sendBacks, requests } = setup();
    await ask("Bash", escape);
    await ask("Bash", escape, "bg1");
    bridge.message({ type: "system", subtype: "compact_boundary" } as SDKMessage);
    await ask("Bash", escape);
    expect(sendBacks()).toHaveLength(2);
    bridge.message({ type: "conversation_reset", trigger: "clear" } as unknown as SDKMessage);
    await ask("Bash", escape);
    expect(sendBacks()).toHaveLength(3);
    // A background agent that runs past /clear keeps its context, and the hint in it.
    await ask("Bash", escape, "bg1");
    expect(sendBacks()).toHaveLength(3);
    expect(requests().map((e) => e.agent_id)).toEqual([undefined, "bg1"]);
  });

  test("a cancelled request does not use up the send-back", async () => {
    const { bridge, guard, ask, sendBacks, requests } = setup();
    const out = (await guard.bash(
      {
        session_id: "s",
        transcript_path: "/t",
        cwd,
        hook_event_name: "PreToolUse",
        permission_mode: "default",
        tool_name: "Bash",
        tool_input: escape,
        tool_use_id: "toolu_gone",
      } as HookInput,
      "toolu_gone",
      { signal: new AbortController().signal },
    )) as any;
    expect(out.hookSpecificOutput.permissionDecision).toBe("ask");
    const aborted = new AbortController();
    aborted.abort();
    const result = bridge.canUseTool("Bash", escape, {
      signal: aborted.signal,
      toolUseID: "toolu_gone",
      requestId: "r",
    });
    expect(await result).toMatchObject({ behavior: "deny", message: CANCELLED });
    expect(sendBacks()).toHaveLength(0);
    expect(requests()).toHaveLength(1);
    const next = await ask("Bash", escape);
    expect(await next.result).toEqual({ behavior: "deny", message: hint(REASONS.escape, TMP) });
    expect(sendBacks()).toHaveLength(1);
  });

  test("sends back the excluded command and the settings files with their own hints", async () => {
    const { ask } = setup({ effective: { sandbox: { excludedCommands: ["touch *"] } } });
    const excluded = await ask("Bash", { command: "touch ~/x" });
    expect(await excluded.result).toEqual({ behavior: "deny", message: hint(REASONS.excluded, TMP) });
    const other = setup();
    const settings = await other.ask("Edit", { file_path: join(cwd, ".claude", "settings.json") });
    expect(await settings.result).toEqual({ behavior: "deny", message: hint(REASONS.settings, TMP) });
  });

  test("never sends back Claude Code's own asks, questions, plans or network hosts", async () => {
    const { bridge, requests, sendBacks } = setup();
    const opts = { signal: new AbortController().signal, requestId: "r" };
    bridge.canUseTool("Bash", { command: "rm -rf out" }, { ...opts, toolUseID: "t1" });
    bridge.canUseTool(
      "Write",
      { file_path: join(home, ".zshrc") },
      { ...opts, toolUseID: "t2", decisionReason: "safety" },
    );
    bridge.canUseTool("AskUserQuestion", { questions: [] }, { ...opts, toolUseID: "t3" });
    bridge.canUseTool("ExitPlanMode", { plan: "x" }, { ...opts, toolUseID: "t4" });
    bridge.canUseTool("SandboxNetworkAccess", { host: "example.com" }, { ...opts, toolUseID: "t5" });
    expect(requests()).toHaveLength(5);
    expect(sendBacks()).toHaveLength(0);
  });

  test("sends the event before the call's result", async () => {
    const { bridge, ask, sent } = setup();
    const order: string[] = [];
    const emit = (bridge as unknown as { emit: (ev: Event) => void }).emit;
    (bridge as unknown as { emit: (ev: Event) => void }).emit = (ev) => {
      order.push(ev.type);
      emit(ev);
    };
    const { result } = await ask("Bash", escape);
    await result!.then(() => order.push("result"));
    expect(order).toEqual(["send_back", "result"]);
    expect(sent).toHaveLength(1);
  });

  test("logs the command cut at 200 characters, on one line", async () => {
    const { ask, log } = setup();
    const long = "echo " + "x".repeat(300);
    await ask("Bash", { command: `cd /\n${long}`, dangerouslyDisableSandbox: true });
    await ask("Bash", { command: `cd /\n${long}`, dangerouslyDisableSandbox: true });
    const shown = `cd /\\n${long}`.slice(0, 200);
    expect(log).toEqual([
      `send-back: main Bash runs outside the sandbox: ${shown}`,
      `send-back: asked main Bash runs outside the sandbox: ${shown} (same call)`,
    ]);
  });
});
