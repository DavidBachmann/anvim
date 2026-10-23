import { describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import type { Event } from "./protocol";
import { EditorBridge, editorServer, isEditorTool, SERVER } from "./tools";

type Request = Extract<Event, { type: "editor_request" }>;

function bridge(timeoutMs?: number) {
  const sent: Request[] = [];
  const b = new EditorBridge((ev) => sent.push(ev as Request), timeoutMs);
  return { b, sent };
}

async function connect(b: EditorBridge, opts?: { debug?: boolean }) {
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
    expect(isEditorTool({ name: SERVER, source: "sdk" })).toBe(true);
    // The CLI gives the tools of these servers names that start with mcp__anvim__.
    for (const name of ["anvim_", "anvim.", "anvim__evil"]) {
      expect(isEditorTool({ name, source: "project" })).toBe(false);
      expect(isEditorTool({ name, source: "sdk" })).toBe(false);
    }
    expect(isEditorTool({ name: SERVER, source: "user" })).toBe(false);
    expect(isEditorTool(undefined)).toBe(false);
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
