// Codex agents: the codex editor tool (tools.ts) starts OpenAI's Codex CLI in
// the background. Its JSONL stream becomes the protocol events of a
// subagent (codexstream.ts), so the plugin shows it as one. When it exits,
// its result goes to Claude as a task notification, as a background agent's
// end does.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { CodexStream } from "./codexstream";
import type { Event } from "./protocol";
import { type AnyRecord, tail } from "./text";

// The agent type that the plugin names the agent by: Codex 1.
const CODEX_TYPE = "Codex";
const STDERR_TAIL = 2000;

async function* lines(stream: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let buf = "";
  for await (const chunk of stream) {
    buf += decoder.decode(chunk, { stream: true });
    let at: number;
    while ((at = buf.indexOf("\n")) >= 0) {
      yield buf.slice(0, at);
      buf = buf.slice(at + 1);
    }
  }
  buf += decoder.decode();
  if (buf.trim()) yield buf;
}

async function readTail(stream: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of stream) text = tail(text + decoder.decode(chunk, { stream: true }), STDERR_TAIL);
  return text;
}

export type CodexInput = {
  description: string;
  prompt: string;
  read_only?: boolean;
  model?: string;
  effort?: string;
  mcp_servers?: string[];
};

// An MCP server of Claude's session that a run gets, as a stdio server of its
// own. Codex passes such a server only a short list of env vars, so env holds
// every var that the server needs from anvim's env.
export type CodexServer = { name: string; command: string; args: string[]; env: Record<string, string> };

// A model and a reasoning effort. Each one is unset when nobody chose it.
export type CodexSettings = { model?: string; effort?: string };

function setting(value: unknown): string | undefined {
  return typeof value === "string" && value !== "" ? value : undefined;
}

// The top-level keys of Codex's config.toml, which a run without flags uses.
// anvim passes no flag for them: Codex reads its own config.
export function codexConfig(): CodexSettings {
  const home = process.env.CODEX_HOME || join(homedir(), ".codex");
  try {
    const toml = Bun.TOML.parse(readFileSync(join(home, "config.toml"), "utf8")) as Record<string, unknown>;
    // A profile's keys win inside Codex, so the top-level ones would mislead.
    if (toml.profile !== undefined) return {};
    return { model: setting(toml.model), effort: setting(toml.model_reasoning_effort) };
  } catch {
    return {};
  }
}

// Codex parses each -c value as TOML. A JSON string is also a TOML string, and
// a JSON array of strings is also a TOML array. "approve" lets Codex call the
// server's tools without an approval prompt.
function serverArgs(servers: CodexServer[]): string[] {
  return servers.flatMap(({ name, command, args, env }) => {
    const table = Object.entries(env).map(([key, value]) => `${JSON.stringify(key)}=${JSON.stringify(value)}`);
    return [
      `command=${JSON.stringify(command)}`,
      `args=${JSON.stringify(args)}`,
      `env={${table.join(",")}}`,
      'default_tools_approval_mode="approve"',
    ].flatMap((setting) => ["-c", `mcp_servers.${name}.${setting}`]);
  });
}

export function codexArgs(
  bin: string,
  cwd: string,
  readOnly: boolean,
  settings: CodexSettings,
  servers: CodexServer[] = [],
): string[] {
  const { model, effort } = settings;
  return [
    bin,
    "exec",
    "--json",
    "-C",
    cwd,
    "-s",
    readOnly ? "read-only" : "workspace-write",
    ...(model ? ["-m", model] : []),
    // A TOML string, so that no level parses as another type.
    ...(effort ? ["-c", `model_reasoning_effort=${JSON.stringify(effort)}`] : []),
    ...serverArgs(servers),
    "--skip-git-repo-check",
    "-",
  ];
}

// Where a run's model or effort comes from: the tool call, anvim's default,
// Codex's config, or Codex's own default, which anvim does not know.
type Source = "call" | "anvim" | "config" | "codex";
export type RunSettings = { model?: string; modelFrom: Source; effort?: string; effortFrom: Source };

