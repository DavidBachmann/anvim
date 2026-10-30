// The stream of one Codex run: its JSONL output becomes the protocol events of
// a subagent, and its end becomes a task notification for Claude.
import { isAbsolute, relative, resolve } from "node:path";
import type { Event } from "./protocol";
import { type AnyRecord, head, MAX_AGENT_TEXT, resultText, truncate } from "./text";

// The result that goes to Claude can be long.
const MAX_RESULT = 50_000;

type Item = AnyRecord;
type Change = { path: string; kind: string };
type AgentEnd = Extract<Event, { type: "agent_end" }>;

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
    try {
      this.message(m, out);
    } catch (err) {
      // A line that anvim cannot read must not end the run. The events before
      // the error still go out, because their calls count as started.
      process.stderr.write(`could not read a Codex line: ${(err as Error)?.stack ?? err}\n`);
    }
    return out;
  }

  private message(m: Item, out: Event[]): void {
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
  }

  private item(item: Item, done: boolean, out: Event[]): void {
    const id = `${this.agentId}:${item.id}`;
    switch (item.type) {
      case "agent_message":
        return this.agentMessage(item, done, out);
      case "error":
        if (typeof item.message === "string") this.lastError = item.message;
        return;
      case "command_execution":
        return this.command(id, item, done, out);
      case "file_change":
        return this.fileChange(id, item, done, out);
      case "mcp_tool_call":
        return this.mcpCall(id, item, done, out);
    }
  }

  private agentMessage(item: Item, done: boolean, out: Event[]): void {
    if (!done || typeof item.text !== "string" || !item.text.trim()) return;
    this.lastText = item.text.trim();
    out.push({
      type: "agent_text",
      agent_id: this.agentId,
      parent_id: this.toolUseId,
      text: truncate(item.text, MAX_AGENT_TEXT),
    });
  }

  private command(id: string, item: Item, done: boolean, out: Event[]): void {
    if (typeof item.command !== "string") return;
    const command = unwrapShell(item.command);
    this.use(id, "Bash", { command }, `Running ${truncate(command.split("\n")[0]!, 60)}`, out);
    if (!done) return;
    const code = item.exit_code;
    const failed = item.status !== "completed" || (typeof code === "number" && code !== 0);
    const output = String(item.aggregated_output ?? "");
    const text = failed && typeof code === "number" ? `Exit code ${code}\n${output}` : output;
    this.result(id, failed, text, out);
  }

  private fileChange(id: string, item: Item, done: boolean, out: Event[]): void {
    if (!Array.isArray(item.changes)) return;
    const failed = item.status !== "completed";
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
      this.result(call, failed, failed ? `Could not change ${name}` : `${verb} ${name}`, out);
    });
  }

  private mcpCall(id: string, item: Item, done: boolean, out: Event[]): void {
    if (typeof item.server !== "string" || typeof item.tool !== "string") return;
    // The name that Claude's own call of the tool has.
    const name = `mcp__${item.server}__${item.tool}`;
    const input = typeof item.arguments === "object" && item.arguments !== null ? item.arguments : {};
    this.use(id, name, input, `Calling ${item.server} ${item.tool}`, out);
    if (!done) return;
    const res: Item = typeof item.result === "object" && item.result !== null ? item.result : {};
    const error = typeof item.error === "string" ? item.error : item.error?.message;
    const failed = item.status !== "completed" || item.error != null || res.isError === true || res.is_error === true;
    const image = Array.isArray(res.content) && res.content.some((part: Item) => part?.type === "image");
    const text = (typeof error === "string" && error) || resultText(res.content) || (image ? "[Image]" : "");
    this.result(id, failed, text, out);
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
      tokens: this.tokens,
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

  // The agent's end, and the notification that tells Claude its result. The
  // runner gives the tail of the run's stderr.
  end(run: { description: string; code: number; stderr: string; durationMs: number }): {
    event: AgentEnd;
    notification: string;
  } {
    const ok = run.code === 0;
    const failure = ok
      ? ""
      : [`Codex exited with code ${run.code}.`, this.lastError, run.stderr.trim()].filter(Boolean).join("\n");
    const result = [this.lastText, failure].filter(Boolean).join("\n\n") || "Codex ended without a reply.";
    const event: AgentEnd = {
      type: "agent_end",
      agent_id: this.agentId,
      tool_use_id: this.toolUseId,
      status: ok ? "completed" : "failed",
      summary: truncate(ok ? result : failure),
      tool_uses: this.toolUses,
      tokens: this.tokens,
      duration_ms: run.durationMs,
    };
    return { event, notification: notification(event, run.description, head(result, MAX_RESULT)) };
  }
}

// As Claude Code words a background agent's end, so that a resumed session
// draws it as one (sessions.ts).
function notification(end: AgentEnd, description: string, result: string): string {
  const usage = [
    end.tokens !== undefined ? `<total_tokens>${end.tokens}</total_tokens>` : "",
    `<tool_uses>${end.tool_uses}</tool_uses>`,
    `<duration_ms>${end.duration_ms}</duration_ms>`,
  ].join("");
  return [
    "<task-notification>",
    `<task-id>${end.agent_id}</task-id>`,
    `<tool-use-id>${end.tool_use_id}</tool-use-id>`,
    `<status>${end.status}</status>`,
    `<summary>Agent "${description}" ${end.status === "completed" ? "finished" : "failed"}</summary>`,
    "<note>This is the Codex agent that the codex tool started. It cannot be continued: start a new one for more work.</note>",
    `<result>${result}</result>`,
    `<usage>${usage}</usage>`,
    "</task-notification>",
  ].join("\n");
}
