import { describe, expect, test } from "bun:test";
import type { PermissionResult, PermissionUpdate } from "@anthropic-ai/claude-agent-sdk";
import { CANCELLED, joinAnswer, PermissionBridge, REJECT, REJECT_WITH } from "./permissions";
import type { Event } from "./protocol";

type Request = Extract<Event, { type: "permission_request" }>;
type Options = Parameters<PermissionBridge["canUseTool"]>[2];

const editMode: PermissionUpdate = { type: "setMode", mode: "acceptEdits", destination: "session" };
const mkdirRule: PermissionUpdate = {
  type: "addRules",
  rules: [{ toolName: "Bash", ruleContent: "mkdir -p out" }],
  behavior: "allow",
  destination: "localSettings",
};

function setup() {
  const sent: Event[] = [];
  const bridge = new PermissionBridge((ev) => sent.push(ev));
  bridge.cwd = "/work/project";
  const ask = (tool: string, input: Record<string, unknown>, opts: Partial<Options> = {}) => {
    const controller = new AbortController();
    const result = bridge.canUseTool(tool, input, {
      signal: controller.signal,
      toolUseID: "toolu_1",
      requestId: "r1",
      ...opts,
    }) as Promise<PermissionResult>;
    return { result, controller, request: sent.at(-1) as Request };
  };
  return { bridge, sent, ask };
}