function pick(call: unknown, anvim: unknown, config: unknown): [string | undefined, Source] {
  const values: [unknown, Source][] = [
    [call, "call"],
    [anvim, "anvim"],
    [config, "config"],
  ];
  for (const [value, from] of values) {
    const set = setting(value);
    if (set) return [set, from];
  }
  return [undefined, "codex"];
}

// The call's input wins over anvim's defaults, field by field, and anvim's
// defaults win over Codex's config.
export function runSettings(input: CodexInput, defaults: CodexSettings, config: CodexSettings): RunSettings {
  const [model, modelFrom] = pick(input.model, defaults.model, config.model);
  const [effort, effortFrom] = pick(input.effort, defaults.effort, config.effort);
  return { model, modelFrom, effort, effortFrom };
}

function describeSetting(what: "model" | "effort", value: string | undefined, from: Source): string {
  if (from === "codex" || !value) return `Codex's default ${what}`;
  const source = {
    call: "from the call",
    anvim: `anvim's default, set with /codex-${what}`,
    config: "from Codex's config",
  }[from];
  return `${what} ${value} (${source})`;
}

export function describeRun(run: RunSettings): string {
  const model = describeSetting("model", run.model, run.modelFrom);
  return `${model} and ${describeSetting("effort", run.effort, run.effortFrom)}`;
}

// A model in Codex's model list, as far as anvim needs it. slug is the name
// that `codex exec -m` takes.
export type CodexModel = { slug: string; name: string; hidden: boolean; efforts: string[] };

export const listed = (m: CodexModel) => (m.name === m.slug ? m.slug : `${m.slug} (${m.name})`);

export function visibleModels(models: CodexModel[]): CodexModel[] {
  return models.filter((m) => !m.hidden);
}

// The visible models' levels, in the order Codex lists them.
export function modelEfforts(models: CodexModel[]): string[] {
  return [...new Set(visibleModels(models).flatMap((m) => m.efforts))];
}

// Why the codex tool must not start this run, or undefined. Only the call's
// own model and effort are checked: Claude can fix those.
function checkRun(run: RunSettings, models: CodexModel[]): string | undefined {
  if (run.modelFrom === "call" && !models.some((m) => m.slug === run.model)) {
    const slugs = visibleModels(models).map(listed).join(", ");
    return `Codex has no model ${run.model}. Pass one of these slugs as model: ${slugs}.`;
  }
  const effort = run.effortFrom === "call" ? run.effort : undefined;
  const known = models.find((m) => m.slug === run.model);
  if (effort && known && known.efforts.length > 0 && !known.efforts.includes(effort)) {
    return `Codex model ${known.slug} has no effort ${effort}. Pass one of: ${known.efforts.join(", ")}.`;
  }
  return undefined;
}

function toModel(item: unknown): CodexModel | undefined {
  if (typeof item !== "object" || item === null) return undefined;
  const m = item as AnyRecord;
  const slug = setting(m.model) ?? setting(m.id);
  if (!slug) return undefined;
  const efforts: string[] = Array.isArray(m.supportedReasoningEfforts)
    ? m.supportedReasoningEfforts.flatMap(
        (e: unknown) => setting(typeof e === "object" && e !== null ? (e as AnyRecord).reasoningEffort : e) ?? [],
      )
    : [];
  return { slug, name: setting(m.displayName) ?? slug, hidden: m.hidden === true, efforts };
}

type CodexState = "on" | "off" | "missing" | "logged_out";

const LOGIN_TIMEOUT_MS = 3000;
const MAX_MODEL_PAGES = 5;

