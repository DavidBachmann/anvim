import {
  query,
  type Options,
  type PermissionMode,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { contextHook, PendingContexts } from "./context";
import { PermissionBridge } from "./permissions";
import { PreviewBridge } from "./preview";
import type { Command, Event } from "./protocol";
import * as sessions from "./sessions";
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
const previews = new PreviewBridge(emit);

// The session to resume, after its history went out. Claude Code fails to
// start on an id it cannot find, so a missing one starts a new session.
async function resumeTarget(cmd: Extract<Command, { type: "start" }>): Promise<string | undefined> {
  let id = cmd.resume;
  if (!id && cmd.continue) {
    id = await sessions.latest(cmd.cwd);
    if (!id) emit({ type: "notice", level: "info", text: "No earlier session in this directory, so this one is new." });
  }
  if (!id) return undefined;
  if (!(await sessions.exists(id, cmd.cwd))) {
    emit({ type: "notice", level: "warn", text: `No session ${id} in this directory, so this one is new.` });
    return undefined;
  }
  if (cmd.history) emit({ type: "history", session_id: id, events: await sessions.history(id, cmd.cwd) });
  return id;
}

// The summary detail answers from the last response's usage, without API calls.
async function reportContext(): Promise<void> {
  try {
    const usage = await session?.getContextUsage({ detail: "summary" });
    if (usage) emit({ type: "context", percent: usage.percentage, tokens: usage.totalTokens, max: usage.maxTokens });
  } catch {
    // Context usage is a nicety. The next turn tries again.
  }
}

// A message that the translator cannot read goes to the log. It must not end
// the session.
function translate(translator: Translator, msg: SDKMessage): Event[] {
  try {
    return translator.translate(msg);
  } catch (err) {
    process.stderr.write(`could not translate a ${msg.type} message: ${(err as Error)?.stack ?? err}\n`);
    return [];
  }
}

async function run(cmd: Extract<Command, { type: "start" }>): Promise<void> {
  const mode = (cmd.permission_mode ?? "default") as PermissionMode;
  permissions.cwd = cmd.cwd;
  permissions.bypass = mode === "bypassPermissions";
  const options: Options = {
    cwd: cmd.cwd,
    model: cmd.model,
    resume: await resumeTarget(cmd),
    permissionMode: mode,
    allowDangerouslySkipPermissions: mode === "bypassPermissions",
    includePartialMessages: true,
    hooks: {
      PreToolUse: [{ matcher: "Edit|Write|NotebookEdit", hooks: [previews.hook] }],
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
  for await (const msg of session) {
    contexts.message(msg);
    for (const ev of translate(translator, msg)) emit(ev);
    if (msg.type === "result") void reportContext();
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
    case "list_models": {
      const models = (await session?.supportedModels()) ?? [];
      emit({
        type: "models",
        models: models.map((m) => ({
          value: m.value,
          name: m.displayName,
          description: m.description,
          resolved: m.resolvedModel,
        })),
      });
      return;
    }
    case "preview_done":
      previews.done(cmd.req);
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
// Bun runs no exit handlers on SIGTERM, so the SDK would leave Claude Code
// running. A restart of a hung sidecar sends SIGTERM.
function shutdown(): void {
  inbox.close();
  session?.close();
  process.exit(0);
}
rl.on("close", shutdown);
process.on("SIGTERM", shutdown);
