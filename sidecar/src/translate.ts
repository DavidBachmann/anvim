import type { SDKMessage, SlashCommand as SdkSlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { FieldStream } from "./fieldstream";
import type { Event } from "./protocol";
import {
  type AnyRecord,
  commandOutput,
  MAX_AGENT_TEXT,
  readResult,
  resultText,
  truncate,
  truncateOutput,
} from "./text";

// Claude Code's model name on the messages that it writes itself, such as a
// slash command's output.
const SYNTHETIC = "<synthetic>";

type Block =
  | { type: "text" }
  | { type: "thinking" }
  | { type: "tool_use"; id: string; name: string; fields: FieldStream }
  | { type: "other" };

// A subagent's model, the tokens in its context after its last response, and
// the window that its last agent_context used.
type AgentContext = { model: string; tokens: number; max?: number };

// A message of the main agent's own conversation. Background subagents send
// their messages between the main agent's turns too, as do the task messages
// that report on them.
export function mainThread(m: AnyRecord): boolean {
  if (m.parent_tool_use_id != null || m.agent_id) return false;
  return !(m.type === "system" && (m.subtype?.startsWith("task_") || m.subtype === "background_tasks_changed"));
}

// Turns the SDK message stream into anvim events. Stateful: it tracks the
// open content blocks of the main session's current message.
export class Translator {
  private blocks = new Map<number, Block>();
  private inTurn = false;
  // /compact prints "Compacted" after the compact boundary, which says more.
  private compacted = false;
  // The task ids of running subagents. Only task_started names a task's type,
  // and shells and other tasks send task messages too.
  private agents = new Set<string>();
  // The running agents that started in the background.
  private background = new Set<string>();
  // The subagent Read calls that wait for their result. A subagent's result
  // has no tool_use_result, so a Read's line count comes from its text.
  private agentReads = new Set<string>();
  // The context window of each model, from the turns' results.
  private windows = new Map<string, number>();
  // The main agent's window, for a model that no result named yet.
  defaultWindow?: number;
  private contexts = new Map<string, AgentContext>();

  translate(msg: SDKMessage): Event[] {
    const m = msg as AnyRecord;
    const out: Event[] = [];
    if (!this.inTurn && (m.type === "stream_event" || m.type === "assistant") && mainThread(m)) {
      this.inTurn = true;
      out.push({ type: "turn_start" });
    }
    switch (m.type) {
      case "system":
        this.system(m, out);
        break;
      case "conversation_reset":
        this.contexts.clear();
        out.push({ type: "reset" });
        break;
      case "command_lifecycle":
        if (typeof m.command_uuid === "string") out.push({ type: "prompt_state", id: m.command_uuid, state: String(m.state) });
        break;
      case "stream_event":
        if (m.parent_tool_use_id == null) this.streamEvent(m.event, out);
        break;
      case "assistant":
        this.assistant(m, out);
        break;
      case "user":
        this.user(m, out);
        break;
      case "result":
        this.result(m, out);
        break;
    }
    return out;
  }

  private system(m: AnyRecord, out: Event[]): void {
    switch (m.subtype) {
      case "init":
        out.push({
          type: "init",
          session_id: m.session_id,
          model: m.model,
          cwd: m.cwd,
          permission_mode: m.permissionMode,
          version: m.claude_code_version,
          slash_commands: m.slash_commands ?? [],
          terminal_slash_commands: Array.isArray(m.terminal_slash_commands) ? m.terminal_slash_commands : undefined,
        });
        break;
      case "commands_changed":
        if (Array.isArray(m.commands)) out.push(commandsEvent(m.commands));
        break;
      case "local_command_output":
        if (typeof m.content === "string" && m.content.trim()) out.push({ type: "output", text: truncateOutput(m.content.trim()) });
        break;
      case "status":
        out.push({ type: "status", status: m.status ?? null, permission_mode: m.permissionMode });
        if (m.compact_result === "failed") {
          out.push({ type: "notice", level: "error", text: `Compaction failed: ${m.compact_error ?? "no reason given"}` });
        }
        break;
      case "compact_boundary": {
        const meta = m.compact_metadata ?? {};
        this.compacted = true;
        out.push({ type: "compact", trigger: meta.trigger ?? "auto", pre_tokens: meta.pre_tokens, post_tokens: meta.post_tokens });
        break;
      }
      case "api_retry":
        out.push({
          type: "notice",
          level: "warn",
          text: `API retry ${m.attempt}/${m.max_retries} in ${Math.round(m.retry_delay_ms / 1000)}s`,
        });
        break;
      case "background_tasks_changed":
        this.backgroundTasks(m, out);
        break;
      default:
        if (m.subtype?.startsWith("task_")) this.task(m, out);
    }
  }

  // An ambient task is housekeeping, which Claude Code shows no activity for.
  // The list of background tasks is the level signal: a background agent that
  // left it has ended, even when its task_notification never came.
  private backgroundTasks(m: AnyRecord, out: Event[]): void {
    const live = new Set((m.tasks ?? []).map((t: AnyRecord) => t.task_id));
    for (const id of this.background) {
      if (live.has(id)) continue;
      this.background.delete(id);
      this.agents.delete(id);
      out.push({ type: "agent_end", agent_id: id, status: "completed" });
    }
  }

  private task(m: AnyRecord, out: Event[]): void {
    const id = m.task_id;
    if (m.subtype === "task_started") {
      if (m.task_type !== "local_agent" || m.ambient || !m.tool_use_id) return;
      this.agents.add(id);
      if (m.is_backgrounded) this.background.add(id);
      out.push({
        type: "agent_start",
        agent_id: id,
        tool_use_id: m.tool_use_id,
        description: m.description ?? "",
        subagent_type: m.subagent_type || undefined,
        parent_agent_id: m.parent_task_id,
        depth: m.spawn_depth ?? 1,
        background: Boolean(m.is_backgrounded),
      });
    } else if (!this.agents.has(id)) {
      return;
    } else if (m.subtype === "task_updated") {
      if (m.patch?.is_backgrounded !== true || this.background.has(id)) return;
      this.background.add(id);
      out.push({ type: "agent_background", agent_id: id });
    } else if (m.subtype === "task_progress") {
      out.push({
        type: "agent_progress",
        agent_id: id,
        description: m.description ?? "",
        tool_uses: m.usage?.tool_uses,
        tokens: m.usage?.total_tokens,
        last_tool: m.last_tool_name,
      });
    } else if (m.subtype === "task_notification") {
      this.agents.delete(id);
      this.background.delete(id);
      out.push({
        type: "agent_end",
        agent_id: id,
        tool_use_id: m.tool_use_id,
        status: m.status,
        summary: m.summary ? truncate(m.summary) : undefined,
        tool_uses: m.usage?.tool_uses,
        tokens: m.usage?.total_tokens,
        duration_ms: m.usage?.duration_ms,
      });
    }
  }

  private result(m: AnyRecord, out: Event[]): void {
    this.inTurn = false;
    this.compacted = false;
    this.blocks.clear();
    out.push({
      type: "turn_end",
      subtype: m.subtype,
      is_error: Boolean(m.is_error),
      duration_ms: m.duration_ms ?? 0,
      cost_usd: m.total_cost_usd ?? 0,
      num_turns: m.num_turns ?? 0,
    });
    this.learnWindows(m, out);
    // Claude Code puts its own diagnostic line first when a turn ends early,
    // such as when the user stops it after a tool result.
    const errors = Array.isArray(m.errors)
      ? m.errors.filter((e: unknown) => !String(e).startsWith("[ede_diagnostic]"))
      : [];
    if (m.subtype !== "success" && errors.length) {
      out.push({ type: "notice", level: "error", text: errors.join("\n") });
    }
  }

  // A subagent's context after a response holds the response's prompt and
  // its output.
  private agentUsage(id: string, message: AnyRecord, out: Event[]): void {
    const u = message.usage;
    const tokens =
      (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.output_tokens ?? 0);
    const entry: AgentContext = { model: String(message.model ?? ""), tokens };
    this.contexts.set(id, entry);
    this.agentContext(id, entry, out);
  }

  private windowOf(model: string): number | undefined {
    return this.windows.get(model) ?? this.defaultWindow;
  }

  private agentContext(id: string, entry: AgentContext, out: Event[]): void {
    entry.max = this.windowOf(entry.model);
    const max = entry.max || undefined;
    const percent = max ? Math.round((entry.tokens / max) * 100) : undefined;
    out.push({ type: "agent_context", agent_id: id, tokens: entry.tokens, max, percent });
  }

  // A result names the window of each model that ran. A subagent whose
  // percent came from another window gets it again.
  private learnWindows(m: AnyRecord, out: Event[]): void {
    for (const [model, usage] of Object.entries<AnyRecord>(m.modelUsage ?? {})) {
      if (usage?.contextWindow > 0) this.windows.set(model, usage.contextWindow);
    }
    for (const [id, entry] of this.contexts) {
      if (this.windowOf(entry.model) !== entry.max) this.agentContext(id, entry, out);
    }
  }

  private streamEvent(e: AnyRecord, out: Event[]): void {
    if (e.type === "content_block_start") {
      const cb = e.content_block;
      if (cb.type === "text") {
        this.blocks.set(e.index, { type: "text" });
        out.push({ type: "text_start" });
      } else if (cb.type === "thinking" || cb.type === "redacted_thinking") {
        this.blocks.set(e.index, { type: "thinking" });
        out.push({ type: "thinking_start" });
      } else if (cb.type === "tool_use") {
        this.blocks.set(e.index, { type: "tool_use", id: cb.id, name: cb.name, fields: new FieldStream() });
        out.push({ type: "tool_start", id: cb.id, name: cb.name });
      } else {
        this.blocks.set(e.index, { type: "other" });
      }
    } else if (e.type === "content_block_delta") {
      const d = e.delta;
      if (d.type === "text_delta" && d.text) {
        out.push({ type: "text_delta", text: d.text });
      } else if (d.type === "input_json_delta") {
        const block = this.blocks.get(e.index);
        if (block?.type !== "tool_use") return;
        for (const f of block.fields.push(d.partial_json ?? "")) {
          const ev: Event = { type: "tool_field", id: block.id, name: block.name, key: f.key, phase: f.kind };
          if (f.kind === "delta") ev.text = f.text;
          if (f.kind === "end") ev.value = f.value;
          out.push(ev);
        }
      }
    } else if (e.type === "content_block_stop") {
      const block = this.blocks.get(e.index);
      this.blocks.delete(e.index);
      if (block?.type === "text") out.push({ type: "text_stop" });
      else if (block?.type === "thinking") out.push({ type: "thinking_stop" });
      else if (block?.type === "tool_use") out.push({ type: "tool_input_end", id: block.id });
    } else if (e.type === "message_stop") {
      // A cut stream leaves tool blocks open; their input is incomplete.
      for (const block of this.blocks.values()) {
        if (block.type === "tool_use") out.push({ type: "tool_input_end", id: block.id });
      }
      this.blocks.clear();
    }
  }

  private assistant(m: AnyRecord, out: Event[]): void {
    const synthetic = m.message?.model === SYNTHETIC;
    const failed = m.error || (synthetic && m.is_api_error_message);
    const main = mainThread(m);
    // A slash command such as /usage answers with a message of its own, which
    // streams no text.
    if (synthetic && !failed && main) {
      const text = resultText(m.message.content).trim();
      if (text) out.push({ type: "output", text: truncateOutput(text) });
      return;
    }
    const parent = m.parent_tool_use_id ?? null;
    const agent: string | undefined = main ? undefined : m.agent_id;
    if (agent && !synthetic && m.message?.usage) this.agentUsage(agent, m.message, out);
    for (const block of m.message?.content ?? []) {
      // The main agent's text streamed already. A subagent's comes whole.
      if (agent && block.type === "text" && block.text?.trim()) {
        out.push({ type: "agent_text", agent_id: agent, parent_id: parent, text: truncate(block.text, MAX_AGENT_TEXT) });
      } else if (block.type === "tool_use") {
        if (agent && block.name === "Read") this.agentReads.add(block.id);
        out.push({
          type: "tool_use",
          id: block.id,
          name: block.name,
          input: block.input ?? {},
          parent_id: parent,
          agent_id: agent,
        });
      }
    }
    // A synthetic error says in its text what went wrong. Its code, such as
    // server_error, names only the kind.
    if (failed) {
      const text = synthetic ? resultText(m.message.content).trim() : "";
      out.push({ type: "notice", level: "error", text: truncate(text || String(m.error ?? "API error")) });
    }
  }

  private user(m: AnyRecord, out: Event[]): void {
    const content = m.message?.content;
    if (typeof content === "string" && m.parent_tool_use_id == null) {
      const text = commandOutput(content);
      if (text === undefined) return;
      if (text && !this.compacted) out.push({ type: "output", text: truncateOutput(text) });
      this.compacted = false;
      return;
    }
    if (!Array.isArray(content)) return;
    for (const block of content) {
      if (block.type !== "tool_result") continue;
      const text = resultText(block.content);
      const read = this.agentReads.delete(block.tool_use_id);
      out.push({
        type: "tool_result",
        id: block.tool_use_id,
        is_error: Boolean(block.is_error),
        text: truncate(text),
        result: read && !block.is_error ? readResult(text) : trim(m.tool_use_result),
        parent_id: m.parent_tool_use_id ?? null,
        agent_id: m.agent_id,
      });
    }
  }
}

export function commandsEvent(commands: SdkSlashCommand[]): Event {
  return {
    type: "commands",
    commands: commands.map((c) => ({
      name: c.name,
      description: c.description ?? "",
      argument_hint: c.argumentHint || undefined,
      aliases: c.aliases?.length ? c.aliases : undefined,
      builtin: c.builtin || undefined,
    })),
  };
}

// Tool results can hold whole files. The plugin only needs the metadata.
function trim(value: unknown): unknown {
  if (typeof value === "string") return truncate(value);
  if (Array.isArray(value)) return value.map(trim);
  if (value && typeof value === "object") {
    const out: AnyRecord = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "originalFile") continue;
      out[k] = trim(v);
    }
    return out;
  }
  return value;
}
