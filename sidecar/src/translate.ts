import type { ModelInfo, SDKMessage, SlashCommand as SdkSlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { FieldStream } from "./fieldstream";
import type { Event } from "./protocol";

const MAX_TEXT = 2000;
// A subagent's reply can be long. Its thinking only needs the gist.
const MAX_AGENT_TEXT = 8000;
const MAX_THINKING = 2000;
// A local command such as /context prints about 10k characters of tables.
const MAX_OUTPUT = 20000;
// Claude Code's model name on the messages that it writes itself, such as a
// slash command's output.
const SYNTHETIC = "<synthetic>";

type Block =
  | { type: "text" }
  | { type: "thinking" }
  | { type: "tool_use"; id: string; name: string; fields: FieldStream }
  | { type: "other" };

type AnyRecord = Record<string, any>;

// A message of the main agent's own conversation. Background subagents send
// their messages between the main agent's turns too, as do the task messages
// that report on them.
export function mainThread(msg: SDKMessage): boolean {
  const m = msg as AnyRecord;
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
  // The names of subagent tool calls that wait for their result. A subagent's
  // result has no tool_use_result, so a Read's line count comes from its text.
  private agentTools = new Map<string, string>();

  translate(msg: SDKMessage): Event[] {
    const m = msg as AnyRecord;
    const out: Event[] = [];
    if (!this.inTurn && (m.type === "stream_event" || m.type === "assistant") && mainThread(msg)) {
      this.inTurn = true;
      out.push({ type: "turn_start" });
    }
    switch (m.type) {
      case "system":
        this.system(m, out);
        break;
      case "conversation_reset":
        out.push({ type: "reset" });
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
        if (m.subtype !== "success" && Array.isArray(m.errors) && m.errors.length) {
          out.push({ type: "notice", level: "error", text: m.errors.join("\n") });
        }
        break;
    }
    return out;
  }

  private system(m: AnyRecord, out: Event[]): void {
    if (m.subtype === "init") {
      out.push({
        type: "init",
        session_id: m.session_id,
        model: m.model,
        cwd: m.cwd,
        permission_mode: m.permissionMode,
        version: m.claude_code_version,
        slash_commands: m.slash_commands ?? [],
        ...(Array.isArray(m.terminal_slash_commands) ? { terminal_slash_commands: m.terminal_slash_commands } : {}),
      });
    } else if (m.subtype === "commands_changed" && Array.isArray(m.commands)) {
      out.push(commandsEvent(m.commands));
    } else if (m.subtype === "local_command_output" && typeof m.content === "string" && m.content.trim()) {
      out.push({ type: "output", text: truncateOutput(m.content.trim()) });
    } else if (m.subtype === "status") {
      out.push({ type: "status", status: m.status ?? null, permission_mode: m.permissionMode });
      if (m.compact_result === "failed") {
        out.push({ type: "notice", level: "error", text: `Compaction failed: ${m.compact_error ?? "no reason given"}` });
      }
    } else if (m.subtype === "compact_boundary") {
      const meta = m.compact_metadata ?? {};
      this.compacted = true;
      out.push({ type: "compact", trigger: meta.trigger ?? "auto", pre_tokens: meta.pre_tokens, post_tokens: meta.post_tokens });
    } else if (m.subtype === "api_retry") {
      out.push({
        type: "notice",
        level: "warn",
        text: `API retry ${m.attempt}/${m.max_retries} in ${Math.round(m.retry_delay_ms / 1000)}s`,
      });
    } else if (m.subtype?.startsWith("task_")) {
      this.task(m, out);
    } else if (m.subtype === "background_tasks_changed") {
      this.backgroundTasks(m, out);
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
        ...(m.subagent_type ? { subagent_type: m.subagent_type } : {}),
        ...(m.parent_task_id ? { parent_agent_id: m.parent_task_id } : {}),
        depth: m.spawn_depth ?? 1,
        background: Boolean(m.is_backgrounded),
      });
    } else if (!this.agents.has(id)) {
      return;
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
        ...(m.tool_use_id ? { tool_use_id: m.tool_use_id } : {}),
        status: m.status,
        ...(m.summary ? { summary: truncate(m.summary) } : {}),
        ...(m.usage ? { tool_uses: m.usage.tool_uses, tokens: m.usage.total_tokens, duration_ms: m.usage.duration_ms } : {}),
      });
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
      const block = this.blocks.get(e.index);
      const d = e.delta;
      if (d.type === "text_delta" && d.text) {
        out.push({ type: "text_delta", text: d.text });
      } else if (d.type === "input_json_delta" && block?.type === "tool_use") {
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
    // A slash command such as /usage answers with a message of its own, which
    // streams no text.
    if (synthetic && !failed && mainThread(m as SDKMessage)) {
      const text = resultText(m.message.content).trim();
      if (text) out.push({ type: "output", text: truncateOutput(text) });
      return;
    }
    const parent = m.parent_tool_use_id ?? null;
    const agent = mainThread(m as SDKMessage) ? undefined : m.agent_id;
    for (const block of m.message?.content ?? []) {
      // The main agent's text streamed already. A subagent's comes whole.
      if (agent && block.type === "text" && block.text?.trim()) {
        out.push({ type: "agent_text", agent_id: agent, parent_id: parent, text: truncate(block.text, MAX_AGENT_TEXT) });
      } else if (agent && block.type === "thinking" && block.thinking?.trim()) {
        out.push({
          type: "agent_text",
          agent_id: agent,
          parent_id: parent,
          text: truncate(block.thinking, MAX_THINKING),
          thinking: true,
        });
      } else if (block.type === "tool_use") {
        if (agent) this.agentTools.set(block.id, block.name);
        out.push({
          type: "tool_use",
          id: block.id,
          name: block.name,
          input: block.input ?? {},
          parent_id: parent,
          ...agentOf(m),
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
      if (text !== undefined && !this.compacted && text !== "") out.push({ type: "output", text: truncateOutput(text) });
      if (text !== undefined) this.compacted = false;
      return;
    }
    if (!Array.isArray(content)) return;
    for (const block of content) {
      if (block.type !== "tool_result") continue;
      const text = resultText(block.content);
      const name = this.agentTools.get(block.tool_use_id);
      this.agentTools.delete(block.tool_use_id);
      out.push({
        type: "tool_result",
        id: block.tool_use_id,
        is_error: Boolean(block.is_error),
        text: truncate(text),
        result: name === "Read" && !block.is_error ? readResult(text) : trim(m.tool_use_result),
        parent_id: m.parent_tool_use_id ?? null,
        ...agentOf(m),
      });
    }
  }
}

function agentOf(m: AnyRecord): { agent_id?: string } {
  return m.agent_id ? { agent_id: m.agent_id } : {};
}

export function commandsEvent(commands: SdkSlashCommand[]): Event {
  return {
    type: "commands",
    commands: commands.map((c) => ({
      name: c.name,
      description: c.description ?? "",
      ...(c.argumentHint ? { argument_hint: c.argumentHint } : {}),
      ...(c.aliases?.length ? { aliases: c.aliases } : {}),
      ...(c.builtin ? { builtin: true } : {}),
    })),
  };
}

export function modelsEvent(models: ModelInfo[]): Event {
  return {
    type: "models",
    models: models.map((m) => ({
      value: m.value,
      name: m.displayName,
      description: m.description,
      resolved: m.resolvedModel,
      ...(m.supportsEffort && m.supportedEffortLevels?.length ? { effort_levels: m.supportedEffortLevels } : {}),
    })),
  };
}

// The text of a slash command's output message, or undefined for other text.
export function commandOutput(content: string): string | undefined {
  const match = content.match(/^<local-command-(?:stdout|stderr)>([\s\S]*)<\/local-command-(?:stdout|stderr)>$/);
  return match ? match[1]!.trim() : undefined;
}

export function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((b: AnyRecord) => b.type === "text")
    .map((b: AnyRecord) => b.text)
    .join("\n");
}

// The first `end` characters, without a lone half of a UTF-16 surrogate pair.
// JSON would send it as an escape that Neovim's decoder refuses.
function head(s: string, end: number): string {
  const code = s.charCodeAt(end - 1);
  return s.slice(0, code >= 0xd800 && code <= 0xdbff ? end - 1 : end);
}

export function truncate(s: string, max = MAX_TEXT): string {
  return s.length > max ? head(s, max) + "..." : s;
}

// A Read's text numbers its lines. Saved sessions and subagents' results have
// no tool_use_result, so the line count comes from there.
export function readResult(text: string): { file: { numLines: number } } | undefined {
  const lines = text.split("\n").filter((line) => /^\s*\d+\t/.test(line)).length;
  return lines > 0 ? { file: { numLines: lines } } : undefined;
}

// A slash command's output ends at a line end, so no table row breaks.
export function truncateOutput(s: string): string {
  if (s.length <= MAX_OUTPUT) return s;
  const end = s.lastIndexOf("\n", MAX_OUTPUT);
  return (end > 0 ? s.slice(0, end) : head(s, MAX_OUTPUT)) + "\n...";
}

// Tool results can hold whole files. The plugin only needs the metadata.
export function trim(value: unknown): unknown {
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
