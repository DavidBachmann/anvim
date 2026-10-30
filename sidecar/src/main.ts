import {
  query,
  type Options,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { openSync, writeSync } from "node:fs";
import { createInterface } from "node:readline";
import { postToolUse } from "./agentfiles";
import {
  browsersEvent,
  CHROME_SERVER,
  chromeArgs,
  chromeCalls,
  chromeEvent,
  chromeForCodex,
  type ChromeMessage,
  reconnectChrome,
  selectChrome,
  setChromeDefault,
} from "./chrome";
import { CodexRunner, type CodexSettings, codexConfig, codexState, codexWarning } from "./codex";
import { contextEvent, mcpEvent, modelsEvent, rewindFilesEvent, sessionInfoEvent, usageEvent } from "./dialogs";
import { Effort, getSettings } from "./effort";
import { type ImageBlock, imageBlocks } from "./images";
import { Limits, limitsEvent } from "./limits";
import { PermissionBridge } from "./permissions";
import { PreviewBridge } from "./preview";
import type { Command, Event } from "./protocol";
import { preToolUse, SandboxGuard, SandboxNotice, sandboxSetup, startMode } from "./sandbox";
import * as sessions from "./sessions";
import { TodoStore } from "./todos";
import { errorText } from "./text";
import { EditorBridge, editorServer, SERVER } from "./tools";
import { commandsEvent, Translator } from "./translate";

type Start = Extract<Command, { type: "start" }>;
// The answers to the plugin's requests, which carry an error when their call fails.
type Answer = Extract<Event, { error?: string }>;

const record = process.env.ANVIM_RECORD ? openSync(process.env.ANVIM_RECORD, "a") : undefined;

function emit(ev: Event): void {
  const line = JSON.stringify(ev);
  process.stdout.write(line + "\n");
  if (record !== undefined) writeSync(record, `${Date.now()} ${line}\n`);
}

function emitNotice(level: "info" | "warn" | "error", text: string): void {
  emit({ type: "notice", level, text });
}

const warn = (text: string) => emitNotice("warn", text);

// An answer that the view can do without. A failed call stays silent.
function emitLater(answer: Promise<Event>): void {
  answer.then(emit).catch(() => {});
}

// Turns pushed prompts into the AsyncIterable that streaming input mode reads.
class Inbox implements AsyncIterable<SDKUserMessage> {
  private queue: SDKUserMessage[] = [];
  private wake: (() => void) | null = null;
  private closed = false;

  // Claude Code reports the lifecycle of a prompt that has a uuid.
  push(text: string, images: ImageBlock[] = [], uuid?: string): void {
    const content = images.length ? [{ type: "text" as const, text }, ...images] : text;
    this.queue.push({
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      ...(uuid ? { uuid: uuid as SDKUserMessage["uuid"] } : {}),
    });
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
const effort = new Effort(emit);
const starting = Promise.withResolvers<Query>();
// The start's effort goes out before any change runs.
const ready = starting.promise.then(async (q) => {
  await effort.report(q);
  return q;
});
let controls: Promise<void> = Promise.resolve();
const translator = new Translator();
const editor = new EditorBridge(emit);
const permissions = new PermissionBridge(emit);
const previews = new PreviewBridge(emit);
// The Codex agents of the session, when a codex CLI is on PATH.
let codex: CodexRunner | undefined;
// The user's model and effort for the next Codex runs.
let codexDefaults: CodexSettings = {};
// The project's todo list. A start without todos_path has none.
let todos: TodoStore | undefined;
// The directory of the session, where Claude Code saves it.
let cwd = process.cwd();

// The session to resume, after its history went out. Claude Code fails to
// start on an id it cannot find, so a missing one starts a new session.
async function resumeTarget(cmd: Start): Promise<string | undefined> {
  let id = cmd.resume;
  if (!id && cmd.continue) {
    id = await sessions.latest(cmd.cwd);
    if (!id) emitNotice("info", "No earlier session in this directory, so this one is new.");
  }
  if (!id) return undefined;
  if (!(await sessions.exists(id, cmd.cwd))) {
    warn(`No session ${id} in this directory, so this one is new.`);
    return undefined;
  }
  if (cmd.history) {
    emit({ type: "history", session_id: id, events: await sessions.history(id, cmd.cwd, cmd.resume_at) });
  }
  return id;
}

// The summary detail answers from the last response's usage, without API calls.
async function reportContext(): Promise<void> {
  try {
    const usage = await session?.getContextUsage({ detail: "summary" });
    if (!usage) return;
    emit({ type: "context", percent: usage.percentage, tokens: usage.totalTokens, max: usage.maxTokens });
    translator.defaultWindow = usage.maxTokens;
  } catch {
    // Context usage is a nicety. The next turn tries again.
  }
}

// Model and effort changes wait for the session, which a resume starts only
// after its history went out. They run one at a time, in order.
function control(fn: (q: Query) => Promise<void>): Promise<void> {
  const next = controls.then(() => ready).then(fn);
  controls = next.catch(() => {});
  return next;
}

// Emits what fn answers. When fn throws, the failed answer goes out with the error.
async function reply(failed: Answer, fn: () => Promise<Event | Event[]>): Promise<void> {
  try {
    for (const ev of [await fn()].flat()) emit(ev);
  } catch (err) {
    emit({ ...failed, error: errorText(err) });
  }
}

// A reply that needs the session.
function answer(failed: Answer, fn: (q: Query) => Promise<Event | Event[]>): Promise<void> {
  return control((q) => reply(failed, () => fn(q)));
}

// Claude Code starts the Chrome server with the mode that the session starts
// in, and in bypass mode, the extension skips its site checks.
let chromeSkipsChecks = false;

function emitChrome(q: Query, message?: ChromeMessage): Promise<void> {
  return reply({ type: "chrome" }, async () => {
    const [dialog, servers] = await Promise.all([chromeCalls(q).getChromeDialog(), q.mcpServerStatus()]);
    return chromeEvent(dialog, servers, chromeSkipsChecks, message);
  });
}

// A message that the translator cannot read goes to the log. It must not end
// the session.
function translate(msg: SDKMessage): Event[] {
  try {
    return translator.translate(msg);
  } catch (err) {
    process.stderr.write(`could not translate a ${msg.type} message: ${(err as Error)?.stack ?? err}\n`);
    return [];
  }
}

// No sandbox runs, so anvim's own default, bypass mode, becomes default mode.
// The plugin's start mode decides the statusline's label and which modes
// Shift-Tab and plan approval offer. Claude Code's own line comes after the
// start, so a running session switches too. It switches at once, as
// set_permission_mode does, so a Shift-Tab that comes later wins.
export function fallBack(): void {
  permissions.bypass = false;
  emit({ type: "start_mode", mode: "default" });
  session?.setPermissionMode("default").catch((err) => {
    process.stderr.write(`could not fall back to default mode: ${err}\n`);
  });
}

async function run(cmd: Start): Promise<void> {
  // The tool list is fixed when the session starts, so the login check must
  // end before that. It runs while the rest of the start does.
  const codexCheck = codexState(cmd.codex === true);
  // Only false turns the sandbox off, so a start without the field keeps it.
  const sandboxOn = cmd.sandbox !== false;
  const sandbox = sandboxSetup(sandboxOn, cmd.cwd);
  const start = startMode(cmd.permission_mode, cmd.permission_mode_chosen === true, sandboxOn && !sandbox.problem);
  const mode = start.mode;
  cwd = cmd.cwd;
  permissions.cwd = cmd.cwd;
  permissions.bypass = mode === "bypassPermissions";
  chromeSkipsChecks = mode === "bypassPermissions";
  if (start.fallback) fallBack();
  // With the sandbox off, its guards are off too. One switch has one meaning.
  const guard = sandboxOn
    ? new SandboxGuard({
        cwd: cmd.cwd,
        settings: async () => (session ? getSettings(session) : {}),
        prompt: (tool, input, opts) => permissions.canUseTool(tool, input, { ...opts, requestId: "anvim-guard" }),
      })
    : undefined;
  permissions.useGuard(guard);
  const notice = new SandboxNotice(warn, start, fallBack);
  const [resume, { state: codexOn, bin: codexBin, models: codexModels }] = await Promise.all([
    resumeTarget(cmd),
    codexCheck,
  ]);
  emit({
    type: "codex",
    state: codexOn,
    ...(codexOn === "on" ? { config: codexConfig() } : {}),
    ...(codexModels ? { models: codexModels } : {}),
  });
  const codexProblem = codexWarning(codexOn, codexModels);
  if (codexProblem) warn(codexProblem);
  codex = codexBin
    ? new CodexRunner({
        bin: codexBin,
        cwd: cmd.cwd,
        emit,
        notify: (text) => inbox.push(text),
        defaults: () => codexDefaults,
        models: codexModels,
        // Before the session's first message, the start's mode applies.
        servers: { [CHROME_SERVER]: () => ready.then((q) => chromeForCodex(chromeCalls(q), permissions.mode ?? mode)) },
      })
    : undefined;
  todos = cmd.todos_path ? new TodoStore(cmd.todos_path, emit) : undefined;
  todos?.start();
  const options: Options = {
    ...sandbox.options,
    cwd: cmd.cwd,
    model: cmd.model,
    effort: cmd.effort,
    resume,
    resumeSessionAt: resume ? cmd.resume_at : undefined,
    // /rewind restores the files that Claude's edit tools changed.
    enableFileCheckpointing: true,
    permissionMode: mode,
    allowDangerouslySkipPermissions: mode === "bypassPermissions",
    includePartialMessages: true,
    // Foreground subagents send their text only with this.
    forwardSubagentText: true,
    hooks: {
      PreToolUse: preToolUse(previews.hook, guard),
      PostToolUse: postToolUse(() => session, cmd.cwd),
      ...(todos
        ? { SessionStart: [{ hooks: [todos.sessionStart] }], UserPromptSubmit: [{ hooks: [todos.firstPrompt] }] }
        : {}),
    },
    // anvim's todo list is the only one, also if Claude Code offers its own again.
    disallowedTools: ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"],
    systemPrompt: { type: "preset", preset: "claude_code", append: cmd.append_system_prompt },
    extraArgs: chromeArgs(cmd.chrome),
    mcpServers: { [SERVER]: editorServer(editor, { debug: cmd.debug === true, codex, todos }) },
    canUseTool: permissions.canUseTool,
    stderr: (data) => {
      process.stderr.write(data);
      notice.stderr(data);
    },
  };
  // After a resumed session's history, which draws the transcript again.
  notice.warn(sandbox.problem);
  effort.start(cmd.effort);
  session = query({ prompt: inbox, options });
  starting.resolve(session);
  // A resumed session shows how full it is before its first turn.
  void reportContext();
  emitLater(session.supportedCommands().then(commandsEvent));
  // The effort picker needs the models' effort levels.
  emitLater(session.supportedModels().then(modelsEvent));
  // The statusline names the login, so a work login and a personal one differ.
  emitLater(session.accountInfo().then((a) => ({ type: "account", email: a.email })));
  const limits = new Limits(emit, session);
  void limits.report();
  for await (const msg of session) {
    permissions.message(msg);
    // /clear: no conversation waits for the result of a Codex agent.
    if (msg.type === "conversation_reset") codex?.stopAll();
    for (const ev of translate(msg)) emit(ev);
    limits.message(msg);
    if (msg.type === "result") {
      void reportContext();
      // A settings file can change the inherited effort meanwhile.
      void control((q) => effort.report(q));
    }
  }
}

export async function handle(cmd: Command): Promise<void> {
  switch (cmd.type) {
    case "start":
      if (session) return;
      codexDefaults = { model: cmd.codex_model, effort: cmd.codex_effort };
      run(cmd).then(
        () => process.exit(0),
        (err) => {
          emitNotice("error", String(err?.stack ?? err));
          process.exit(1);
        },
      );
      return;
    case "prompt":
      inbox.push(cmd.text, imageBlocks(cmd.images ?? [], warn), cmd.id);
      return;
    case "interrupt":
      await session?.interrupt();
      return;
    case "background":
      await session?.backgroundTasks().catch((err) => warn(`Could not move the tasks to the background: ${err}`));
      return;
    case "cancel_prompt":
      // Query has cancelAsyncMessage, but the SDK's types do not name it.
      await (session as (Query & { cancelAsyncMessage(uuid: string): Promise<boolean> }) | undefined)
        ?.cancelAsyncMessage(cmd.id)
        .catch(() => {});
      return;
    case "set_permission_mode":
      permissions.mode = cmd.mode;
      await session?.setPermissionMode(cmd.mode);
      return;
    case "set_model":
      await control((q) => effort.setModel(q, cmd.model));
      return;
    case "set_effort":
      await control((q) => effort.set(q, cmd.effort));
      return;
    case "set_codex_defaults":
      codexDefaults = { model: cmd.model ?? undefined, effort: cmd.effort ?? undefined };
      return;
    case "list_models":
      await control(async (q) => emit(modelsEvent(await q.supportedModels())));
      return;
    case "usage":
      await answer({ type: "usage" }, async (q) => {
        // The SDK marks this call as one that may change in any release.
        const usage = await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET();
        // The statusline shows the same numbers as the Usage tab.
        return [usageEvent(usage), limitsEvent(usage)];
      });
      return;
    case "context_usage":
      await answer({ type: "context_usage" }, async (q) => contextEvent(await q.getContextUsage({ detail: "full" })));
      return;
    case "mcp_servers":
      await answer({ type: "mcp_servers" }, async (q) => mcpEvent(await q.mcpServerStatus()));
      return;
    case "mcp_action":
      await control(async (q) => {
        let error: string | undefined;
        try {
          // The editor tools are anvim's, and the session needs them.
          if (cmd.server === SERVER) throw new Error("anvim's own server always runs");
          if (cmd.action === "reconnect") await q.reconnectMcpServer(cmd.server);
          else await q.toggleMcpServer(cmd.server, cmd.action === "enable");
        } catch (err) {
          error = `Could not ${cmd.action} ${cmd.server}: ${errorText(err)}`;
        }
        try {
          emit(mcpEvent(await q.mcpServerStatus(), error));
        } catch (err) {
          emit({ type: "mcp_servers", error: error ?? errorText(err) });
        }
      });
      return;
    case "session_info":
      await answer({ type: "session_info" }, async (q) => {
        const init = await q.initializationResult();
        return sessionInfoEvent(init.claude_code_version, init.account, await q.mcpServerStatus());
      });
      return;
    case "chrome":
      await control((q) => emitChrome(q));
      return;
    case "chrome_reconnect":
      await control(async (q) => emitChrome(q, await reconnectChrome(q)));
      return;
    case "chrome_default":
      await control(async (q) => emitChrome(q, await setChromeDefault(cmd.enabled)));
      return;
    case "chrome_browsers":
      await answer({ type: "chrome_browsers" }, async (q) =>
        browsersEvent((await chromeCalls(q).getChromeBrowsers()).browsers),
      );
      return;
    case "chrome_select":
      await control(async (q) => emitChrome(q, await selectChrome(q, cmd.device_id)));
      return;
    case "todo_reset":
      if (!cmd.undo) await todos?.reset();
      else if (todos && !(await todos.undo())) emitNotice("info", "There is no previous todo list to bring back.");
      return;
    case "preview_done":
      previews.done(cmd.req);
      return;
    case "rewind_points":
      await reply({ type: "rewind_points", session_id: cmd.session_id }, async () => ({
        type: "rewind_points",
        session_id: cmd.session_id,
        points: sessions.rewindPoints(await sessions.messages(cmd.session_id, cwd, cmd.at)),
      }));
      return;
    case "rewind_files": {
      const dry_run = cmd.dry_run === true;
      await answer({ type: "rewind_files", uuid: cmd.uuid, dry_run, can_rewind: false }, async (q) =>
        rewindFilesEvent(cmd.uuid, dry_run, await q.rewindFiles(cmd.uuid, { dryRun: dry_run })),
      );
      return;
    }
    case "editor_response":
      editor.respond(cmd);
      return;
    case "permission_response":
      permissions.respond(cmd);
      return;
  }
}

// Bun runs no exit handlers on SIGTERM, so the SDK would leave Claude Code
// running. A restart of a hung sidecar sends SIGTERM.
function shutdown(): void {
  codex?.stopAll();
  inbox.close();
  session?.close();
  process.exit(0);
}

// The tests import handle() without the process around it.
if (import.meta.main) {
  const rl = createInterface({ input: process.stdin });
  rl.on("line", (line) => {
    if (!line.trim()) return;
    let cmd: Command;
    try {
      cmd = JSON.parse(line);
    } catch {
      emitNotice("error", `bad command: ${line.slice(0, 200)}`);
      return;
    }
    handle(cmd).catch((err) => emitNotice("error", errorText(err)));
  });
  rl.on("close", shutdown);
  process.on("SIGTERM", shutdown);
  // A session that ends leaves no Codex agent running.
  process.on("exit", () => codex?.stopAll());
}
