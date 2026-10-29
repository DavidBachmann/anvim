import { describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CodexRunner, type CodexModel } from "./codex";
import type { Event } from "./protocol";
import { type Codex, EditorBridge, editorServer, isOwnServer, SERVER } from "./tools";

type Request = Extract<Event, { type: "editor_request" }>;

function bridge(timeoutMs?: number) {
  const sent: Request[] = [];
  const b = new EditorBridge((ev) => sent.push(ev as Request), timeoutMs);
  return { b, sent };
}

async function connect(b: EditorBridge, opts?: { debug?: boolean; codex?: Codex }) {
  const server = editorServer(b, opts);
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await server.instance.connect(serverSide);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(clientSide);
  return client;
}

describe("EditorBridge", () => {
  test("matches each response to its request", async () => {
    const { b, sent } = bridge();
    const first = b.request("lsp_hover", { path: "a.lua", line: 1, symbol: "x" });
    const second = b.request("diagnostics", {});
    expect(sent).toEqual([
      { type: "editor_request", req: 1, method: "lsp_hover", params: { path: "a.lua", line: 1, symbol: "x" } },
      { type: "editor_request", req: 2, method: "diagnostics", params: {} },
    ]);
    b.respond({ type: "editor_response", req: 2, error: "No such file: b.lua" });
    b.respond({ type: "editor_response", req: 1, result: "function x()" });
    expect(await first).toEqual({ content: [{ type: "text", text: "function x()" }] });
    expect(await second).toEqual({ content: [{ type: "text", text: "No such file: b.lua" }], isError: true });
    expect(b.waiting).toBe(0);
  });

  test("turns a missing answer into a tool error and ignores a late one", async () => {
    const { b } = bridge(20);
    const res = await b.request("lsp_references", {});
    expect(res.isError).toBe(true);
    expect(res.content[0]!.text).toContain("did not answer lsp_references");
    expect(b.waiting).toBe(0);
    b.respond({ type: "editor_response", req: 1, result: "too late" });
  });
});

describe("editor MCP server", () => {
  test("registers every tool with a usable schema", async () => {
    const client = await connect(bridge().b);
    const { tools } = await client.listTools();
    const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
    expect(Object.keys(byName).sort()).toEqual([
      "diagnostics",
      "lsp_definition",
      "lsp_document_symbols",
      "lsp_hover",
      "lsp_references",
      "lsp_workspace_symbols",
      "show_user",
    ]);
    expect(byName.lsp_references!.inputSchema.required?.sort()).toEqual(["line", "path", "symbol"]);
    expect(byName.show_user!.inputSchema.required?.sort()).toEqual(["path", "start_line"]);
    expect(byName.diagnostics!.inputSchema.required ?? []).toEqual([]);
    for (const t of tools) expect(t.annotations?.readOnlyHint).toBe(true);
  });

  test("has the screenshot and reload tools only with --debug", async () => {
    const names = async (debug: boolean) =>
      (await (await connect(bridge().b, { debug })).listTools()).tools.map((t) => t.name);
    expect(await names(false)).not.toContain("screenshot");
    expect(await names(false)).not.toContain("reload");
    expect(await names(true)).toEqual(expect.arrayContaining(["screenshot", "reload"]));
  });

  test("trusts only the in-process server that anvim registered", () => {
    expect(isOwnServer({ name: SERVER, source: "sdk" })).toBe(true);
    // The CLI gives the tools of these servers names that start with mcp__anvim__.
    for (const name of ["anvim_", "anvim.", "anvim__evil"]) {
      expect(isOwnServer({ name, source: "project" })).toBe(false);
      expect(isOwnServer({ name, source: "sdk" })).toBe(false);
    }
    expect(isOwnServer({ name: SERVER, source: "user" })).toBe(false);
    expect(isOwnServer(undefined)).toBe(false);
  });

  test("a tool call goes to the editor and returns its answer", async () => {
    const { b, sent } = bridge();
    const client = await connect(b);
    const call = client.callTool({ name: "show_user", arguments: { path: "a.lua", start_line: 3, note: "here" } });
    while (sent.length === 0) await Bun.sleep(1);
    expect(sent[0]!.method).toBe("show_user");
    expect(sent[0]!.params).toEqual({ path: "a.lua", start_line: 3, note: "here" });
    b.respond({ type: "editor_response", req: sent[0]!.req, result: "Showed a.lua#L3." });
    expect(await call).toEqual({ content: [{ type: "text", text: "Showed a.lua#L3." }] });
  });

  test("rejects a call whose input breaks the schema, without asking the editor", async () => {
    const { b, sent } = bridge();
    const client = await connect(b);
    const res = await client.callTool({ name: "lsp_hover", arguments: { path: "a.lua", line: 0, symbol: "x" } });
    expect(res.isError).toBe(true);
    expect(sent).toEqual([]);
  });
});