// Asks `codex app-server`, the JSON-RPC server of Codex's IDE clients, for
// its model list. The list depends on the login, so it runs with the real
// Codex home, as `codex exec` does. Any failure gives undefined.
export async function codexModels(bin: string, timeoutMs = LOGIN_TIMEOUT_MS): Promise<CodexModel[] | undefined> {
  let proc: Bun.Subprocess<"pipe", "pipe", "ignore">;
  try {
    proc = Bun.spawn([bin, "app-server"], { stdin: "pipe", stdout: "pipe", stderr: "ignore" });
  } catch {
    return undefined;
  }
  const send = (msg: object) => {
    proc.stdin.write(`${JSON.stringify(msg)}\n`);
    proc.stdin.flush();
  };
  const replies = lines(proc.stdout);
  let next = 0;
  // A request's result, or undefined for an error or a closed stream.
  const request = async (method: string, params: object): Promise<AnyRecord | undefined> => {
    const id = next++;
    send({ method, id, params });
    for (let r = await replies.next(); !r.done; r = await replies.next()) {
      let m: AnyRecord;
      try {
        m = JSON.parse(r.value);
      } catch {
        continue;
      }
      // Notifications and server requests can come in between.
      if (m?.id !== id || m.method !== undefined) continue;
      return typeof m.result === "object" && m.result !== null ? m.result : undefined;
    }
    return undefined;
  };
  const talk = async (): Promise<CodexModel[] | undefined> => {
    if (!(await request("initialize", { clientInfo: { name: "anvim", title: "anvim", version: "0" } }))) return undefined;
    send({ method: "initialized" });
    const models: CodexModel[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < MAX_MODEL_PAGES; page++) {
      const result = await request("model/list", { includeHidden: true, cursor });
      if (!result || !Array.isArray(result.data)) return undefined;
      for (const item of result.data) {
        const model = toModel(item);
        if (model) models.push(model);
      }
      cursor = setting(result.nextCursor);
      if (!cursor) break;
    }
    return models.length > 0 ? models : undefined;
  };
  let timer: Timer | undefined;
  const timeout = new Promise<undefined>((resolve) => {
    timer = setTimeout(() => resolve(undefined), timeoutMs);
  });
  try {
    return await Promise.race([talk().catch(() => undefined), timeout]);
  } finally {
    clearTimeout(timer);
    proc.kill();
  }
}

// `codex login status` exits 0 when Codex has a login. A timeout or an error
// counts as no login.
async function loggedIn(bin: string): Promise<boolean> {
  try {
    const proc = Bun.spawn([bin, "login", "status"], {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
      timeout: LOGIN_TIMEOUT_MS,
    });
    return (await proc.exited) === 0;
  } catch {
    return false;
  }
}

// Whether Claude gets the codex tool: the user asked for it, and a codex CLI
// with a login is on PATH. Without a login, every run would fail. The model
// list is read at the same time, and counts only with a login.
export async function codexState(
  wanted: boolean,
  which: (cmd: string) => string | null = (cmd) => Bun.which(cmd),
  login: (bin: string) => Promise<boolean> = loggedIn,
  list: (bin: string) => Promise<CodexModel[] | undefined> = codexModels,
): Promise<{ state: CodexState; bin?: string; models?: CodexModel[] }> {
  if (!wanted) return { state: "off" };
  const bin = which("codex");
  if (!bin) return { state: "missing" };
  const [ok, models] = await Promise.all([login(bin), list(bin)]);
  if (!ok) return { state: "logged_out" };
  return { state: "on", bin, models };
}

// The user asked for Codex, so a Codex that is not ready gets a warning.
export function codexWarning(state: CodexState, models?: CodexModel[]): string | undefined {
  if (state === "missing") return "You started anvim with --codex, but no codex command is on PATH.";
  if (state === "logged_out")
    return "You started anvim with --codex, but Codex is not logged in. Run `codex login`, then restart anvim.";
  if (state === "on" && !models)
    return "Codex is on, but anvim could not read its model list, so it does not check model names.";
  return undefined;
}

// The running Codex processes of the session.
export class CodexRunner {
  private runs = new Map<string, { proc: Bun.Subprocess; killed: boolean }>();
  private next = 1;
  // A resumed session runs in a new sidecar, and its notifications must not
  // repeat an earlier run's task id.
  private stamp = Date.now().toString(36);

