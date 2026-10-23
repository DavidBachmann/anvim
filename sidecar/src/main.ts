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
import {
  browsersEvent,
  CHROME_SERVER,
  chromeArgs,
  chromeCalls,
  chromeEvent,
  type ChromeMessage,
  setEnabledByDefault,
} from "./chrome";
import { type ImageBlock, imageBlocks } from "./images";
import { PermissionBridge } from "./permissions";
import { PreviewBridge } from "./preview";
import type { Command, EffortLevel, Event } from "./protocol";
import { preToolUse, SandboxGuard, SandboxNotice, sandboxSetup, startMode } from "./sandbox";
import * as sessions from "./sessions";
import { EditorBridge, editorServer, SERVER } from "./tools";
import { commandsEvent, contextEvent, mcpEvent, modelsEvent, sessionInfoEvent, Translator, usageEvent } from "./translate";

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
let sessionReady!: (q: Query) => void;
// The start's effort goes out before any change runs.
const ready = new Promise<Query>((resolve) => (sessionReady = resolve)).then(async (q) => {
  await reportEffort(q);
  return q;
});
let controls: Promise<void> = Promise.resolve();
const editor = new EditorBridge(emit);
const permissions = new PermissionBridge(emit);
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

// Model and effort changes wait for the session, which a resume starts only
// after its history went out. They run one at a time, in order.
function control(fn: (q: Query) => Promise<void>): Promise<void> {
  const next = controls.then(() => ready).then(fn);
  controls = next.catch(() => {});
  return next;
}

// What getSettings() answers. The SDK has the method, but not in its types.
export type SettingsAnswer = {
  effective?: Record<string, any>;
  sources?: { source: string; settings?: Record<string, any> | null }[];
  applied?: { model?: string; effort?: EffortLevel | null };
};

// Claude Code starts the Chrome server with the mode that the session starts
// in, and in bypass mode, the extension skips its site checks.
let chromeSkipsChecks = false;

async function emitChrome(q: Query, message?: ChromeMessage): Promise<void> {
  try {
    const [dialog, servers] = await Promise.all([chromeCalls(q).getChromeDialog(), q.mcpServerStatus()]);
    emit(chromeEvent(dialog, servers, chromeSkipsChecks, message));
  } catch (err) {
    emit({ type: "chrome", error: errorText(err) });
  }
}

function errorText(err: unknown): string {
  return String((err as Error)?.message ?? err);
}

function getSettings(q: Query): Promise<SettingsAnswer> {
  return (q as unknown as { getSettings(): Promise<SettingsAnswer> }).getSettings();
}

// claude-opus-5-5[1m] and claude-opus-5-5-20261001 are claude-opus-5-5.
function canonical(model: string): string {
  return model.replace(/\[1m\]$/i, "").replace(/-\d{8}$/, "");
}

// The level that a new session takes from the settings files for a model:
// the model's modelSettings entry, or a file's top-level effortLevel, from
// the highest file that has either. Claude Code applies the user's own
// top-level effortLevel only to some older models, so it does not count here.
// The flag settings are anvim's own. null leaves the model's own level.
export function settingsEffort(answer: SettingsAnswer, model: string): EffortLevel | null {
  const name = canonical(model);
  for (const { source, settings } of [...(answer.sources ?? [])].reverse()) {
    if (source === "flagSettings" || !settings) continue;
    const entries = Object.entries(settings.modelSettings ?? {}) as [string, { effortLevel?: EffortLevel }][];
    const own = entries.find(([key]) => key === name) ?? entries.find(([key]) => canonical(key) === name);
    const level = own?.[1]?.effortLevel ?? (source === "userSettings" ? undefined : settings.effortLevel);
    if (level) return level;
  }
  return null;
}

// A session that started without an effort inherits it: Claude Code takes it
// from the settings for each model, as in a new session. A level from
// set_effort ends that, and the flag settings cannot bring it back. After
// set_effort null, a model switch applies the settings' level for the new
// model, so the default follows the model as an inherited effort does.
let inheriting = false;
let followSettings = false;
// The levels that the session inherited, by model. They are Claude Code's own
// answer, which settingsEffort() only comes close to.
const inherited = new Map<string, EffortLevel | null>();

