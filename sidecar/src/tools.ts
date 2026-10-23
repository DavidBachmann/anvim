// Editor tools: an in-process MCP server whose tools run in Neovim. Each call
// becomes an editor_request, and the plugin (lua/anvim/tools.lua) answers it.
import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import type { Command, Event } from "./protocol";

export const SERVER = "anvim";
const TIMEOUT_MS = 10_000;

type Response = Extract<Command, { type: "editor_response" }>;
type Result = { content: { type: "text"; text: string }[]; isError?: boolean };

const text = (s: string, isError = false): Result => ({
  content: [{ type: "text", text: s }],
  ...(isError ? { isError } : {}),
});

// Matches editor responses to their requests. A request that Neovim does not
// answer in time becomes a tool error, so Claude never hangs on the editor.
export class EditorBridge {
  private pending = new Map<number, (res: { result?: string; error?: string }) => void>();
  private next = 1;

  constructor(
    private emit: (ev: Event) => void,
    private timeoutMs = TIMEOUT_MS,
  ) {}

  request(method: string, params: Record<string, unknown>): Promise<Result> {
    const req = this.next++;
    return new Promise((resolve) => {
      const finish = (res: { result?: string; error?: string }) => {
        clearTimeout(timer);
        this.pending.delete(req);
        resolve(res.error != null ? text(res.error, true) : text(res.result ?? ""));
      };
      const timer = setTimeout(
        () => finish({ error: `Neovim did not answer ${method} within ${this.timeoutMs / 1000} s.` }),
        this.timeoutMs,
      );
      this.pending.set(req, finish);
      this.emit({ type: "editor_request", req, method, params });
    });
  }

  respond(res: Response): void {
    this.pending.get(res.req)?.(res);
  }

  get waiting(): number {
    return this.pending.size;
  }
}

const path = z.string().describe("File path, absolute or relative to the working directory");
const line = z.number().int().min(1).describe("1-based line number");
const symbol = z.string().describe("The symbol's name, exactly as it appears on that line");
const lsp = "It asks the language servers running in the user's editor.";
// The tools only read code and move the editor's view.
const readOnly = { annotations: { readOnlyHint: true } };

export function editorTools(bridge: EditorBridge) {
  const call = (method: string) => (args: Record<string, unknown>) => bridge.request(method, args);
  return [
    tool(
      "show_user",
      "Show the user a range of code in their editor, with an optional note above it. Use it whenever you explain code or answer where something is. The range stays marked until the user's next prompt.",
      {
        path,
        start_line: line,
        end_line: line.optional().describe("1-based last line of the range, inclusive"),
        note: z.string().optional().describe("One or two sentences shown above the range"),
      },
      call("show_user"),
      readOnly,
    ),
    tool(
      "diagnostics",
      "List the errors and warnings that the editor's language servers and linters report, errors first. Without a path, it lists every file in the working directory that they checked.",
      { path: path.optional() },
      call("diagnostics"),
      readOnly,
    ),
    tool(
      "lsp_definition",
      `Find where a symbol is defined. ${lsp} Prefer it over grep for code symbols.`,
      { path, line, symbol },
      call("lsp_definition"),
      readOnly,
    ),
    tool(
      "lsp_references",
      `List every reference to a symbol, across the workspace. ${lsp} Prefer it over grep to find where a function, type or variable is used. If you do not know where the symbol is, find it with lsp_workspace_symbols first.`,
      { path, line, symbol },
      call("lsp_references"),
      readOnly,
    ),
    tool(
      "lsp_hover",
      `Get the type, signature and documentation of a symbol. ${lsp}`,
      { path, line, symbol },
      call("lsp_hover"),
      readOnly,
    ),
    tool(
      "lsp_document_symbols",
      `Outline a file: its classes, functions, methods and fields, with line ranges. ${lsp}`,
      { path },
      call("lsp_document_symbols"),
      readOnly,
    ),
    tool(
      "lsp_workspace_symbols",
      `Find symbols by name across the workspace. It gives the path and line that the other lsp_ tools need. ${lsp} It starts the servers for the working directory's languages when none runs yet.`,
      { query: z.string().describe("Part of a symbol name") },
      call("lsp_workspace_symbols"),
      readOnly,
    ),
  ];
}

export function editorServer(bridge: EditorBridge): McpSdkServerConfigWithInstance {
  // Always loaded, so the tools never hide behind tool search.
  return createSdkMcpServer({ name: SERVER, tools: editorTools(bridge), alwaysLoad: true });
}

// Read-only tools need no permission prompt. Trust comes from the server's
// source, not the tool name: the tools of a settings server named "anvim_",
// "anvim." or "anvim__evil" also start with mcp__anvim__.
export function isEditorTool(mcpServer: { name: string; source: string } | undefined): boolean {
  return mcpServer?.source === "sdk" && mcpServer.name === SERVER;
}