  constructor(
    private opts: {
      bin: string;
      cwd: string;
      emit: (ev: Event) => void;
      // Hands Claude the end of a run, as a message of its own.
      notify: (text: string) => void;
      // anvim's defaults now, which the user can change between runs.
      defaults: () => CodexSettings;
      config?: () => CodexSettings;
      // Codex's model list, when anvim could read it.
      models?: CodexModel[];
      // The MCP servers of Claude's session that a run can get, by name. Each
      // one gives the server at call time, or the reason that it cannot.
      servers?: Record<string, () => Promise<CodexServer | string>>;
    },
  ) {}

  get models(): CodexModel[] | undefined {
    return this.opts.models;
  }

  private config(): CodexSettings {
    return (this.opts.config ?? codexConfig)();
  }

  // Why the call must not start a run, or undefined. Without a model list,
  // anvim checks nothing.
  check(input: CodexInput): string | undefined {
    const { models } = this.opts;
    return models ? checkRun(runSettings(input, this.opts.defaults(), this.config()), models) : undefined;
  }

  // The servers that the call names, or the first reason that one of them
  // cannot go to Codex.
  async handOver(names: string[] = []): Promise<CodexServer[] | string> {
    const offered = this.opts.servers ?? {};
    const unknown = names.filter((name) => !Object.hasOwn(offered, name));
    if (unknown.length > 0) {
      const known = Object.keys(offered);
      const can = known.length > 0 ? `It can hand over only ${known.join(", ")}.` : "It can hand over no MCP server.";
      return `anvim cannot hand ${unknown.join(", ")} to Codex. ${can}`;
    }
    const servers: CodexServer[] = [];
    for (const name of new Set(names)) {
      const server = await offered[name]!();
      if (typeof server === "string") return server;
      servers.push(server);
    }
    return servers;
  }

  // Returns at once. The run goes on in the background.
  start(
    input: CodexInput,
    toolUseId: string | undefined,
    servers: CodexServer[] = [],
  ): { id: string; run: RunSettings } {
    const id = `codex-${this.stamp}-${this.next++}`;
    const { bin, cwd, emit } = this.opts;
    const stream = new CodexStream(id, toolUseId ?? id, cwd);
    const defaults = this.opts.defaults();
    const settings = runSettings(input, defaults, this.config());
    // Codex reads its own config, so the flags leave it out.
    const flags = runSettings(input, defaults, {});
    const proc = Bun.spawn(codexArgs(bin, cwd, input.read_only === true, flags, servers), {
      cwd,
      // Inside cmux, `codex` is cmux's wrapper. Its hooks call the cmux app
      // on every tool call, which drops them, and a burst of them once
      // crashed cmux. The variable makes the wrapper run plain Codex.
      env: { ...process.env, CMUX_CODEX_HOOKS_DISABLED: "1" },
      stdin: new Blob([input.prompt]),
      stdout: "pipe",
      stderr: "pipe",
    });
    const run = { proc, killed: false };
    this.runs.set(id, run);
    emit({
      type: "agent_start",
      agent_id: id,
      tool_use_id: stream.toolUseId,
      description: input.description,
      subagent_type: CODEX_TYPE,
      depth: 1,
      background: true,
      // What the run uses, for the Overview.
      model: settings.model,
      effort: settings.effort,
    });
    const started = Date.now();
    const stderr = readTail(proc.stderr);
    const { description } = input;
    void (async () => {
      for await (const line of lines(proc.stdout)) {
        if (run.killed) break;
        for (const ev of stream.line(line)) emit(ev);
      }
      const code = await proc.exited;
      this.runs.delete(id);
      // A reset or an exit stopped it. Nobody waits for its result.
      if (run.killed) return;
      const end = stream.end({ description, code, stderr: await stderr, durationMs: Date.now() - started });
      emit(end.event);
      this.opts.notify(end.notification);
    })().catch((err) => process.stderr.write(`codex run ${id} failed: ${err}\n`));
    return { id, run: settings };
  }

  stopAll(): void {
    for (const run of this.runs.values()) {
      run.killed = true;
      run.proc.kill();
    }
    this.runs.clear();
  }
}
