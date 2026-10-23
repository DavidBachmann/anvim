// Editor tools: an in-process MCP server whose tools run in Neovim. Each call
// becomes an editor_request, and the plugin (lua/anvim/tools.lua) answers it.
import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import type { Command, Event } from "./protocol";
import { parseDump, png, svg, type Pos } from "./screen";

export const SERVER = "anvim";
const TIMEOUT_MS = 10_000;

type Response = Extract<Command, { type: "editor_response" }>;
type Result = { content: { type: "text"; text: string }[]; isError?: boolean };
type ImageResult = { content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[] };

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
    return this.call(method, params).then((res) => (res.error != null ? text(res.error, true) : text(res.result ?? "")));
  }

  // The editor's raw answer, for a tool that builds its own result.
  call(method: string, params: Record<string, unknown>): Promise<{ result?: string; error?: string }> {
    const req = this.next++;
    return new Promise((resolve) => {
      const finish = (res: { result?: string; error?: string }) => {
        clearTimeout(timer);
        this.pending.delete(req);
        resolve(res);
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

// The user's screen as their terminal shows it. Neovim's TUI writes the dump,
// and the plugin answers with the default colors and the cursor (0-based),
// which the dump lacks.
async function screenshot(bridge: EditorBridge): Promise<Result | ImageResult> {
  const dir = mkdtempSync(join(tmpdir(), "anvim-screenshot-"));
  const files = { dump: join(dir, "screen.cat"), svg: join(dir, "screen.svg"), png: join(dir, "screen.png") };
  const res = await bridge.call("screenshot", { path: files.dump });
  if (res.error != null) return text(res.error, true);
  try {
    const info = JSON.parse(res.result ?? "{}") as { fg?: number; bg?: number; cursor?: Pos };
    const screen = parseDump(readFileSync(files.dump, "utf8"));
    writeFileSync(files.svg, svg(screen.cells, { fg: info.fg ?? 0xffffff, bg: info.bg ?? 0 }, info.cursor));
    const why = await png(files.svg, files.png, screen.cols, screen.rows);
    const lines = screen.cells.map((row) => row.map((c) => c.text).join("").trimEnd());
    const cursor = info.cursor ? ` The cursor is at row ${info.cursor.row + 1}, column ${info.cursor.col + 1}.` : "";
    const summary = [
      `The user's screen has ${screen.rows} rows and ${screen.cols} columns.${cursor}`,
      "```",
      ...lines,
      "```",
      why
        ? `There is no PNG: ${why} The terminal output and an SVG are in ${dir}.`
        : `The terminal output, an SVG and the PNG are in ${dir}.`,
    ].join("\n");
    if (why) return text(summary);
    return {
      content: [
        { type: "image", data: readFileSync(files.png).toString("base64"), mimeType: "image/png" },
        { type: "text", text: summary },
      ],
    };
  } catch (err) {
    return text(`Could not read the screenshot in ${dir}: ${err}`, true);
  }
}

export function editorTools(bridge: EditorBridge, opts: { debug?: boolean } = {}) {
  const call = (method: string) => (args: Record<string, unknown>) => bridge.request(method, args);
  // These tools are for anvim's own development, so only --debug adds them.
  const debug = opts.debug
    ? [
        tool(
          "screenshot",
          "Take a picture of the user's anvim screen as their terminal shows it. It returns a PNG and the screen's text. Images that the terminal draws, such as PNG files in the code window, are not in it.",
          {},
          () => screenshot(bridge),
          readOnly,
        ),
        tool(
          "reload",
          "Restart anvim with its code on disk, to load your changes to anvim's Lua or sidecar code. Run the gates before the call. anvim restarts when this turn ends and no agent runs, so end your turn right after the call. The new anvim resumes this session and sends a prompt that says it restarted.",
          {},
          call("reload"),
        ),
      ]
    : [];
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
    ...debug,
  ];
}

export function editorServer(bridge: EditorBridge, opts: { debug?: boolean } = {}): McpSdkServerConfigWithInstance {
  // Always loaded, so the tools never hide behind tool search.
  return createSdkMcpServer({ name: SERVER, tools: editorTools(bridge, opts), alwaysLoad: true });
}

// Editor tools need no permission prompt. Trust comes from the server's
// source, not the tool name: the tools of a settings server named "anvim_",
// "anvim." or "anvim__evil" also start with mcp__anvim__.
export function isEditorTool(mcpServer: { name: string; source: string } | undefined): boolean {
  return mcpServer?.source === "sdk" && mcpServer.name === SERVER;
}