describe("PermissionBridge", () => {
  test("sends a request and allows once", async () => {
    const { bridge, ask } = setup();
    const input = { command: "mkdir -p out", description: "Make the output dir" };
    const { result, request } = ask("Bash", input, {
      suggestions: [mkdirRule],
      description: "Make the output dir",
      blockedPath: "/work/project/out",
    });
    expect(request).toEqual({
      type: "permission_request",
      req: 1,
      tool_use_id: "toolu_1",
      tool: "Bash",
      input,
      remember: "Yes, and don't ask again for Bash(mkdir -p out) in this project",
      blocked_path: "/work/project/out",
      title: undefined,
      description: "Make the output dir",
      default_to_no: undefined,
      agent_id: undefined,
    });
    expect(bridge.waiting).toBe(1);
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow" });
    expect(await result).toEqual({ behavior: "allow", updatedInput: input, decisionClassification: "user_temporary" });
    expect(bridge.waiting).toBe(0);
  });

  test("remember returns the suggestions as permission updates", async () => {
    const { bridge, ask } = setup();
    const { result } = ask("Edit", { file_path: "/work/project/a.lua" }, { suggestions: [editMode] });
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", remember: true });
    expect(await result).toMatchObject({
      behavior: "allow",
      updatedPermissions: [editMode],
      decisionClassification: "user_permanent",
    });
  });

  test("asks for a sandboxed command's new network host, and remembers it as a WebFetch rule", async () => {
    const { bridge, ask } = setup();
    // As Claude Code sends it: a fresh tool_use id that no tool call has.
    const host: PermissionUpdate = {
      type: "addRules",
      rules: [{ toolName: "WebFetch", ruleContent: "domain:example.com" }],
      behavior: "allow",
      destination: "localSettings",
    };
    const { result, request } = ask(
      "SandboxNetworkAccess",
      { host: "example.com" },
      {
        suggestions: [host],
        displayName: "SandboxNetworkAccess",
        description: "Allow network connection to example.com?",
        toolUseID: "77718261-f1b0-40e7-bf1e-07736e97f24c",
      },
    );
    expect(request.remember).toBe("Yes, and don't ask again for WebFetch(domain:example.com) in this project");
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", remember: true });
    expect(await result).toMatchObject({
      behavior: "allow",
      updatedInput: { host: "example.com" },
      updatedPermissions: [host],
    });
  });

  test("offers nothing to remember when Claude Code suppresses the rule", async () => {
    const { bridge, ask } = setup();
    const { result, request } = ask("Bash", { command: "rm -rf out" }, {
      suggestions: [mkdirRule],
      suppressAlwaysAllowRule: true,
      defaultToNo: true,
    });
    expect(request.remember).toBeUndefined();
    expect(request.default_to_no).toBe(true);
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", remember: true });
    expect((await result) as Record<string, unknown>).not.toHaveProperty("updatedPermissions");
  });

  test("anvim's own ask shows its reason and offers nothing to remember", async () => {
    const { bridge, ask } = setup();
    const reasons = new Map([["toolu_1", "runs outside the sandbox"]]);
    bridge.guard = {
      take: (id) => {
        const reason = reasons.get(id);
        reasons.delete(id);
        return reason;
      },
    };
    const { result, request } = ask(
      "Bash",
      { command: "rm ~/x", dangerouslyDisableSandbox: true },
      { suggestions: [mkdirRule], decisionReason: "runs outside the sandbox" },
    );
    expect(request.reason).toBe("runs outside the sandbox");
    expect(request.remember).toBeUndefined();
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", remember: true });
    expect((await result) as Record<string, unknown>).not.toHaveProperty("updatedPermissions");
  });

  test("a user's own hook that asks keeps the remember choice, and shows no reason", async () => {
    const { bridge, ask } = setup();
    bridge.guard = { take: () => undefined };
    const { request } = ask("Bash", { command: "mkdir -p out" }, {
      suggestions: [mkdirRule],
      decisionReason: "my hook wants a look",
    });
    expect(request.reason).toBeUndefined();
    expect(request.remember).toBe("Yes, and don't ask again for Bash(mkdir -p out) in this project");
  });

  test("denies with Claude Code's wording, and carries what the user typed", async () => {
    const { bridge, ask } = setup();
    const plain = ask("Bash", { command: "make" }).result;
    const typed = ask("Bash", { command: "make all" }).result;
    bridge.respond({ type: "permission_response", req: 1, behavior: "deny" });
    bridge.respond({ type: "permission_response", req: 2, behavior: "deny", message: "  Run make test instead. " });
    expect(await plain).toEqual({ behavior: "deny", message: REJECT, decisionClassification: "user_reject" });
    expect(await typed).toEqual({
      behavior: "deny",
      message: REJECT_WITH + "Run make test instead.",
      decisionClassification: "user_reject",
    });
  });

  test("an abort cancels the request in the plugin, and a late answer is ignored", async () => {
    const { bridge, sent, ask } = setup();
    const { result, controller } = ask("Bash", { command: "sleep 9" });
    controller.abort();
    expect(sent.at(-1)).toEqual({ type: "permission_cancel", req: 1 });
    expect(await result).toEqual({ behavior: "deny", message: CANCELLED });
    expect(bridge.waiting).toBe(0);
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow" });

    const aborted = new AbortController();
    aborted.abort();
    const early = ask("Bash", { command: "ls" }, { signal: aborted.signal });
    expect(sent.slice(-2).map((ev) => ev.type)).toEqual(["permission_request", "permission_cancel"]);
    expect((await early.result).behavior).toBe("deny");
  });

  test("allows anvim's editor tools without a prompt, and only those", async () => {
    const { bridge, sent, ask } = setup();
    const input = { path: "a.lua", start_line: 3 };
    const own = await ask("mcp__anvim__show_user", input, { mcpServer: { name: "anvim", source: "sdk" } }).result;
    expect(own).toEqual({ behavior: "allow", updatedInput: input });
    expect(sent).toEqual([]);
    // A settings server named "anvim_" gets tool names that start with mcp__anvim__ too.
    ask("mcp__anvim__show_user", input, { mcpServer: { name: "anvim_", source: "project" } });
    ask("mcp__anvim__show_user", input, { mcpServer: { name: "anvim", source: "user" } });
    expect(sent.map((ev) => ev.type)).toEqual(["permission_request", "permission_request"]);
    expect(bridge.waiting).toBe(2);
  });

  test("puts AskUserQuestion answers into the input, as Claude Code expects them", async () => {
    const { bridge, ask } = setup();
    const input = {
      questions: [
        { question: "Which greeting?", header: "Greeting", multiSelect: false, options: [] },
        { question: "Which languages?", header: "Languages", multiSelect: true, options: [] },
        { question: "Skipped?", header: "Skip", multiSelect: false, options: [] },
      ],
    };
    const { result } = ask("AskUserQuestion", input);
    bridge.respond({
      type: "permission_response",
      req: 1,
      behavior: "allow",
      answers: {
        "Which greeting?": ["Hi"],
        "Which languages?": ["English", "French", "Spanish, but formal"],
        "Skipped?": [],
      },
    });
    expect(await result).toEqual({
      behavior: "allow",
      updatedInput: {
        ...input,
        answers: { "Which greeting?": "Hi", "Which languages?": 'English, French, "Spanish, but formal"' },
      },
      decisionClassification: "user_temporary",
    });
  });

  test("approving a plan switches the permission mode for the session", async () => {
    const { bridge, ask } = setup();
    const input = { plan: "# Plan", planFilePath: "/tmp/plan.md" };
    const approved = ask("ExitPlanMode", input).result;
    const unknown = ask("ExitPlanMode", input).result;
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", mode: "acceptEdits" });
    bridge.respond({ type: "permission_response", req: 2, behavior: "allow", mode: "bypassPermissions" });
    expect(await approved).toEqual({
      behavior: "allow",
      updatedInput: input,
      updatedPermissions: [{ type: "setMode", mode: "acceptEdits", destination: "session" }],
      decisionClassification: "user_temporary",
    });
    expect((await unknown) as Record<string, unknown>).not.toHaveProperty("updatedPermissions");
  });

  test("switches back to bypass after a plan only when the session started in it", async () => {
    const { bridge, ask } = setup();
    bridge.bypass = true;
    const input = { plan: "# Plan" };
    const approved = ask("ExitPlanMode", input).result;
    bridge.respond({ type: "permission_response", req: 1, behavior: "allow", mode: "bypassPermissions" });
    expect(await approved).toMatchObject({
      updatedPermissions: [{ type: "setMode", mode: "bypassPermissions", destination: "session" }],
    });
    // Only a plan approval can switch the mode.
    const other = ask("Bash", { command: "make" }).result;
    bridge.respond({ type: "permission_response", req: 2, behavior: "allow", mode: "bypassPermissions" });
    expect((await other) as Record<string, unknown>).not.toHaveProperty("updatedPermissions");
  });
});

describe("joinAnswer", () => {
  test("quotes the labels that Claude Code could not split again", () => {
    expect(joinAnswer(["A"])).toBe("A");
    expect(joinAnswer(["A", "B,C"])).toBe("A, B,C");
    expect(joinAnswer(['say "hi"', "x, y"])).toBe('"say \\"hi\\"", "x, y"');
  });
});

describe("rememberLabel", () => {
});