describe("codex tool", () => {
  const models: CodexModel[] = [
    { slug: "gpt-6.1-terra", name: "GPT-6.1 Terra", hidden: false, efforts: ["low", "high", "xhigh"] },
    { slug: "gpt-6-mini", name: "GPT-6 Mini", hidden: false, efforts: ["low", "medium"] },
    { slug: "gpt-old", name: "GPT Old", hidden: true, efforts: [] },
  ];
  const task = { description: "Review", prompt: "Review a.ts" };

  // Claude in Chrome is not connected.
  const servers = { "claude-in-chrome": async () => "Claude in Chrome is not connected in this session." };

  function runner(bin: string, config = {}) {
    const events: Event[] = [];
    const notes: string[] = [];
    const codex = new CodexRunner({
      bin,
      cwd: tmpdir(),
      emit: (ev) => events.push(ev),
      notify: (text) => notes.push(text),
      defaults: () => ({}),
      config: () => config,
      models,
      servers,
    });
    return { codex, events, notes };
  }

  const textOf = (res: Awaited<ReturnType<Client["callTool"]>>) => (res.content as { text: string }[])[0]!.text;

  test("lists the visible models to Claude, and refuses a model, an effort or a server that Codex lacks", async () => {
    const { codex, events } = runner("/nonexistent/codex");
    const client = await connect(bridge().b, { codex });
    const tool = (await client.listTools()).tools.find((t) => t.name === "codex")!;
    const props = tool.inputSchema.properties as Record<string, { description: string }>;
    expect(props.model!.description).toContain("gpt-6.1-terra (GPT-6.1 Terra), gpt-6-mini (GPT-6 Mini).");
    expect(props.model!.description).not.toContain("gpt-old");
    expect(props.effort!.description).toContain("low, high, xhigh, medium");

    const unknown = await client.callTool({ name: "codex", arguments: { ...task, model: "gpt-6.1" } });
    expect(unknown.isError).toBe(true);
    expect(textOf(unknown)).toContain("Pass one of these slugs as model: gpt-6.1-terra (GPT-6.1 Terra), gpt-6-mini");
    const effort = await client.callTool({ name: "codex", arguments: { ...task, model: "gpt-6-mini", effort: "xhigh" } });
    expect(effort.isError).toBe(true);
    expect(textOf(effort)).toContain("low, medium");
    expect(props.mcp_servers!.description).toContain('Only "claude-in-chrome" is supported.');
    const server = await client.callTool({ name: "codex", arguments: { ...task, mcp_servers: ["playwright"] } });
    expect(server.isError).toBe(true);
    expect(textOf(server)).toBe("anvim cannot hand playwright to Codex. It can hand over only claude-in-chrome.");
    const chrome = await client.callTool({ name: "codex", arguments: { ...task, mcp_servers: ["claude-in-chrome"] } });
    expect(chrome.isError).toBe(true);
    expect(textOf(chrome)).toBe("Claude in Chrome is not connected in this session.");
    expect(events).toEqual([]);
  });

  test("the result names the run's model and effort and where each comes from", async () => {
    const dir = mkdtempSync(join(tmpdir(), "anvim-codex-"));
    const bin = join(dir, "codex");
    writeFileSync(bin, "#!/bin/sh\ncat >/dev/null\n");
    chmodSync(bin, 0o755);
    const { codex, events, notes } = runner(bin, { effort: "xhigh" });
    const client = await connect(bridge().b, { codex });
    // A hidden model is a model too.
    const res = await client.callTool({ name: "codex", arguments: { ...task, model: "gpt-old", effort: "max" } });
    expect(res.isError).toBeUndefined();
    expect(textOf(res)).toMatch(/started in the background with model gpt-old \(from the call\) and effort max \(from the call\)\. /);
    const res2 = await client.callTool({ name: "codex", arguments: { ...task, model: "gpt-6.1-terra" } });
    expect(textOf(res2)).toContain("with model gpt-6.1-terra (from the call) and effort xhigh (from Codex's config).");
    expect(events.filter((e) => e.type === "agent_start")).toHaveLength(2);
    while (notes.length < 2) await Bun.sleep(5);
    rmSync(dir, { recursive: true });
  });
});
