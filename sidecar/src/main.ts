import {
  query,
  type HookCallback,
  type Options,
  type PermissionMode,
  type Query,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { contextHook, PendingContexts } from "./context";
import { PermissionBridge } from "./permissions";
import type { Command, Event } from "./protocol";
import { EditorBridge, editorServer, SERVER } from "./tools";
import { commandsEvent, Translator } from "./translate";

const record = process.env.ANVIM_RECORD;

function emit(ev: Event): void {
  const line = JSON.stringify(ev);
  process.stdout.write(line + "\n");
  if (record) appendFileSync(record, `${Date.now()} ${line}\n`);
}

// Turns pushed prompts into the AsyncIterable that streaming input mode reads.
class Inbox implements AsyncIterable<SDKUserMessage> {
  private queue: SDKUserMessage[] = [];
  private wake: (() => void) | null = null;
  private closed = false;

  push(text: string): void {
    this.queue.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
    this.wake?.();
  }

  close(): void {
    this.closed = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    while (true) {
      const next = this.queue.shift();
      if (next) {
        yield next;
        continue;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => (this.wake = resolve));
      this.wake = null;
    }
  }
}

const inbox = new Inbox();
let session: Query | null = null;
const editor = new EditorBridge(emit);
const permissions = new PermissionBridge(emit);
const contexts = new PendingContexts();

const PREVIEW_TIMEOUT_MS = 3000;
const previews = new Map<number, () => void>();
let nextReq = 1;

const awaitPreview: HookCallback = async (_input, toolUseID, { signal }) => {
  if (!toolUseID) return {};
  const req = nextReq++;
  await new Promise<void>((resolve) => {
    const done = () => {
      clearTimeout(timer);
      previews.delete(req);
      resolve();
    };
    const timer = setTimeout(done, PREVIEW_TIMEOUT_MS);
    signal.addEventListener("abort", done, { once: true });
    previews.set(req, done);
    emit({ type: "await_preview", req, tool_use_id: toolUseID });
  });
  return {};
};

async function run(cmd: Extract<Command, { type: "start" }>): Promise<void> {
  const mode = (cmd.permission_mode ?? "default") as PermissionMode;
  permissions.cwd = cmd.cwd;
  permissions.bypass = mode === "bypassPermissions";
  const options: Options = {
    cwd: cmd.cwd,
    model: cmd.model,
    resume: cmd.resume,
    permissionMode: mode,
    allowDangerouslySkipPermissions: mode === "bypassPermissions",
    includePartialMessages: true,
    hooks: {
      PreToolUse: [{ matcher: "Edit|Write|NotebookEdit", hooks: [awaitPreview] }],
      UserPromptSubmit: [{ hooks: [contextHook(contexts)] }],
    },
    systemPrompt: { type: "preset", preset: "claude_code", append: cmd.append_system_prompt },
    mcpServers: { [SERVER]: editorServer(editor) },
    canUseTool: permissions.canUseTool,
    stderr: (data) => process.stderr.write(data),
  };
  session = query({ prompt: inbox, options });
  session
    .supportedCommands()
    .then((commands) => emit(commandsEvent(commands)))
    .catch(() => {});
  const translator = new Translator();
  let turnOpen = false;
  for await (const msg of session) {
    if (!turnOpen) {
      turnOpen = true;
      contexts.turnStart();
    }
    if (msg.type === "result") {
      turnOpen = false;
      contexts.turnEnd();
    }
    for (const ev of translator.translate(msg)) emit(ev);
  }
}

async function handle(cmd: Command): Promise<void> {
  switch (cmd.type) {
    case "start":
      if (session) return;
      run(cmd)
        .then(() => emit({ type: "exit", code: 0 }))
        .catch((err) => {
          emit({ type: "notice", level: "error", text: String(err?.stack ?? err) });
          emit({ type: "exit", code: 1 });
        })
        .finally(() => process.exit());
      return;
    case "prompt":
      contexts.push(cmd.text, cmd.context);
      inbox.push(cmd.text);
      return;
    case "interrupt":
      await session?.interrupt();
      return;
    case "set_permission_mode":
      await session?.setPermissionMode(cmd.mode as PermissionMode);
      return;
    case "set_model":
      await session?.setModel(cmd.model);
      return;
    case "preview_done":
      previews.get(cmd.req)?.();
      return;
    case "editor_response":
      editor.respond(cmd);
      return;
    case "permission_response":
      permissions.respond(cmd);
      return;
  }
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let cmd: Command;
  try {
    cmd = JSON.parse(line);
  } catch {
    emit({ type: "notice", level: "error", text: `bad command: ${line.slice(0, 200)}` });
    return;
  }
  handle(cmd).catch((err) => emit({ type: "notice", level: "error", text: String(err?.message ?? err) }));
});
rl.on("close", () => {
  inbox.close();
  session?.close();
  process.exit(0);
});
