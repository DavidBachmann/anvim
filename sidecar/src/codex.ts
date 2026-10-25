// Codex agents: the codex editor tool (tools.ts) starts OpenAI's Codex CLI in
// the background. Its JSONL stream becomes the protocol events of a
// subagent, so the plugin shows it as one. When it exits, its result goes to
// Claude as a task notification, as a background agent's end does.
import { isAbsolute, relative, resolve } from "node:path";
import type { Event } from "./protocol";
import { truncate } from "./translate";

// The agent type that the plugin names the agent by: Codex 1.
export const CODEX_TYPE = "Codex";
// A tool result or a reply can be long.
const MAX_AGENT_TEXT = 8000;
const MAX_RESULT = 50_000;
const STDERR_TAIL = 2000;

type Item = Record<string, any>;
type Change = { path: string; kind: string };

// Codex runs each command through the user's shell: /bin/zsh -lc 'cat a.txt'.
// The plugin reads the files that a command reads, so it needs the command.
export function unwrapShell(command: string): string {
  const m = command.match(/^\S*\/(?:ba|z|da)?sh -l?c ([\s\S]+)$/);
  if (!m) return command;
  const arg = m[1]!;
  if (/^'[\s\S]*'$/.test(arg)) return arg.slice(1, -1).replace(/'(?:\\'|"'")'/g, "'");
  if (/^"[\s\S]*"$/.test(arg)) return arg.slice(1, -1).replace(/\\(["\\$`])/g, "$1");
  return arg;
}

// Turns one Codex run's stream into the events of agent `agentId`. Its tool
// calls have the codex tool call as parent, as a subagent's calls have the
// Agent tool call.
export class CodexStream {
  private started = new Set<string>();
  private toolUses = 0;
  private tokens?: number;
  private lastText = "";
  private lastError = "";

  constructor(
    readonly agentId: string,
    readonly toolUseId: string,
    private cwd: string,
  ) {}

  line(raw: string): Event[] {
    let m: Item;
    try {
      m = JSON.parse(raw);
    } catch {
      return [];
    }
    const out: Event[] = [];
    if (m.type === "item.started" || m.type === "item.completed") {
      this.item(m.item ?? {}, m.type === "item.completed", out);
    } else if (m.type === "turn.completed" && m.usage) {
      // OpenAI counts the cached input in input_tokens.
      const tokens = (m.usage.input_tokens ?? 0) + (m.usage.output_tokens ?? 0);
      this.tokens = tokens;
      out.push({ type: "agent_context", agent_id: this.agentId, tokens });
    } else if (m.type === "turn.failed") {
      this.lastError = String(m.error?.message ?? "the turn failed");
    } else if (m.type === "error") {
      this.lastError = String(m.message ?? "");
    }
    return out;
  }

  private item(item: Item, done: boolean, out: Event[]): void {
    const id = `${this.agentId}:${item.id}`;
    if (item.type === "agent_message" && done && typeof item.text === "string" && item.text.trim()) {
      this.lastText = item.text.trim();
      out.push({
        type: "agent_text",
        agent_id: this.agentId,
        parent_id: this.toolUseId,
        text: truncate(item.text, MAX_AGENT_TEXT),
      });
    } else if (item.type === "error" && typeof item.message === "string") {
      this.lastError = item.message;
    } else if (item.type === "command_execution" && typeof item.command === "string") {
      const command = unwrapShell(item.command);
      this.use(id, "Bash", { command }, `Running ${truncate(command.split("\n")[0]!, 60)}`, out);
      if (!done) return;
      const code = item.exit_code;
      const failed = item.status !== "completed" || (typeof code === "number" && code !== 0);
      const output = String(item.aggregated_output ?? "");
      const text = failed && typeof code === "number" ? `Exit code ${code}\n${output}` : output;
      this.result(id, failed, text, out);
    } else if (item.type === "file_change" && Array.isArray(item.changes)) {
      item.changes.forEach((change: Change, i: number) => {
        const path = isAbsolute(change.path) ? change.path : resolve(this.cwd, change.path);
        const name = this.display(path);
        const call = `${id}:${i}`;
        // A change carries no text. The buffer reloads from disk after the
        // result, so an Edit without old and new text shows the file.
        if (change.kind === "add") this.use(call, "Write", { file_path: path }, `Creating ${name}`, out);
        else if (change.kind === "delete") this.use(call, "Bash", { command: `rm ${name}` }, `Deleting ${name}`, out);
        else this.use(call, "Edit", { file_path: path }, `Editing ${name}`, out);
        if (!done) return;
        const verb = change.kind === "add" ? "Created" : change.kind === "delete" ? "Deleted" : "Updated";
        const failed = item.status !== "completed";
        this.result(call, failed, failed ? `Could not change ${name}` : `${verb} ${name}`, out);
      });
    }
  }

  // An item can arrive completed without having started.
  private use(id: string, name: string, input: Record<string, unknown>, description: string, out: Event[]): void {
    if (this.started.has(id)) return;
    this.started.add(id);
    this.toolUses++;
    out.push({
      type: "agent_progress",
      agent_id: this.agentId,
      description,
      tool_uses: this.toolUses,
      ...(this.tokens !== undefined ? { tokens: this.tokens } : {}),
      last_tool: name,
    });
    out.push({ type: "tool_use", id, name, input, parent_id: this.toolUseId, agent_id: this.agentId });
  }

  private result(id: string, isError: boolean, text: string, out: Event[]): void {
    out.push({
      type: "tool_result",
      id,
      is_error: isError,
      text: truncate(text),
      parent_id: this.toolUseId,
      agent_id: this.agentId,
    });
  }

  private display(path: string): string {
    const rel = relative(this.cwd, path);
    return rel && !rel.startsWith("..") && !isAbsolute(rel) ? rel : path;
  }

  // The agent's end, and the notification that tells Claude its result.
  end(run: { description: string; code: number; stderr: string; durationMs: number }): {
    event: Event;
    notification: string;
  } {
    const ok = run.code === 0;
    const failure = ok
      ? ""
      : [`Codex exited with code ${run.code}.`, this.lastError, run.stderr.trim().slice(-STDERR_TAIL)]
          .filter(Boolean)
          .join("\n");
    const result = [this.lastText, failure].filter(Boolean).join("\n\n") || "Codex ended without a reply.";
    const usage = { tool_uses: this.toolUses, tokens: this.tokens, duration_ms: run.durationMs };
    return {
      event: {
        type: "agent_end",
        agent_id: this.agentId,
        tool_use_id: this.toolUseId,
        status: ok ? "completed" : "failed",
        summary: truncate(ok ? result : failure),
        ...usage,
      },
      notification: notification({
        id: this.agentId,
        toolUseId: this.toolUseId,
        status: ok ? "completed" : "failed",
        description: run.description,
        result: result.slice(0, MAX_RESULT),
        ...usage,
      }),
    };
  }
}

// As Claude Code words a background agent's end, so that a resumed session
// draws it as one (sessions.ts).
export function notification(n: {
  id: string;
  toolUseId: string;
  status: "completed" | "failed";
  description: string;
  result: string;
  tool_uses: number;
  tokens?: number;
  duration_ms: number;
}): string {
  const usage = [
    n.tokens !== undefined ? `<total_tokens>${n.tokens}</total_tokens>` : "",
    `<tool_uses>${n.tool_uses}</tool_uses>`,
    `<duration_ms>${n.duration_ms}</duration_ms>`,
  ].join("");
  return [
    "<task-notification>",
    `<task-id>${n.id}</task-id>`,
    `<tool-use-id>${n.toolUseId}</tool-use-id>`,
    `<status>${n.status}</status>`,
    `<summary>Agent "${n.description}" ${n.status === "completed" ? "finished" : "failed"}</summary>`,
    "<note>This is the Codex agent that the codex tool started. It cannot be continued: start a new one for more work.</note>",
    `<result>${n.result}</result>`,
    `<usage>${usage}</usage>`,
    "</task-notification>",
  ].join("\n");
}

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

async function tail(stream: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of stream) text = (text + decoder.decode(chunk, { stream: true })).slice(-STDERR_TAIL);
  return text;
}

export type CodexInput = { description: string; prompt: string; read_only?: boolean };

export type CodexState = "on" | "off" | "missing" | "logged_out";

const LOGIN_TIMEOUT_MS = 3000;

// `codex login status` exits 0 when Codex has a login. A timeout or an error
// counts as no login.
async function loggedIn(bin: string): Promise<boolean> {
  try {
    const proc = Bun.spawn([bin, "login", "status"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
    const timer = setTimeout(() => proc.kill(), LOGIN_TIMEOUT_MS);
    const code = await proc.exited;
    clearTimeout(timer);
    return code === 0;
  } catch {
    return false;
  }
}

// Whether Claude gets the codex tool: the user did not turn it off, and a
// codex CLI with a login is on PATH. Without a login, every run would fail.
export async function codexState(
  wanted: boolean,
  which: (cmd: string) => string | null = (cmd) => Bun.which(cmd),
  login: (bin: string) => Promise<boolean> = loggedIn,
): Promise<{ state: CodexState; bin?: string }> {
  if (!wanted) return { state: "off" };
  const bin = which("codex");
  if (!bin) return { state: "missing" };
  return (await login(bin)) ? { state: "on", bin } : { state: "logged_out" };
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
    },
  ) {}

  // Returns at once. The run goes on in the background.
  start(input: CodexInput, toolUseId: string | undefined): { id: string } {
    const id = `codex-${this.stamp}-${this.next++}`;
    const { bin, cwd, emit } = this.opts;
    const stream = new CodexStream(id, toolUseId ?? id, cwd);
    const sandbox = input.read_only ? "read-only" : "workspace-write";
    const proc = Bun.spawn([bin, "exec", "--json", "-C", cwd, "-s", sandbox, "--skip-git-repo-check", "-"], {
      cwd,
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
    });
    const started = Date.now();
    const stderr = tail(proc.stderr);
    void (async () => {
      for await (const line of lines(proc.stdout)) {
        if (run.killed) break;
        for (const ev of stream.line(line)) emit(ev);
      }
      const code = await proc.exited;
      this.runs.delete(id);
      // A reset or an exit stopped it. Nobody waits for its result.
      if (run.killed) return;
      const end = stream.end({
        description: input.description,
        code,
        stderr: await stderr,
        durationMs: Date.now() - started,
      });
      emit(end.event);
      this.opts.notify(end.notification);
    })().catch((err) => process.stderr.write(`codex run ${id} failed: ${err}\n`));
    return { id };
  }

  stopAll(): void {
    for (const run of this.runs.values()) {
      run.killed = true;
      run.proc.kill();
    }
    this.runs.clear();
  }

  get running(): number {
    return this.runs.size;
  }
}