async function reportEffort(q: Query): Promise<void> {
  try {
    const { applied } = await getSettings(q);
    const level = applied?.effort ?? null;
    if (inheriting && applied?.model) inherited.set(applied.model, level);
    emit({ type: "effort", level });
  } catch {
    // Without get_settings, the statusline shows no effort.
  }
}

async function defaultEffort(q: Query): Promise<EffortLevel | null> {
  const answer = await getSettings(q);
  const model = answer.applied?.model;
  if (!model) return null;
  return inherited.has(model) ? inherited.get(model)! : settingsEffort(answer, model);
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

async function run(cmd: Extract<Command, { type: "start" }>): Promise<void> {
  // Only false turns the sandbox off, so a start without the field keeps it.
  const sandboxOn = cmd.sandbox !== false;
  const sandbox = sandboxSetup(sandboxOn, cmd.cwd);
  const start = startMode(cmd.permission_mode, cmd.permission_mode_chosen === true, sandboxOn && !sandbox.problem);
  const mode = start.mode;
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
  const notice = new SandboxNotice(
    (text) => emit({ type: "notice", level: "warn", text }),
    start,
    fallBack,
  );
  const options: Options = {
    ...sandbox.options,
    cwd: cmd.cwd,
    model: cmd.model,
    effort: cmd.effort,
    resume: await resumeTarget(cmd),
    permissionMode: mode,
    allowDangerouslySkipPermissions: mode === "bypassPermissions",
    includePartialMessages: true,
    // Foreground subagents send their text only with this.
    forwardSubagentText: true,
    hooks: {
      PreToolUse: preToolUse(previews.hook, guard),
    },
    systemPrompt: { type: "preset", preset: "claude_code", append: cmd.append_system_prompt },
    extraArgs: chromeArgs(cmd.chrome),
    mcpServers: { [SERVER]: editorServer(editor, { debug: cmd.debug === true }) },
    canUseTool: permissions.canUseTool,
    stderr: (data) => {
      process.stderr.write(data);
      notice.stderr(data);
    },
  };
  // After a resumed session's history, which draws the transcript again.
  notice.warn(sandbox.problem);
  inheriting = !cmd.effort;
  session = query({ prompt: inbox, options });
  sessionReady(session);
  // A resumed session shows how full it is before its first turn.
  void reportContext();
  session
    .supportedCommands()
    .then((commands) => emit(commandsEvent(commands)))
    .catch(() => {});
  // The effort picker needs the models' effort levels.
  session
    .supportedModels()
    .then((models) => emit(modelsEvent(models)))
    .catch(() => {});
  // The statusline names the login, so a work login and a personal one differ.
  session
    .accountInfo()
    .then((a) => emit({ type: "account", email: a.email }))
    .catch(() => {});
  const translator = new Translator();
  for await (const msg of session) {
    permissions.message(msg);
    for (const ev of translate(translator, msg)) emit(ev);
    if (msg.type === "result") {
      void reportContext();
      // A settings file can change the inherited effort meanwhile.
      void control(reportEffort);
    }
  }
}

export async function handle(cmd: Command): Promise<void> {
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
      inbox.push(
        cmd.text,
        imageBlocks(cmd.images ?? [], (text) => emit({ type: "notice", level: "warn", text })),
        cmd.id,
      );
      return;
    case "interrupt":
      await session?.interrupt();
      return;
    case "set_permission_mode":
      await session?.setPermissionMode(cmd.mode as PermissionMode);
      return;
    case "set_model":
      await control(async (q) => {
        await q.setModel(cmd.model);
        if (followSettings && !inheriting) await q.applyFlagSettings({ effortLevel: await defaultEffort(q) });
        await reportEffort(q);
      });
      return;
    case "set_effort":
      await control(async (q) => {
        followSettings = cmd.effort === null;
        // An inherited effort is the default already.
        if (!(followSettings && inheriting)) {
          const level = cmd.effort ?? (await defaultEffort(q));
          inheriting = false;
          // The flag layer, so the effort lasts for this session only, and no
          // settings file changes.
          await q.applyFlagSettings({ effortLevel: level });
        }
        await reportEffort(q);
      });
      return;
    case "list_models":
      await control(async (q) => emit(modelsEvent(await q.supportedModels())));
      return;
    case "usage":
      await control(async (q) => {
        try {
          // The SDK marks this call as one that may change in any release.
          emit(usageEvent(await q.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()));
        } catch (err) {
          emit({ type: "usage", error: String((err as Error)?.message ?? err) });
        }
      });
      return;
    case "context_usage":
      await control(async (q) => {
        try {
          emit(contextEvent(await q.getContextUsage({ detail: "full" })));
        } catch (err) {
          emit({ type: "context_usage", error: String((err as Error)?.message ?? err) });
        }
      });
      return;
    case "mcp_servers":
      await control(async (q) => {
        try {
          emit(mcpEvent(await q.mcpServerStatus()));
        } catch (err) {
          emit({ type: "mcp_servers", error: String((err as Error)?.message ?? err) });
        }
      });
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
          error = `Could not ${cmd.action} ${cmd.server}: ${(err as Error)?.message ?? err}`;
        }
        try {
          emit(mcpEvent(await q.mcpServerStatus(), error));
        } catch (err) {
          emit({ type: "mcp_servers", error: error ?? String((err as Error)?.message ?? err) });
        }
      });
      return;
    case "session_info":
      await control(async (q) => {
        try {
          const init = await q.initializationResult();
          emit(sessionInfoEvent(init.claude_code_version, await q.accountInfo(), await q.mcpServerStatus()));
        } catch (err) {
          emit({ type: "session_info", error: String((err as Error)?.message ?? err) });
        }
      });
      return;
    case "chrome":
      await control((q) => emitChrome(q));
      return;
    case "chrome_reconnect":
      await control(async (q) => {
        let message: ChromeMessage;
        try {
          await q.reconnectMcpServer(CHROME_SERVER);
          message = {
            text: "Reconnected to Claude in Chrome. Its browser tools are back in this session. If a browser action still doesn't work, check that Chrome is open and the extension is signed in.",
            level: "info",
          };
        } catch (err) {
          message = {
            text: `Could not reconnect Claude in Chrome: ${errorText(err)} Select "Reconnect extension" to try again, or open /mcp and select claude-in-chrome for details.`,
            level: "error",
          };
        }
        await emitChrome(q, message);
      });
      return;
    case "chrome_default":
      await control(async (q) => {
        let message: ChromeMessage | undefined;
        try {
          await setEnabledByDefault(cmd.enabled);
        } catch (err) {
          message = { text: `The setting was not saved: ${errorText(err)}`, level: "error" };
        }
        await emitChrome(q, message);
      });
      return;
    case "chrome_browsers":
      await control(async (q) => {
        try {
          emit(browsersEvent((await chromeCalls(q).getChromeBrowsers()).browsers));
        } catch (err) {
          emit({ type: "chrome_browsers", error: errorText(err) });
        }
      });
      return;
    case "chrome_select":
      await control(async (q) => {
        let message: ChromeMessage | undefined;
        try {
          const { name } = await chromeCalls(q).selectChromeBrowser(cmd.device_id);
          if (name) message = { text: `Now using browser "${name}" for Chrome actions.`, level: "info" };
        } catch (err) {
          message = { text: `Couldn't switch browser: ${errorText(err)}`, level: "error" };
        }
        await emitChrome(q, message);
      });
      return;
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

// Bun runs no exit handlers on SIGTERM, so the SDK would leave Claude Code
// running. A restart of a hung sidecar sends SIGTERM.
function shutdown(): void {
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
      emit({ type: "notice", level: "error", text: `bad command: ${line.slice(0, 200)}` });
      return;
    }
    handle(cmd).catch((err) => emit({ type: "notice", level: "error", text: String(err?.message ?? err) }));
  });
  rl.on("close", shutdown);
  process.on("SIGTERM", shutdown);
}
